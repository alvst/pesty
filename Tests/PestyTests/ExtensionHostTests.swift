import XCTest
@testable import Pesty

final class ExtensionHostTests: XCTestCase {
    func testValidScriptReturnsItsManifest() {
        let host = ExtensionHost()
        let source = script(id: "com.example.valid", name: "Example", version: "2.3")

        XCTAssertEqual(
            host.validate(source: source),
            .success(
                ExtensionManifest(
                    id: "com.example.valid",
                    name: "Example",
                    version: "2.3",
                    api: 1,
                    hooks: ["badge"]
                )
            )
        )
    }

    func testBadgeReturnsString() {
        let host = ExtensionHost()
        let source = script(id: "com.example.badge", badgeBody: #"return "ready";"#)
        let extensionValue = installed(source: source, id: "com.example.badge")

        XCTAssertEqual(
            host.badgeSync(
                clipType: "text",
                text: "hello",
                extension: extensionValue
            ),
            .success("ready")
        )
        XCTAssertEqual(
            host.decorationsSync(
                clipType: "text",
                text: "hello",
                extension: extensionValue
            ),
            .success(CardDecorations(badge: "ready"))
        )
    }

    func testAsyncDecorationsCompleteOnMainQueue() {
        let host = ExtensionHost()
        let source = script(id: "com.example.async-decorations")
        let completion = expectation(description: "decorations completion")

        host.decorations(
            clipType: "text",
            text: "hello",
            extension: installed(source: source, id: "com.example.async-decorations")
        ) { decorations in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(decorations, CardDecorations(badge: "badge"))
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2)
    }

    func testAsyncBadgeCompletesOnMainQueue() {
        let host = ExtensionHost()
        let source = script(id: "com.example.async", badgeBody: #"return "ready";"#)
        let completion = expectation(description: "badge completion")

        host.badge(
            clipType: "text",
            text: "hello",
            extension: installed(source: source, id: "com.example.async")
        ) { badge in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(badge, "ready")
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2)
    }

    func testTextIsCappedAt65536UTF16Units() {
        let host = ExtensionHost()
        let source = script(
            id: "com.example.cap",
            badgeBody: "return String(clip.text.length);"
        )

        XCTAssertEqual(
            host.badgeSync(
                clipType: "text",
                text: String(repeating: "x", count: 200_000),
                extension: installed(source: source, id: "com.example.cap")
            ),
            .success("65536")
        )
    }

    func testThrowingBadgeBecomesNilAndDoesNotPoisonHost() {
        let host = ExtensionHost()
        let throwingSource = script(
            id: "com.example.throwing",
            badgeBody: #"throw new Error("broken");"#
        )

        XCTAssertEqual(
            host.badgeSync(
                clipType: "text",
                text: "hello",
                extension: installed(source: throwingSource, id: "com.example.throwing")
            ),
            .success(nil)
        )

        let healthySource = script(id: "com.example.healthy", badgeBody: #"return "ok";"#)
        XCTAssertEqual(
            host.badgeSync(
                clipType: "text",
                text: "hello",
                extension: installed(source: healthySource, id: "com.example.healthy")
            ),
            .success("ok")
        )
    }

    func testNonStringBadgeValuesBecomeNil() {
        let host = ExtensionHost()
        let numberSource = script(id: "com.example.number", badgeBody: "return 42;")
        let objectSource = script(id: "com.example.object", badgeBody: "return { value: 42 }; ")

        XCTAssertEqual(
            host.badgeSync(
                clipType: "text",
                text: "hello",
                extension: installed(source: numberSource, id: "com.example.number")
            ),
            .success(nil)
        )
        XCTAssertEqual(
            host.badgeSync(
                clipType: "text",
                text: "hello",
                extension: installed(source: objectSource, id: "com.example.object")
            ),
            .success(nil)
        )
    }

    func testBadgeSanitationTrimsStripsControlsAndTruncates() {
        let host = ExtensionHost()
        let dirtySource = script(
            id: "com.example.dirty",
            badgeBody: #"return "  ab\n\u0007cd  ";"#
        )
        let longSource = script(
            id: "com.example.long",
            badgeBody: #"return "abcdefghijklmnopqrstuvwxyz012345";"#
        )
        let blankSource = script(
            id: "com.example.blank",
            badgeBody: #"return " \n\t ";"#
        )

        XCTAssertEqual(
            host.badgeSync(
                clipType: "text",
                text: "hello",
                extension: installed(source: dirtySource, id: "com.example.dirty")
            ),
            .success("abcd")
        )
        XCTAssertEqual(
            host.badgeSync(
                clipType: "text",
                text: "hello",
                extension: installed(source: longSource, id: "com.example.long")
            ),
            .success("abcdefghijklmnopqrstuvwx")
        )
        XCTAssertEqual(
            host.badgeSync(
                clipType: "text",
                text: "hello",
                extension: installed(source: blankSource, id: "com.example.blank")
            ),
            .success(nil)
        )
    }

    func testMultiHookDecorationsAreSanitizedPerField() throws {
        let host = ExtensionHost()
        let source = #"""
        pesty.register({
          id: "com.example.multi-hook",
          name: "Multi Hook",
          version: "1.0",
          api: 1,
          badge: function (clip) { return "  abcdefghijklmnopqrstuvwxyz\n\u0007  "; },
          subtitle: function (clip) { return "  " + "s".repeat(90) + "\n"; },
          icon: function (clip) {
            return clip.text === "invalid" ? "Square.and.arrow" : "  square.and.arrow.up  ";
          },
          color: function (clip) { return clip.text === "invalid" ? "#abcdzz" : "#a1b2c3"; },
          title: function (clip) { return "t".repeat(70); },
          label: function (clip) { return "abcdefghijklmnopqrst"; }
        });
        """#
        let manifest = try host.validate(source: source).get()
        XCTAssertEqual(
            manifest.hooks,
            ["badge", "color", "icon", "label", "subtitle", "title"]
        )
        let extensionValue = InstalledExtension(
            manifest: manifest,
            source: source,
            enabled: true,
            isBundled: false,
            installedAt: .now
        )

        XCTAssertEqual(
            host.decorationsSync(
                clipType: "text",
                text: "valid",
                extension: extensionValue
            ),
            .success(
                CardDecorations(
                    badge: "abcdefghijklmnopqrstuvwx",
                    subtitle: String(repeating: "s", count: 80),
                    icon: "square.and.arrow.up",
                    color: "#A1B2C3",
                    title: String(repeating: "t", count: 60),
                    label: "abcdefghijklmnop"
                )
            )
        )
        XCTAssertEqual(
            host.decorationsSync(
                clipType: "text",
                text: "invalid",
                extension: extensionValue
            ),
            .success(
                CardDecorations(
                    badge: "abcdefghijklmnopqrstuvwx",
                    subtitle: String(repeating: "s", count: 80),
                    title: String(repeating: "t", count: 60),
                    label: "abcdefghijklmnop"
                )
            )
        )
    }

    func testTypesFilterSkipsJavaScriptAndFailureTicks() {
        let host = ExtensionHost()
        let extensionID = "com.example.filtered"
        let extensionValue = installed(
            source: #"throw new Error("must not run");"#,
            id: extensionID,
            types: ["link"],
            hooks: ["badge"]
        )

        for _ in 0..<5 {
            XCTAssertEqual(
                host.decorationsSync(
                    clipType: "text",
                    text: "hello",
                    extension: extensionValue
                ),
                .success(CardDecorations())
            )
        }
        XCTAssertFalse(host.isQuarantined(extensionID))
    }

    func testWeightAndTypesAreValidatedAndNormalized() throws {
        let host = ExtensionHost()
        let clampedSource = """
        pesty.register({
          id: "com.example.weighted",
          name: "Weighted",
          version: "1.0",
          api: 1,
          weight: 2500,
          types: ["link", "text", "link"],
          badge: function (clip) { return "ok"; }
        });
        """
        let clamped = try host.validate(source: clampedSource).get()
        XCTAssertEqual(clamped.weight, 1000)
        XCTAssertEqual(clamped.types, ["link", "text"])

        let negativeSource = clampedSource
            .replacingOccurrences(of: "com.example.weighted", with: "com.example.negative")
            .replacingOccurrences(of: "2500", with: "-2500")
        XCTAssertEqual(try host.validate(source: negativeSource).get().weight, -1000)

        let nonNumber = clampedSource.replacingOccurrences(of: "2500", with: #""heavy""#)
        XCTAssertEqual(
            host.validate(source: nonNumber),
            .failure(.invalidManifest("weight must be a finite number"))
        )
        let nonFinite = clampedSource.replacingOccurrences(of: "2500", with: "Infinity")
        XCTAssertEqual(
            host.validate(source: nonFinite),
            .failure(.invalidManifest("weight must be a finite number"))
        )
        let unknownType = clampedSource.replacingOccurrences(
            of: #"["link", "text", "link"]"#,
            with: #"["video"]"#
        )
        XCTAssertEqual(
            host.validate(source: unknownType),
            .failure(.invalidManifest("unknown clip type video"))
        )
        let emptyTypes = clampedSource.replacingOccurrences(
            of: #"["link", "text", "link"]"#,
            with: "[]"
        )
        XCTAssertEqual(
            host.validate(source: emptyTypes),
            .failure(.invalidManifest("types must be a non-empty array"))
        )
        let nonStringType = clampedSource.replacingOccurrences(
            of: #"["link", "text", "link"]"#,
            with: "[42]"
        )
        XCTAssertEqual(
            host.validate(source: nonStringType),
            .failure(.invalidManifest("types entries must be strings"))
        )
    }

    func testPerHookExceptionKeepsOtherValuesAndCleanEvaluationResetsFailures() {
        let host = ExtensionHost()
        let extensionID = "com.example.partial-failure"
        let source = #"""
        pesty.register({
          id: "com.example.partial-failure",
          name: "Partial Failure",
          version: "1.0",
          api: 1,
          badge: function (clip) { return "kept"; },
          icon: function (clip) {
            if (clip.text === "fail") { throw new Error("broken icon"); }
            return "checkmark";
          }
        });
        """#
        let extensionValue = installed(
            source: source,
            id: extensionID,
            hooks: ["badge", "icon"]
        )
        let partial = CardDecorations(badge: "kept")

        for _ in 0..<4 {
            XCTAssertEqual(
                host.decorationsSync(
                    clipType: "text",
                    text: "fail",
                    extension: extensionValue
                ),
                .success(partial)
            )
        }
        XCTAssertEqual(
            host.decorationsSync(
                clipType: "text",
                text: "clean",
                extension: extensionValue
            ),
            .success(CardDecorations(badge: "kept", icon: "checkmark"))
        )
        for _ in 0..<4 {
            _ = host.decorationsSync(
                clipType: "text",
                text: "fail",
                extension: extensionValue
            )
        }
        XCTAssertFalse(host.isQuarantined(extensionID))

        XCTAssertEqual(
            host.decorationsSync(
                clipType: "text",
                text: "fail",
                extension: extensionValue
            ),
            .success(partial)
        )
        XCTAssertTrue(host.isQuarantined(extensionID))
    }

    func testTransformIsOnDemandPreservesContentAndCompletesOnMainQueue() throws {
        let host = ExtensionHost()
        let source = #"""
        pesty.register({
          id: "com.example.transform",
          name: "Transform",
          version: "1.0",
          api: 1,
          transform: function (clip) { return "  " + clip.type + ":" + clip.text + "\n"; }
        });
        """#
        let manifest = try host.validate(source: source).get()
        XCTAssertEqual(manifest.hooks, ["transform"])
        let extensionValue = InstalledExtension(
            manifest: manifest,
            source: source,
            enabled: true,
            isBundled: false,
            installedAt: .now
        )

        XCTAssertEqual(
            host.decorationsSync(
                clipType: "text",
                text: "hello",
                extension: extensionValue
            ),
            .success(CardDecorations())
        )
        XCTAssertEqual(
            host.transformSync(
                clipType: "text",
                text: "hello",
                extension: extensionValue
            ),
            .success("  text:hello\n")
        )

        let completion = expectation(description: "transform completion")
        host.transform(
            clipType: "link",
            text: "example",
            extension: extensionValue
        ) { value in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(value, "  link:example\n")
            completion.fulfill()
        }
        wait(for: [completion], timeout: 2)
    }

    func testOversizeTransformBecomesNilAndTicksFailure() {
        let host = ExtensionHost()
        let extensionID = "com.example.large-transform"
        let source = #"""
        pesty.register({
          id: "com.example.large-transform",
          name: "Large Transform",
          version: "1.0",
          api: 1,
          transform: function (clip) { return "x".repeat(1048577); }
        });
        """#
        let extensionValue = installed(
            source: source,
            id: extensionID,
            hooks: ["transform"]
        )

        for _ in 0..<5 {
            XCTAssertEqual(
                host.transformSync(
                    clipType: "text",
                    text: "hello",
                    extension: extensionValue
                ),
                .success(nil)
            )
        }
        XCTAssertTrue(host.isQuarantined(extensionID))
    }

    func testInvalidRegistrationShapesAreRejected() {
        let host = ExtensionHost()
        XCTAssertEqual(
            host.validate(source: script(id: "com.example.api", api: 2)),
            .failure(.unsupportedAPI(2))
        )
        XCTAssertEqual(host.validate(source: "var answer = 42;"), .failure(.noRegisterCall))

        let registration = script(id: "com.example.duplicate")
        XCTAssertEqual(
            host.validate(source: registration + "\n" + registration),
            .failure(.duplicateRegisterCall)
        )
        for id in ["a", "has space"] {
            guard case .failure(.invalidManifest) = host.validate(source: script(id: id)) else {
                return XCTFail("Expected invalid manifest for \(id)")
            }
        }
        XCTAssertEqual(
            host.validate(
                source: """
                pesty.register({
                  id: "com.example.object-badge",
                  name: "Example",
                  version: "1.0",
                  api: 1,
                  badge: {}
                });
                """
            ),
            .failure(.hookNotAFunction("badge"))
        )
        XCTAssertEqual(
            host.validate(
                source: """
                pesty.register({
                  id: "com.example.numeric-icon",
                  name: "Example",
                  version: "1.0",
                  api: 1,
                  badge: function (clip) { return "ok"; },
                  icon: 42
                });
                """
            ),
            .failure(.hookNotAFunction("icon"))
        )
    }

    func testNumericBadgeIsRejectedWithoutCallingJSObjectAPI() {
        let host = ExtensionHost()
        let source = """
        pesty.register({
          id: "com.example.numeric-badge",
          name: "Example",
          version: "1.0",
          api: 1,
          badge: 42
        });
        """

        XCTAssertEqual(host.validate(source: source), .failure(.hookNotAFunction("badge")))
    }

    func testRegistrationWithoutHooksIsRejected() {
        let host = ExtensionHost()
        let source = """
        pesty.register({
          id: "com.example.missing-badge",
          name: "Example",
          version: "1.0",
          api: 1
        });
        """

        XCTAssertEqual(
            host.validate(source: source),
            .failure(.invalidManifest("at least one hook function is required"))
        )
    }

    func testExceptionMessagesAreCappedAt200CharactersAtBothBoundaries() {
        let host = ExtensionHost()
        let loadResult = host.validate(
            source: #"throw new Error("x".repeat(1000));"#
        )
        guard case .failure(.scriptException(let loadMessage)) = loadResult else {
            return XCTFail("Expected a load exception")
        }
        XCTAssertEqual(loadMessage.count, 200)

        let transformSource = """
        pesty.register({
          id: "com.example.large-error",
          name: "Example",
          version: "1.0",
          api: 1,
          transform: function (clip) { throw new Error("x".repeat(1000)); }
        });
        """
        let transformExtension = installed(
            source: transformSource,
            id: "com.example.large-error",
            hooks: ["transform"]
        )
        guard case .failure(.scriptException(let transformMessage)) = host.transformSync(
            clipType: "text",
            text: "hello",
            extension: transformExtension
        ) else {
            return XCTFail("Expected a transform exception")
        }
        XCTAssertEqual(transformMessage.count, 200)
    }

    func testFiveConsecutiveFailuresQuarantineOnlyThatExtension() {
        let host = ExtensionHost()
        let failingSource = script(
            id: "com.example.quarantine",
            badgeBody: #"throw new Error("nope");"#
        )
        let failingExtension = installed(
            source: failingSource,
            id: "com.example.quarantine"
        )

        for _ in 0..<5 {
            XCTAssertEqual(
                host.badgeSync(
                    clipType: "text",
                    text: "hello",
                    extension: failingExtension
                ),
                .success(nil)
            )
        }
        XCTAssertTrue(host.isQuarantined(failingExtension.id))
        XCTAssertEqual(
            host.badgeSync(clipType: "text", text: "hello", extension: failingExtension),
            .success(nil)
        )

        let healthySource = script(id: "com.example.unaffected", badgeBody: #"return "ok";"#)
        XCTAssertFalse(host.isQuarantined("com.example.unaffected"))
        XCTAssertEqual(
            host.badgeSync(
                clipType: "text",
                text: "hello",
                extension: installed(source: healthySource, id: "com.example.unaffected")
            ),
            .success("ok")
        )
    }

    func testSuccessfulCallResetsConsecutiveFailureCount() {
        let host = ExtensionHost()
        let conditionalSource = script(
            id: "com.example.reset",
            badgeBody: #"if (clip.text === "fail") { throw new Error("nope"); } return "ok";"#
        )
        let extensionValue = installed(source: conditionalSource, id: "com.example.reset")

        for _ in 0..<4 {
            _ = host.badgeSync(clipType: "text", text: "fail", extension: extensionValue)
        }
        XCTAssertEqual(
            host.badgeSync(clipType: "text", text: "pass", extension: extensionValue),
            .success("ok")
        )
        for _ in 0..<4 {
            _ = host.badgeSync(clipType: "text", text: "fail", extension: extensionValue)
        }
        XCTAssertFalse(host.isQuarantined(extensionValue.id))
    }

    func testBundledTokenCountExtension() {
        let host = ExtensionHost()
        let manifest = ExtensionManifest(
            id: "com.alvst.pesty-alvie.token-count",
            name: "Token Count",
            version: "1.0",
            api: 1,
            hooks: ["badge"]
        )
        let extensionValue = InstalledExtension(
            manifest: manifest,
            source: BundledExtensions.tokenCount,
            enabled: false,
            isBundled: true,
            installedAt: .now
        )

        XCTAssertEqual(host.validate(source: BundledExtensions.tokenCount), .success(manifest))
        XCTAssertEqual(
            host.badgeSync(clipType: "text", text: "hello world", extension: extensionValue),
            .success("≈3 tok")
        )
        XCTAssertEqual(
            host.badgeSync(clipType: "image", text: "pixels", extension: extensionValue),
            .success(nil)
        )
        XCTAssertEqual(
            host.badgeSync(clipType: "text", text: "", extension: extensionValue),
            .success(nil)
        )
    }

    func testBundledJSONDetectorExtension() {
        let host = ExtensionHost()
        let manifest = ExtensionManifest(
            id: "com.alvst.pesty-alvie.json-detector",
            name: "JSON",
            version: "1.0",
            api: 1,
            weight: 10,
            types: ["text"],
            hooks: ["icon", "label", "subtitle"]
        )
        let extensionValue = InstalledExtension(
            manifest: manifest,
            source: BundledExtensions.jsonDetector,
            enabled: false,
            isBundled: true,
            installedAt: .now
        )

        XCTAssertEqual(host.validate(source: BundledExtensions.jsonDetector), .success(manifest))
        XCTAssertEqual(
            host.decorationsSync(
                clipType: "text",
                text: #"{"one":1,"two":2}"#,
                extension: extensionValue
            ),
            .success(
                CardDecorations(
                    subtitle: "Valid JSON · 2 keys",
                    icon: "curlybraces",
                    label: "JSON"
                )
            )
        )
        XCTAssertEqual(
            host.decorationsSync(
                clipType: "text",
                text: #"[1,2,3]"#,
                extension: extensionValue
            ),
            .success(
                CardDecorations(
                    subtitle: "Valid JSON · 3 items",
                    icon: "curlybraces",
                    label: "JSON"
                )
            )
        )
        XCTAssertEqual(
            host.decorationsSync(
                clipType: "text",
                text: "not JSON",
                extension: extensionValue
            ),
            .success(CardDecorations())
        )
        XCTAssertEqual(
            host.decorationsSync(
                clipType: "file",
                text: #"{"valid":true}"#,
                extension: extensionValue
            ),
            .success(CardDecorations())
        )
    }

    private func script(
        id: String,
        name: String = "Example",
        version: String = "1.0",
        api: Int = 1,
        badgeBody: String = #"return "badge";"#
    ) -> String {
        """
        pesty.register({
          id: "\(id)",
          name: "\(name)",
          version: "\(version)",
          api: \(api),
          badge: function (clip) { \(badgeBody) }
        });
        """
    }

    private func installed(
        source: String,
        id: String,
        types: [String]? = nil,
        hooks: [String] = ["badge"]
    ) -> InstalledExtension {
        InstalledExtension(
            manifest: ExtensionManifest(
                id: id,
                name: "Example",
                version: "1.0",
                api: 1,
                types: types,
                hooks: hooks
            ),
            source: source,
            enabled: true,
            isBundled: false,
            installedAt: .now
        )
    }
}

/// Public JavaScriptCore API cannot stop these scripts, so their workers live
/// until the test process exits. Keep this suite after the result-store stress
/// tests so the intentional runaways cannot consume their execution budgets.
final class RunawayExtensionHostTests: XCTestCase {
    func testInfiniteLoopTimesOutAndAnotherExtensionStillRuns() {
        let host = ExtensionHost()
        let loopingSource = script(
            id: "com.example.loop",
            badgeBody: "while (true) {}"
        )
        let startedAt = Date()

        XCTAssertEqual(
            host.badgeSync(
                clipType: "text",
                text: "hello",
                extension: installed(source: loopingSource, id: "com.example.loop")
            ),
            .failure(.timedOut)
        )
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        XCTAssertTrue(host.isQuarantined("com.example.loop"))

        let healthySource = script(id: "com.example.after-loop", badgeBody: #"return "ok";"#)
        XCTAssertEqual(
            host.badgeSync(
                clipType: "text",
                text: "hello",
                extension: installed(source: healthySource, id: "com.example.after-loop")
            ),
            .success("ok")
        )
    }

    func testQuarantineReadDoesNotWaitBehindEvaluationQueue() {
        let host = ExtensionHost()
        let extensionID = "com.example.nonblocking-quarantine-read"
        let loopingExtension = installed(
            source: script(id: extensionID, badgeBody: "while (true) {}"),
            id: extensionID
        )
        let evaluationFinished = expectation(description: "looping evaluation finished")

        host.badge(
            clipType: "text",
            text: "hello",
            extension: loopingExtension
        ) { _ in
            evaluationFinished.fulfill()
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        _ = host.isQuarantined(extensionID)
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        XCTAssertLessThan(elapsed, 0.05)
        wait(for: [evaluationFinished], timeout: 2)
        XCTAssertTrue(host.isQuarantined(extensionID))
    }

    func testSubtitleTimeoutQuarantinesImmediately() {
        let host = ExtensionHost()
        let extensionID = "com.example.subtitle-timeout"
        let source = """
        pesty.register({
          id: "com.example.subtitle-timeout",
          name: "Subtitle Timeout",
          version: "1.0",
          api: 1,
          badge: function (clip) { return "ready"; },
          subtitle: function (clip) { while (true) {} }
        });
        """

        XCTAssertEqual(
            host.decorationsSync(
                clipType: "text",
                text: "hello",
                extension: installed(
                    source: source,
                    id: extensionID,
                    hooks: ["badge", "subtitle"]
                )
            ),
            .failure(.timedOut)
        )
        XCTAssertTrue(host.isQuarantined(extensionID))
    }

    func testTransformTimeoutQuarantinesImmediately() {
        let host = ExtensionHost()
        let extensionID = "com.example.transform-timeout"
        let source = """
        pesty.register({
          id: "com.example.transform-timeout",
          name: "Transform Timeout",
          version: "1.0",
          api: 1,
          transform: function (clip) { while (true) {} }
        });
        """

        XCTAssertEqual(
            host.transformSync(
                clipType: "text",
                text: "hello",
                extension: installed(
                    source: source,
                    id: extensionID,
                    hooks: ["transform"]
                )
            ),
            .failure(.timedOut)
        )
        XCTAssertTrue(host.isQuarantined(extensionID))
    }

    private func script(
        id: String,
        badgeBody: String
    ) -> String {
        """
        pesty.register({
          id: "\(id)",
          name: "Example",
          version: "1.0",
          api: 1,
          badge: function (clip) { \(badgeBody) }
        });
        """
    }

    private func installed(
        source: String,
        id: String,
        hooks: [String] = ["badge"]
    ) -> InstalledExtension {
        InstalledExtension(
            manifest: ExtensionManifest(
                id: id,
                name: "Example",
                version: "1.0",
                api: 1,
                hooks: hooks
            ),
            source: source,
            enabled: true,
            isBundled: false,
            installedAt: .now
        )
    }
}
