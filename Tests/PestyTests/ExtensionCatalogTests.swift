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
            "com.alvst.pesty-alvie.token-count",
            "com.alvst.pesty-alvie.json-detector"
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
        catalog.uninstall(id: "com.alvst.pesty-alvie.token-count")
        catalog.uninstall(id: "com.alvst.pesty-alvie.json-detector")

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

        XCTAssertEqual(catalog.extensions.map(\.id), ["com.alvst.pesty-alvie.token-count"])
        XCTAssertFalse(catalog.extensions.contains {
            $0.id == "com.alvst.pesty-alvie.json-detector"
        })
    }

    func testSetEnabledPersistsAcrossReload() {
        let catalog = ExtensionCatalog(directory: directory)
        catalog.setEnabled(true, id: "com.alvst.pesty-alvie.token-count")

        let reloaded = ExtensionCatalog(directory: directory)

        XCTAssertTrue(
            reloaded.extensions.first {
                $0.id == "com.alvst.pesty-alvie.token-count"
            }?.enabled == true
        )
        XCTAssertEqual(reloaded.enabledExtensions.map(\.id), ["com.alvst.pesty-alvie.token-count"])
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

    func testQuarantineAutoDisablesAndPersistsAcrossReload() throws {
        let host = ExtensionHost()
        let catalog = ExtensionCatalog(directory: directory, host: host)
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

        let storedData = try Data(
            contentsOf: directory.appendingPathComponent("extensions.json")
        )
        let stored = try JSONDecoder().decode([InstalledExtension].self, from: storedData)
        let storedExtension = try XCTUnwrap(stored.first(where: { $0.id == extensionID }))
        XCTAssertFalse(storedExtension.enabled)
        XCTAssertEqual(storedExtension.autoDisabledAt, autoDisabled.autoDisabledAt)

        let reloaded = ExtensionCatalog(directory: directory, host: ExtensionHost())
        let reloadedExtension = try XCTUnwrap(
            reloaded.extensions.first(where: { $0.id == extensionID })
        )
        XCTAssertFalse(reloadedExtension.enabled)
        XCTAssertEqual(reloadedExtension.autoDisabledAt, autoDisabled.autoDisabledAt)
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
        XCTAssertEqual(installedExtension.manifest.weight, 0)
        XCTAssertNil(installedExtension.manifest.types)
        XCTAssertTrue(installedExtension.manifest.hooks.isEmpty)
        XCTAssertEqual(installedExtension.manifest.effectiveHooks, ["badge"])
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
}
