import XCTest
@testable import Pesty

@MainActor
final class ExtensionCatalogTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        super.tearDown()
    }

    func testFreshCatalogSeedsBundledExtensionsDisabled() throws {
        let catalog = ExtensionCatalog(directory: directory)
        let expectedIDs: Set<String> = [
            "com.alvst.pesty.token-count",
            "com.alvst.pesty.json-detector"
        ]

        XCTAssertEqual(Set(catalog.extensions.map(\.id)), expectedIDs)
        XCTAssertTrue(catalog.extensions.allSatisfy(\.isBundled))
        XCTAssertTrue(catalog.extensions.allSatisfy { !$0.enabled })
        XCTAssertTrue(catalog.enabledExtensions.isEmpty)
    }

    func testInstallPersistsWithPrivatePermissions() throws {
        let catalog = ExtensionCatalog(directory: directory)
        let source = script(id: "com.example.installed")

        XCTAssertEqual(
            catalog.install(source: source),
            .success(
                ExtensionManifest(
                    id: "com.example.installed",
                    name: "Example",
                    version: "1.0",
                    api: 1,
                    hooks: ["badge"]
                )
            )
        )

        let storeURL = directory.appendingPathComponent("extensions.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        XCTAssertEqual(try permissions(of: directory), 0o700)
        XCTAssertEqual(try permissions(of: storeURL), 0o600)
    }

    func testInstallPersistsDerivedManifestCapabilities() throws {
        let catalog = ExtensionCatalog(directory: directory)
        let source = """
        pesty.register({
          id: "com.example.capabilities",
          name: "Capabilities",
          version: "1.0",
          api: 1,
          weight: 125.5,
          types: ["link", "color"],
          title: function (clip) { return "Title"; },
          icon: function (clip) { return "link"; }
        });
        """

        let manifest = try catalog.install(source: source).get()
        XCTAssertEqual(manifest.weight, 125.5)
        XCTAssertEqual(manifest.types, ["link", "color"])
        XCTAssertEqual(manifest.hooks, ["icon", "title"])

        let reloaded = ExtensionCatalog(directory: directory)
        let persisted = try XCTUnwrap(
            reloaded.extensions.first(where: { $0.id == "com.example.capabilities" })
        )
        XCTAssertEqual(persisted.manifest, manifest)
    }

    func testReloadRoundTripsInstalledExtensions() {
        let catalog = ExtensionCatalog(directory: directory)
        let source = script(id: "com.example.roundtrip")
        _ = catalog.install(source: source)
        catalog.setEnabled(true, id: "com.example.roundtrip")

        let reloaded = ExtensionCatalog(directory: directory)

        XCTAssertEqual(reloaded.extensions, catalog.extensions)
        XCTAssertEqual(reloaded.enabledExtensions.map(\.id), ["com.example.roundtrip"])
    }

    func testSameIDReinstallPreservesEnabledState() throws {
        let catalog = ExtensionCatalog(directory: directory)
        let original = script(id: "com.example.replace", version: "1.0")
        let replacement = script(
            id: "com.example.replace",
            version: "2.0",
            badgeBody: #"return "new";"#
        )
        _ = catalog.install(source: original)
        catalog.setEnabled(true, id: "com.example.replace")

        _ = catalog.install(source: replacement)

        let installed = try XCTUnwrap(
            catalog.extensions.first(where: { $0.id == "com.example.replace" })
        )
        XCTAssertEqual(installed.manifest.version, "2.0")
        XCTAssertEqual(installed.source, replacement)
        XCTAssertTrue(installed.enabled)
        XCTAssertEqual(catalog.extensions.filter { $0.id == installed.id }.count, 1)
    }

    func testInvalidInstallLeavesMemoryAndFileUnchanged() throws {
        let catalog = ExtensionCatalog(directory: directory)
        let storeURL = directory.appendingPathComponent("extensions.json")
        let extensionsBefore = catalog.extensions
        let dataBefore = try Data(contentsOf: storeURL)

        XCTAssertEqual(catalog.install(source: "var invalid = true;"), .failure(.noRegisterCall))

        XCTAssertEqual(catalog.extensions, extensionsBefore)
        XCTAssertEqual(try Data(contentsOf: storeURL), dataBefore)
    }

    func testUninstallRemovesAndPersistsExtension() {
        let catalog = ExtensionCatalog(directory: directory)
        _ = catalog.install(source: script(id: "com.example.remove"))

        catalog.uninstall(id: "com.example.remove")

        XCTAssertFalse(catalog.extensions.contains { $0.id == "com.example.remove" })
        let reloaded = ExtensionCatalog(directory: directory)
        XCTAssertFalse(reloaded.extensions.contains { $0.id == "com.example.remove" })
    }

    func testUninstalledBundledExtensionsAreNotReseeded() {
        let catalog = ExtensionCatalog(directory: directory)
        catalog.uninstall(id: "com.alvst.pesty.token-count")
        catalog.uninstall(id: "com.alvst.pesty.json-detector")

        let reloaded = ExtensionCatalog(directory: directory)

        XCTAssertTrue(reloaded.extensions.isEmpty)
    }

    func testExistingCatalogDoesNotReceiveJSONDetector() throws {
        let host = ExtensionHost()
        let manifest = try host.validate(source: BundledExtensions.tokenCount).get()
        let existing = InstalledExtension(
            manifest: manifest,
            source: BundledExtensions.tokenCount,
            enabled: false,
            isBundled: true,
            installedAt: Date(timeIntervalSince1970: 1)
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode([existing]).write(
            to: directory.appendingPathComponent("extensions.json")
        )

        let catalog = ExtensionCatalog(directory: directory, host: host)

        XCTAssertEqual(catalog.extensions.map(\.id), ["com.alvst.pesty.token-count"])
        XCTAssertFalse(catalog.extensions.contains {
            $0.id == "com.alvst.pesty.json-detector"
        })
    }

    func testSetEnabledPersistsAcrossReload() {
        let catalog = ExtensionCatalog(directory: directory)
        catalog.setEnabled(true, id: "com.alvst.pesty.token-count")

        let reloaded = ExtensionCatalog(directory: directory)

        XCTAssertTrue(
            reloaded.extensions.first {
                $0.id == "com.alvst.pesty.token-count"
            }?.enabled == true
        )
        XCTAssertEqual(reloaded.enabledExtensions.map(\.id), ["com.alvst.pesty.token-count"])
    }

    func testTransformExtensionsFilterByEnabledHookAndClipType() throws {
        let host = ExtensionHost()
        let catalog = ExtensionCatalog(directory: directory, host: host)
        let transformID = "com.example.transform-menu"
        let badgeID = "com.example.badge-only"
        let transformSource = """
        pesty.register({
          id: "\(transformID)",
          name: "Transform",
          version: "1.0",
          api: 1,
          types: ["text"],
          transform: function (clip) { return clip.text.toUpperCase(); }
        });
        """

        XCTAssertNoThrow(try catalog.install(source: transformSource).get())
        XCTAssertNoThrow(try catalog.install(source: script(id: badgeID)).get())
        XCTAssertTrue(catalog.transformExtensions(for: "text").isEmpty)

        catalog.setEnabled(true, id: badgeID)
        XCTAssertTrue(catalog.transformExtensions(for: "text").isEmpty)

        catalog.setEnabled(true, id: transformID)
        XCTAssertEqual(
            catalog.transformExtensions(for: "text").map(\.id),
            [transformID]
        )
        XCTAssertTrue(catalog.transformExtensions(for: "link").isEmpty)

        catalog.setEnabled(false, id: transformID)
        XCTAssertTrue(catalog.transformExtensions(for: "text").isEmpty)
    }

    func testTransformExtensionsExcludeQuarantinedExtension() throws {
        let host = ExtensionHost()
        let catalog = ExtensionCatalog(directory: directory, host: host)
        let extensionID = "com.example.transform-quarantine"
        let source = """
        pesty.register({
          id: "\(extensionID)",
          name: "Slow Transform",
          version: "1.0",
          api: 1,
          transform: function (clip) {
            var deadline = Date.now() + 400;
            while (Date.now() < deadline) {}
            return clip.text;
          }
        });
        """
        _ = try catalog.install(source: source).get()
        catalog.setEnabled(true, id: extensionID)
        let installedExtension = try XCTUnwrap(
            catalog.extensions.first { $0.id == extensionID }
        )
        let invalidated = expectation(description: "transform quarantine invalidated")
        catalog.onExtensionInvalidated = { id in
            if id == extensionID { invalidated.fulfill() }
        }

        XCTAssertEqual(
            catalog.transformExtensions(for: "text").map(\.id),
            [extensionID]
        )
        XCTAssertEqual(
            host.transformSync(
                clipType: "text",
                text: "hello",
                extension: installedExtension
            ),
            .failure(.timedOut)
        )
        wait(for: [invalidated], timeout: 1)

        XCTAssertTrue(catalog.isQuarantined(extensionID))
        XCTAssertTrue(catalog.transformExtensions(for: "text").isEmpty)
    }

    func testMenuEntriesFilterByEnabledQuarantineAndClipTypeAndPersist() throws {
        let host = ExtensionHost()
        let catalog = ExtensionCatalog(directory: directory, host: host)
        let textID = "com.example.text-menu"
        let linkID = "com.example.link-menu"
        let disabledID = "com.example.disabled-menu"

        _ = try catalog.install(
            source: menuScript(
                id: textID,
                types: ["text"],
                menuItems: #"[{ title: "Copy Edited", verb: "copyTransformed" }]"#,
                hooks: #"transform: function (clip) { return clip.text.toUpperCase(); }"#
            )
        ).get()
        _ = try catalog.install(
            source: menuScript(
                id: linkID,
                types: ["link"],
                menuItems: #"[{ title: "Reveal", verb: "revealInFinder" }]"#
            )
        ).get()
        _ = try catalog.install(
            source: menuScript(
                id: disabledID,
                menuItems: #"[{ title: "Disabled", verb: "revealInFinder" }]"#
            )
        ).get()
        catalog.setEnabled(true, id: textID)
        catalog.setEnabled(true, id: linkID)

        XCTAssertEqual(
            catalog.menuEntries(for: "text").map {
                "\($0.installedExtension.id):\($0.menuItem.title)"
            },
            ["\(textID):Copy Edited"]
        )
        XCTAssertEqual(
            catalog.menuEntries(for: "link").map { $0.installedExtension.id },
            [linkID]
        )
        XCTAssertTrue(catalog.menuEntries(for: "image").isEmpty)

        catalog.setEnabled(true, id: disabledID)
        XCTAssertEqual(
            catalog.menuEntries(for: "image").map { $0.installedExtension.id },
            [disabledID]
        )

        let reloaded = ExtensionCatalog(directory: directory)
        XCTAssertEqual(
            reloaded.extensions.first(where: { $0.id == textID })?.manifest.menuItems,
            [ExtensionMenuItem(title: "Copy Edited", verb: .copyTransformed)]
        )

        let slowID = "com.example.quarantined-menu"
        let slowSource = menuScript(
            id: slowID,
            types: ["text"],
            menuItems: #"[{ title: "Reveal", verb: "revealInFinder" }]"#,
            hooks: #"""
            badge: function (clip) {
              var deadline = Date.now() + 250;
              while (Date.now() < deadline) {}
              return "late";
            }
            """#
        )
        _ = try catalog.install(source: slowSource).get()
        catalog.setEnabled(true, id: slowID)
        let slowExtension = try XCTUnwrap(catalog.extensions.first { $0.id == slowID })
        let invalidated = expectation(description: "menu extension quarantined")
        catalog.onExtensionInvalidated = { id in
            if id == slowID { invalidated.fulfill() }
        }
        XCTAssertEqual(
            catalog.menuEntries(for: "text").map { $0.installedExtension.id },
            [textID, disabledID, slowID]
        )

        XCTAssertEqual(
            host.badgeSync(
                clipType: "text",
                text: "hello",
                extension: slowExtension
            ),
            .failure(.timedOut)
        )
        wait(for: [invalidated], timeout: 1)

        XCTAssertTrue(catalog.isQuarantined(slowID))
        XCTAssertEqual(
            catalog.menuEntries(for: "text").map { $0.installedExtension.id },
            [textID, disabledID]
        )
    }

    func testQuarantineAutoDisablesAndPersistsAcrossReload() throws {
        let host = ExtensionHost()
        let alerting = QuarantineAlertingSpy()
        let catalog = ExtensionCatalog(
            directory: directory,
            host: host,
            quarantineAlerting: alerting
        )
        let extensionID = "com.example.catalog-quarantine"
        let source = script(
            id: extensionID,
            badgeBody: "var deadline = Date.now() + 250; while (Date.now() < deadline) {}"
        )
        _ = catalog.install(source: source)
        catalog.setEnabled(true, id: extensionID)
        let invalidated = expectation(description: "quarantined extension invalidated")
        catalog.onExtensionInvalidated = { id in
            if id == extensionID { invalidated.fulfill() }
        }
        let installedExtension = try XCTUnwrap(
            catalog.extensions.first(where: { $0.id == extensionID })
        )

        XCTAssertFalse(catalog.isQuarantined(extensionID))
        XCTAssertTrue(catalog.enabledExtensions.contains { $0.id == extensionID })
        XCTAssertEqual(
            host.badgeSync(
                clipType: "text",
                text: "hello",
                extension: installedExtension
            ),
            .failure(.timedOut)
        )
        wait(for: [invalidated], timeout: 1)

        XCTAssertTrue(catalog.isQuarantined(extensionID))
        XCTAssertFalse(catalog.enabledExtensions.contains { $0.id == extensionID })
        let autoDisabled = try XCTUnwrap(
            catalog.extensions.first(where: { $0.id == extensionID })
        )
        XCTAssertFalse(autoDisabled.enabled)
        XCTAssertNotNil(autoDisabled.autoDisabledAt)
        XCTAssertEqual(autoDisabled.autoDisableReason, .timedOut)
        XCTAssertEqual(
            alerting.alerts,
            [
                QuarantineAlertingSpy.Alert(
                    extensionID: extensionID,
                    extensionName: "Example",
                    reason: .timedOut
                )
            ]
        )

        XCTAssertEqual(
            host.badgeSync(
                clipType: "text",
                text: "hello",
                extension: installedExtension
            ),
            .success(nil)
        )
        XCTAssertEqual(alerting.alerts.count, 1)

        let storedData = try Data(
            contentsOf: directory.appendingPathComponent("extensions.json")
        )
        let stored = try JSONDecoder().decode([InstalledExtension].self, from: storedData)
        let storedExtension = try XCTUnwrap(stored.first(where: { $0.id == extensionID }))
        XCTAssertFalse(storedExtension.enabled)
        XCTAssertEqual(storedExtension.autoDisabledAt, autoDisabled.autoDisabledAt)
        XCTAssertEqual(storedExtension.autoDisableReason, .timedOut)

        let reloaded = ExtensionCatalog(directory: directory, host: ExtensionHost())
        let reloadedExtension = try XCTUnwrap(
            reloaded.extensions.first(where: { $0.id == extensionID })
        )
        XCTAssertFalse(reloadedExtension.enabled)
        XCTAssertEqual(reloadedExtension.autoDisabledAt, autoDisabled.autoDisabledAt)
        XCTAssertEqual(reloadedExtension.autoDisableReason, .timedOut)
    }

    func testReenableClearsAutoDisableAndLiftsHostQuarantine() throws {
        let host = ExtensionHost()
        let catalog = ExtensionCatalog(directory: directory, host: host)
        let extensionID = "com.example.catalog-reenable"
        let timeoutSource = script(
            id: extensionID,
            badgeBody: "var deadline = Date.now() + 250; while (Date.now() < deadline) {}"
        )
        _ = catalog.install(source: timeoutSource)
        catalog.setEnabled(true, id: extensionID)
        let invalidated = expectation(description: "quarantined extension invalidated")
        catalog.onExtensionInvalidated = { id in
            if id == extensionID { invalidated.fulfill() }
        }
        let timedOutExtension = try XCTUnwrap(
            catalog.extensions.first(where: { $0.id == extensionID })
        )

        XCTAssertEqual(
            host.badgeSync(
                clipType: "text",
                text: "hello",
                extension: timedOutExtension
            ),
            .failure(.timedOut)
        )
        wait(for: [invalidated], timeout: 1)
        catalog.onExtensionInvalidated = nil
        XCTAssertTrue(host.isQuarantined(extensionID))

        let validSource = script(
            id: extensionID,
            badgeBody: #"return "recovered";"#
        )
        _ = catalog.install(source: validSource)
        catalog.setEnabled(true, id: extensionID)

        let reenabled = try XCTUnwrap(
            catalog.extensions.first(where: { $0.id == extensionID })
        )
        XCTAssertTrue(reenabled.enabled)
        XCTAssertNil(reenabled.autoDisabledAt)
        XCTAssertNil(reenabled.autoDisableReason)
        XCTAssertFalse(host.isQuarantined(extensionID))
        XCTAssertEqual(
            host.badgeSync(
                clipType: "text",
                text: "hello",
                extension: reenabled
            ),
            .success("recovered")
        )

        let storedData = try Data(
            contentsOf: directory.appendingPathComponent("extensions.json")
        )
        let stored = try JSONDecoder().decode([InstalledExtension].self, from: storedData)
        XCTAssertNil(stored.first(where: { $0.id == extensionID })?.autoDisabledAt)
        XCTAssertNil(stored.first(where: { $0.id == extensionID })?.autoDisableReason)
    }

    func testRepeatedFailureAlertPostsAgainAfterReenable() throws {
        let host = ExtensionHost()
        let alerting = QuarantineAlertingSpy()
        let catalog = ExtensionCatalog(
            directory: directory,
            host: host,
            quarantineAlerting: alerting
        )
        let extensionID = "com.example.catalog-repeat-quarantine"
        _ = catalog.install(
            source: script(
                id: extensionID,
                badgeBody: #"throw new Error("nope");"#
            )
        )
        catalog.setEnabled(true, id: extensionID)

        let firstInvalidation = expectation(description: "first quarantine invalidated")
        catalog.onExtensionInvalidated = { id in
            if id == extensionID { firstInvalidation.fulfill() }
        }
        let firstRun = try XCTUnwrap(
            catalog.extensions.first(where: { $0.id == extensionID })
        )
        for _ in 0..<5 {
            _ = host.badgeSync(
                clipType: "text",
                text: "hello",
                extension: firstRun
            )
        }
        wait(for: [firstInvalidation], timeout: 1)

        XCTAssertEqual(alerting.alerts.count, 1)
        XCTAssertEqual(alerting.alerts.first?.extensionID, extensionID)
        XCTAssertEqual(alerting.alerts.first?.extensionName, "Example")
        XCTAssertEqual(alerting.alerts.first?.reason, .repeatedExceptions)
        XCTAssertEqual(
            catalog.extensions.first(where: { $0.id == extensionID })?.autoDisableReason,
            .repeatedExceptions
        )

        catalog.onExtensionInvalidated = nil
        catalog.setEnabled(true, id: extensionID)
        let reenabled = try XCTUnwrap(
            catalog.extensions.first(where: { $0.id == extensionID })
        )
        XCTAssertTrue(reenabled.enabled)
        XCTAssertNil(reenabled.autoDisabledAt)
        XCTAssertNil(reenabled.autoDisableReason)

        let secondInvalidation = expectation(description: "second quarantine invalidated")
        catalog.onExtensionInvalidated = { id in
            if id == extensionID { secondInvalidation.fulfill() }
        }
        for _ in 0..<5 {
            _ = host.badgeSync(
                clipType: "text",
                text: "hello",
                extension: reenabled
            )
        }
        wait(for: [secondInvalidation], timeout: 1)

        XCTAssertEqual(alerting.alerts.count, 2)
        XCTAssertEqual(alerting.alerts.last?.reason, .repeatedExceptions)
    }

    func testConfigValueAndInstalledSettingsCodableRoundTrips() throws {
        let values: [ExtensionConfigValue] = [
            .boolean(true),
            .number(2.5),
            .string(#"quotes " slashes \\ and script </script>"#)
        ]
        for value in values {
            let data = try JSONEncoder().encode(value)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(object.count, 1)
            XCTAssertEqual(try JSONDecoder().decode(ExtensionConfigValue.self, from: data), value)
        }

        let manifest = ExtensionManifest(
            id: "com.example.codable-config",
            name: "Codable Config",
            version: "1.0",
            api: 1,
            hooks: ["badge"],
            config: [
                ExtensionConfigField(
                    key: "enabled",
                    type: .boolean,
                    label: "Enabled",
                    defaultValue: .boolean(false)
                ),
                ExtensionConfigField(
                    key: "mode",
                    type: .choice,
                    label: "Mode",
                    defaultValue: .string("a"),
                    options: ["a", "b"]
                )
            ]
        )
        let installedExtension = InstalledExtension(
            manifest: manifest,
            source: "source",
            enabled: true,
            isBundled: false,
            installedAt: Date(timeIntervalSince1970: 123),
            settings: ["enabled": .boolean(true), "mode": .string("b")]
        )

        let data = try JSONEncoder().encode(installedExtension)
        XCTAssertEqual(
            try JSONDecoder().decode(InstalledExtension.self, from: data),
            installedExtension
        )
    }

    func testSetSettingValidatesPersistsAndInvalidates() throws {
        let extensionID = "com.example.settings"
        let catalog = ExtensionCatalog(directory: directory)
        _ = try catalog.install(
            source: configScript(
                id: extensionID,
                config: #"""
                [
                  { key: "flag", type: "boolean", label: "Flag", default: false },
                  { key: "ratio", type: "number", label: "Ratio", default: 1 },
                  { key: "suffix", type: "string", label: "Suffix", default: "old" },
                  { key: "mode", type: "choice", label: "Mode", default: "slow",
                    options: ["slow", "fast"] }
                ]
                """#
            )
        ).get()
        var invalidatedIDs: [String] = []
        catalog.onExtensionInvalidated = { invalidatedIDs.append($0) }

        catalog.setSetting(.boolean(true), forKey: "flag", id: extensionID)
        catalog.setSetting(.number(2.5), forKey: "ratio", id: extensionID)
        catalog.setSetting(.string("new"), forKey: "suffix", id: extensionID)
        catalog.setSetting(.string("fast"), forKey: "mode", id: extensionID)

        let expected: [String: ExtensionConfigValue] = [
            "flag": .boolean(true),
            "ratio": .number(2.5),
            "suffix": .string("new"),
            "mode": .string("fast")
        ]
        XCTAssertEqual(catalog.effectiveSettings(for: extensionID), expected)
        XCTAssertEqual(invalidatedIDs, Array(repeating: extensionID, count: 4))

        let storeURL = directory.appendingPathComponent("extensions.json")
        let dataBeforeRejectedValues = try Data(contentsOf: storeURL)
        catalog.setSetting(.string("wrong"), forKey: "flag", id: extensionID)
        catalog.setSetting(.string("wrong"), forKey: "ratio", id: extensionID)
        catalog.setSetting(.number(.infinity), forKey: "ratio", id: extensionID)
        catalog.setSetting(
            .string(String(repeating: "x", count: 201)),
            forKey: "suffix",
            id: extensionID
        )
        catalog.setSetting(.string("unknown"), forKey: "mode", id: extensionID)
        catalog.setSetting(.string("value"), forKey: "missing", id: extensionID)
        catalog.setSetting(.boolean(true), forKey: "flag", id: extensionID)

        XCTAssertEqual(catalog.effectiveSettings(for: extensionID), expected)
        XCTAssertEqual(invalidatedIDs, Array(repeating: extensionID, count: 4))
        XCTAssertEqual(try Data(contentsOf: storeURL), dataBeforeRejectedValues)

        let reloaded = ExtensionCatalog(directory: directory)
        XCTAssertEqual(reloaded.effectiveSettings(for: extensionID), expected)
        XCTAssertEqual(
            reloaded.extensions.first(where: { $0.id == extensionID })?.settings,
            expected
        )
    }

    func testEffectiveSettingsUsesDefaultsAndDropsInvalidStoredKeys() throws {
        let extensionID = "com.example.effective-settings"
        let host = ExtensionHost()
        let source = configScript(
            id: extensionID,
            config: #"""
            [
              { key: "flag", type: "boolean", label: "Flag", default: false },
              { key: "mode", type: "choice", label: "Mode", default: "a",
                options: ["a", "b"] }
            ]
            """#
        )
        let manifest = try host.validate(source: source).get()
        let installedExtension = InstalledExtension(
            manifest: manifest,
            source: source,
            enabled: true,
            isBundled: false,
            installedAt: .now,
            settings: [
                "flag": .string("wrong type"),
                "mode": .string("removed option"),
                "removed": .string("stale")
            ]
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([installedExtension]).write(
            to: directory.appendingPathComponent("extensions.json")
        )

        let catalog = ExtensionCatalog(directory: directory, host: host)

        XCTAssertEqual(
            catalog.effectiveSettings(for: extensionID),
            ["flag": .boolean(false), "mode": .string("a")]
        )
        XCTAssertTrue(catalog.effectiveSettings(for: "missing").isEmpty)
    }

    func testSameIDReinstallPrunesSettingsAgainstNewSchema() throws {
        let extensionID = "com.example.reinstall-settings"
        let catalog = ExtensionCatalog(directory: directory)
        _ = try catalog.install(
            source: configScript(
                id: extensionID,
                version: "1.0",
                config: #"""
                [
                  { key: "flag", type: "boolean", label: "Flag", default: false },
                  { key: "mode", type: "choice", label: "Mode", default: "a",
                    options: ["a", "b"] },
                  { key: "removed", type: "string", label: "Removed", default: "old" }
                ]
                """#
            )
        ).get()
        catalog.setSetting(.boolean(true), forKey: "flag", id: extensionID)
        catalog.setSetting(.string("b"), forKey: "mode", id: extensionID)
        catalog.setSetting(.string("saved"), forKey: "removed", id: extensionID)

        _ = try catalog.install(
            source: configScript(
                id: extensionID,
                version: "2.0",
                config: #"""
                [
                  { key: "flag", type: "boolean", label: "Flag", default: false },
                  { key: "mode", type: "choice", label: "Mode", default: "c",
                    options: ["b", "c"] },
                  { key: "ratio", type: "number", label: "Ratio", default: 4 }
                ]
                """#
            )
        ).get()

        let installedExtension = try XCTUnwrap(
            catalog.extensions.first(where: { $0.id == extensionID })
        )
        XCTAssertEqual(
            installedExtension.settings,
            ["flag": .boolean(true), "mode": .string("b")]
        )
        XCTAssertEqual(
            catalog.effectiveSettings(for: extensionID),
            ["flag": .boolean(true), "mode": .string("b"), "ratio": .number(4)]
        )

        let reloaded = ExtensionCatalog(directory: directory)
        XCTAssertEqual(reloaded.extensions.first(where: { $0.id == extensionID })?.settings,
                       installedExtension.settings)
    }

    func testInstalledExtensionDecodesOldJSONWithoutAutoDisabledAt() throws {
        let fixture = #"""
        [
          {
            "manifest": {
              "id": "com.example.legacy",
              "name": "Legacy",
              "version": "1.0",
              "api": 1
            },
            "source": "pesty.register({});",
            "enabled": true,
            "isBundled": false,
            "installedAt": 0
          }
        ]
        """#

        let decoded = try JSONDecoder().decode(
            [InstalledExtension].self,
            from: Data(fixture.utf8)
        )
        let installedExtension = try XCTUnwrap(decoded.first)

        XCTAssertEqual(installedExtension.id, "com.example.legacy")
        XCTAssertTrue(installedExtension.enabled)
        XCTAssertNil(installedExtension.autoDisabledAt)
        XCTAssertNil(installedExtension.autoDisableReason)
        XCTAssertEqual(installedExtension.manifest.weight, 0)
        XCTAssertNil(installedExtension.manifest.types)
        XCTAssertTrue(installedExtension.manifest.hooks.isEmpty)
        XCTAssertEqual(installedExtension.manifest.effectiveHooks, ["badge"])
        XCTAssertTrue(installedExtension.manifest.config.isEmpty)
        XCTAssertTrue(installedExtension.manifest.menuItems.isEmpty)
        XCTAssertTrue(installedExtension.settings.isEmpty)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }

    private func script(
        id: String,
        version: String = "1.0",
        badgeBody: String = #"return "badge";"#
    ) -> String {
        """
        pesty.register({
          id: "\(id)",
          name: "Example",
          version: "\(version)",
          api: 1,
          badge: function (clip) { \(badgeBody) }
        });
        """
    }

    private func configScript(
        id: String,
        version: String = "1.0",
        config: String
    ) -> String {
        """
        pesty.register({
          id: "\(id)",
          name: "Config",
          version: "\(version)",
          api: 1,
          config: \(config),
          badge: function (clip) { return "ok"; }
        });
        """
    }

    private func menuScript(
        id: String,
        types: [String]? = nil,
        menuItems: String,
        hooks: String = #"badge: function (clip) { return "ok"; }"#
    ) -> String {
        let typesSource = types.map { values in
            let entries = values.map { "\"\($0)\"" }.joined(separator: ", ")
            return "types: [\(entries)],"
        } ?? ""
        return """
        pesty.register({
          id: "\(id)",
          name: "Menu",
          version: "1.0",
          api: 1,
          \(typesSource)
          menuItems: \(menuItems),
          \(hooks)
        });
        """
    }
}

@MainActor
private final class QuarantineAlertingSpy: QuarantineAlerting {
    struct Alert: Equatable {
        let extensionID: String
        let extensionName: String
        let reason: ExtensionQuarantineReason
    }

    private(set) var alerts: [Alert] = []

    func postQuarantineAlert(
        extensionID: String,
        extensionName: String,
        reason: ExtensionQuarantineReason
    ) {
        alerts.append(
            Alert(
                extensionID: extensionID,
                extensionName: extensionName,
                reason: reason
            )
        )
    }
}
