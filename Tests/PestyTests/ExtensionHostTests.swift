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
                    api: 1
                )
            )
        )
    }

    func testBadgeReturnsString() {
        let host = ExtensionHost()
        let source = script(id: "com.example.badge", badgeBody: #"return "ready";"#)

        XCTAssertEqual(
            host.badgeSync(
                clipType: "text",
                text: "hello",
                extension: installed(source: source, id: "com.example.badge")
            ),
            .success("ready")
        )
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

    func testThrowingBadgeReturnsExceptionAndDoesNotPoisonHost() {
        let host = ExtensionHost()
        let throwingSource = script(
            id: "com.example.throwing",
            badgeBody: #"throw new Error("broken");"#
        )

        guard case .failure(.scriptException(let message)) = host.badgeSync(
            clipType: "text",
            text: "hello",
            extension: installed(source: throwingSource, id: "com.example.throwing")
        ) else {
            return XCTFail("Expected a script exception")
        }
        XCTAssertTrue(message.contains("broken"))

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
            .failure(.badgeNotAFunction)
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

        XCTAssertEqual(host.validate(source: source), .failure(.badgeNotAFunction))
    }

    func testMissingBadgeIsRejectedWithoutCallingJSObjectAPI() {
        let host = ExtensionHost()
        let source = """
        pesty.register({
          id: "com.example.missing-badge",
          name: "Example",
          version: "1.0",
          api: 1
        });
        """

        XCTAssertEqual(host.validate(source: source), .failure(.badgeNotAFunction))
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

        let badgeSource = script(
            id: "com.example.large-error",
            badgeBody: #"throw new Error("x".repeat(1000));"#
        )
        guard case .failure(.scriptException(let badgeMessage)) = host.badgeSync(
            clipType: "text",
            text: "hello",
            extension: installed(source: badgeSource, id: "com.example.large-error")
        ) else {
            return XCTFail("Expected a badge exception")
        }
        XCTAssertEqual(badgeMessage.count, 200)
    }

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
            guard case .failure(.scriptException) = host.badgeSync(
                clipType: "text",
                text: "hello",
                extension: failingExtension
            ) else {
                return XCTFail("Expected a script exception")
            }
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
            api: 1
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

    private func installed(source: String, id: String) -> InstalledExtension {
        InstalledExtension(
            manifest: ExtensionManifest(id: id, name: "Example", version: "1.0", api: 1),
            source: source,
            enabled: true,
            isBundled: false,
            installedAt: .now
        )
    }
}
