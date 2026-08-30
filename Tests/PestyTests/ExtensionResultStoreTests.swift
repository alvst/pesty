import XCTest
@testable import Pesty

@MainActor
final class ExtensionResultStoreTests: XCTestCase {
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

    func testBadgeIsCachedAfterRequest() async throws {
        let (host, catalog, store) = makeSystem()
        let extensionID = "com.example.cached"
        _ = try install(
            id: extensionID,
            badgeBody: #"return "cached";"#,
            in: catalog
        )
        let item = ClipItem(type: .text, text: "hello")

        store.requestBadges(for: item)
        await waitUntil { store.hasCachedOutcome(for: item.id, extensionID: extensionID) }

        XCTAssertEqual(store.badges(for: item.id), ["cached"])
        XCTAssertEqual(store.pendingEvaluationCount, 0)
        _ = host
    }

    func testNilOutcomeIsCachedAndNotRequestedAgain() async throws {
        let (_, catalog, store) = makeSystem()
        let extensionID = "com.example.nil"
        _ = try install(id: extensionID, badgeBody: "return null;", in: catalog)
        let item = ClipItem(type: .image)

        store.requestBadges(for: item)
        await waitUntil { store.hasCachedOutcome(for: item.id, extensionID: extensionID) }
        XCTAssertTrue(store.badges(for: item.id).isEmpty)

        store.requestBadges(for: item)
        // A new request would remain in flight until this MainActor turn ends.
        XCTAssertEqual(store.pendingEvaluationCount, 0)
    }

