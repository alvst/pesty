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

    func testFreshCatalogSeedsBundledExtensionDisabled() throws {
        let catalog = ExtensionCatalog(directory: directory)
        let bundled = try XCTUnwrap(catalog.extensions.first)

        XCTAssertEqual(catalog.extensions.count, 1)
        XCTAssertEqual(bundled.id, "com.alvst.pesty-alvie.token-count")
        XCTAssertTrue(bundled.isBundled)
        XCTAssertFalse(bundled.enabled)
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
                    api: 1
                )
            )
        )

        let storeURL = directory.appendingPathComponent("extensions.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        XCTAssertEqual(try permissions(of: directory), 0o700)
        XCTAssertEqual(try permissions(of: storeURL), 0o600)
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

    func testUninstalledBundledExtensionIsNotReseeded() {
        let catalog = ExtensionCatalog(directory: directory)
        catalog.uninstall(id: "com.alvst.pesty-alvie.token-count")

        let reloaded = ExtensionCatalog(directory: directory)

        XCTAssertTrue(reloaded.extensions.isEmpty)
    }

    func testSetEnabledPersistsAcrossReload() {
        let catalog = ExtensionCatalog(directory: directory)
        catalog.setEnabled(true, id: "com.alvst.pesty-alvie.token-count")

        let reloaded = ExtensionCatalog(directory: directory)

        XCTAssertTrue(reloaded.extensions.first?.enabled == true)
        XCTAssertEqual(reloaded.enabledExtensions.map(\.id), ["com.alvst.pesty-alvie.token-count"])
    }

    func testQuarantineDelegatesToInjectedHostAndExcludesEnabledExtension() throws {
        let host = ExtensionHost()
        let catalog = ExtensionCatalog(directory: directory, host: host)
        let extensionID = "com.example.catalog-quarantine"
        let source = script(
            id: extensionID,
            badgeBody: "var deadline = Date.now() + 250; while (Date.now() < deadline) {}"
        )
        _ = catalog.install(source: source)
        catalog.setEnabled(true, id: extensionID)
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
        XCTAssertTrue(catalog.isQuarantined(extensionID))
        XCTAssertFalse(catalog.enabledExtensions.contains { $0.id == extensionID })
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