    func testDuplicateRequestsShareOneInFlightEvaluation() async throws {
        let (_, catalog, store) = makeSystem()
        let extensionID = "com.example.dedup"
        _ = try install(id: extensionID, badgeBody: #"return "one";"#, in: catalog)
        let item = ClipItem(type: .text, text: "hello")

        store.requestBadges(for: item)
        store.requestBadges(for: item)

        XCTAssertEqual(store.pendingEvaluationCount, 1)
        await waitUntil { store.pendingEvaluationCount == 0 }
        XCTAssertEqual(store.badges(for: item.id), ["one"])
    }

    func testForgetPreventsLateCompletionFromRepopulatingCache() async throws {
        let (_, catalog, store) = makeSystem()
        let extensionID = "com.example.late-completion"
        _ = try install(id: extensionID, badgeBody: "return clip.text;", in: catalog)
        let forgotten = ClipItem(type: .text, text: "forgotten")
        let retained = ClipItem(type: .text, text: "retained")

        store.requestBadges(for: forgotten)
        store.forget(forgotten.id)
        store.requestBadges(for: retained)
        await waitUntil { store.hasCachedOutcome(for: retained.id, extensionID: extensionID) }

        XCTAssertFalse(store.hasCachedOutcome(for: forgotten.id, extensionID: extensionID))
        XCTAssertEqual(store.badges(for: retained.id), ["retained"])
    }

    func testForgetForgetAllAndPurgeRemoveOnlyTheirTargets() async throws {
        let (_, catalog, store) = makeSystem()
        let alphaID = "com.example.alpha"
        let betaID = "com.example.beta"
        _ = try install(id: alphaID, badgeBody: #"return "alpha";"#, in: catalog)
        _ = try install(id: betaID, badgeBody: #"return "beta";"#, in: catalog)
        let first = ClipItem(type: .text, text: "first")
        let second = ClipItem(type: .text, text: "second")

        store.requestBadges(for: first)
        store.requestBadges(for: second)
        await waitUntil { store.pendingEvaluationCount == 0 }
        XCTAssertEqual(store.cachedClipCount, 2)

        store.purge(extensionID: alphaID)
        XCTAssertEqual(store.badges(for: first.id), ["beta"])
        XCTAssertEqual(store.badges(for: second.id), ["beta"])

        store.forget(first.id)
        XCTAssertFalse(store.hasCachedOutcome(for: first.id, extensionID: betaID))
        XCTAssertTrue(store.hasCachedOutcome(for: second.id, extensionID: betaID))

        store.forgetAll()
        XCTAssertEqual(store.cachedClipCount, 0)
        XCTAssertEqual(store.pendingEvaluationCount, 0)
    }

    func testCapacityOverflowClearsTheWholeMemoizationCache() async throws {
        let (_, catalog, store) = makeSystem()
        let extensionID = "com.example.capacity"
        _ = try install(id: extensionID, badgeBody: #"return "x";"#, in: catalog)
        let items = (0...512).map { ClipItem(type: .text, text: "item \($0)") }

        for item in items.prefix(512) {
            store.requestBadges(for: item)
        }
        await waitUntil(timeout: 15) { store.pendingEvaluationCount == 0 }
        XCTAssertEqual(store.cachedClipCount, 512)

        store.requestBadges(for: items[512])
        await waitUntil { store.pendingEvaluationCount == 0 }

        XCTAssertEqual(store.cachedClipCount, 1)
        XCTAssertFalse(store.hasCachedOutcome(for: items[0].id, extensionID: extensionID))
        XCTAssertTrue(store.hasCachedOutcome(for: items[512].id, extensionID: extensionID))
    }

    func testDisabledExtensionsAreNotEvaluated() throws {
        let (_, catalog, store) = makeSystem()
        let extensionID = "com.example.disabled"
        _ = try install(
            id: extensionID,
            badgeBody: #"return "hidden";"#,
            enabled: false,
            in: catalog
        )

        store.requestBadges(for: ClipItem(type: .text, text: "hello"))

        XCTAssertEqual(store.pendingEvaluationCount, 0)
        XCTAssertEqual(store.cachedClipCount, 0)
    }

    func testReinstallAndUninstallPurgeCachedResults() async throws {
        let (_, catalog, store) = makeSystem()
        let extensionID = "com.example.replace"
        _ = try install(id: extensionID, badgeBody: #"return "old";"#, in: catalog)
        let item = ClipItem(type: .text, text: "hello")
        store.requestBadges(for: item)
        await waitUntil { store.hasCachedOutcome(for: item.id, extensionID: extensionID) }
        XCTAssertEqual(store.badges(for: item.id), ["old"])

        XCTAssertEqual(
            catalog.install(
                source: script(
                    id: extensionID,
                    version: "2.0",
                    badgeBody: #"return "new";"#
                )
            ),
            .success(
                ExtensionManifest(
                    id: extensionID,
                    name: "Example",
                    version: "2.0",
                    api: 1
                )
            )
        )
        XCTAssertFalse(store.hasCachedOutcome(for: item.id, extensionID: extensionID))

        store.requestBadges(for: item)
        await waitUntil { store.hasCachedOutcome(for: item.id, extensionID: extensionID) }
        XCTAssertEqual(store.badges(for: item.id), ["new"])

        catalog.uninstall(id: extensionID)
        XCTAssertFalse(store.hasCachedOutcome(for: item.id, extensionID: extensionID))
        XCTAssertTrue(store.badges(for: item.id).isEmpty)
    }

    func testDisablingExtensionPurgesCachedResults() async throws {
        let (_, catalog, store) = makeSystem()
        let extensionID = "com.example.disable"
        _ = try install(id: extensionID, badgeBody: #"return "visible";"#, in: catalog)
        let item = ClipItem(type: .text, text: "hello")
        store.requestBadges(for: item)
        await waitUntil { store.hasCachedOutcome(for: item.id, extensionID: extensionID) }

        catalog.setEnabled(false, id: extensionID)

        XCTAssertFalse(store.hasCachedOutcome(for: item.id, extensionID: extensionID))
        XCTAssertTrue(store.badges(for: item.id).isEmpty)
    }

    func testBadgesFollowCatalogOrderAndSkipNilOutcomes() async throws {
        let (_, catalog, store) = makeSystem()
        _ = try install(
            id: "com.example.01-first",
            badgeBody: #"return "first";"#,
            in: catalog
        )
        _ = try install(
            id: "com.example.02-nil",
            badgeBody: "return null;",
            in: catalog
        )
        _ = try install(
            id: "com.example.03-last",
            badgeBody: #"return "last";"#,
            in: catalog
        )
        let item = ClipItem(type: .text, text: "hello")

        store.requestBadges(for: item)
        await waitUntil { store.pendingEvaluationCount == 0 }

        XCTAssertEqual(store.badges(for: item.id), ["first", "last"])
    }

    func testClipTypeRawValuesMatchExtensionAPIAndReachScript() async throws {
        XCTAssertEqual(
            ClipType.allCases.map(\.rawValue),
            ["text", "richText", "link", "image", "file", "color"]
        )
        let (_, catalog, store) = makeSystem()
        let extensionID = "com.example.clip-type"
        _ = try install(id: extensionID, badgeBody: "return clip.type;", in: catalog)
        let item = ClipItem(type: .richText, text: "hello")

        store.requestBadges(for: item)
        await waitUntil { store.pendingEvaluationCount == 0 }

        XCTAssertEqual(store.badges(for: item.id), ["richText"])
    }

    private func makeSystem() -> (ExtensionHost, ExtensionCatalog, ExtensionResultStore) {
        let host = ExtensionHost()
        let catalog = ExtensionCatalog(directory: directory, host: host)
        let store = ExtensionResultStore(catalog: catalog, host: host)
        return (host, catalog, store)
    }

    @discardableResult
    private func install(
        id: String,
        badgeBody: String,
        version: String = "1.0",
        enabled: Bool = true,
        in catalog: ExtensionCatalog
    ) throws -> InstalledExtension {
        let source = script(id: id, version: version, badgeBody: badgeBody)
        guard case .success = catalog.install(source: source) else {
            throw TestError.installFailed
        }
        if enabled { catalog.setEnabled(true, id: id) }
        return try XCTUnwrap(catalog.extensions.first(where: { $0.id == id }))
    }

    private func script(id: String, version: String = "1.0", badgeBody: String) -> String {
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

    private func waitUntil(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "Condition did not become true", file: file, line: line)
    }

    private enum TestError: Error {
        case installFailed
    }
}
