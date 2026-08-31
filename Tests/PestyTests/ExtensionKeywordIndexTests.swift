import XCTest
@testable import Pesty

@MainActor
final class ExtensionKeywordIndexTests: XCTestCase {
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

    func testPersistLoadRoundTripUsesPrivateSidecar() async throws {
        let host = ExtensionHost()
        let catalog = ExtensionCatalog(directory: directory, host: host)
        let installedExtension = try install(
            id: "com.example.persisted-keywords",
            body: #"return ["Alpha", clip.text];"#,
            in: catalog
        )
        let clip = ClipItem(type: .text, text: "Payload")
        let index = makeIndex(clips: [clip], catalog: catalog, host: host)

        await waitUntil {
            !index.isSweepActive
                && index.cachedKeywords(
                    for: clip.id,
                    extensionID: installedExtension.id
                ) != nil
        }
        XCTAssertEqual(
            index.cachedKeywords(for: clip.id, extensionID: installedExtension.id),
            ["alpha", "payload"]
        )
        index.saveNow()

        let storeURL = directory.appendingPathComponent("extension-keywords.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        XCTAssertEqual(try permissions(of: storeURL), 0o600)

        let reloaded = makeIndex(clips: [clip], catalog: catalog, host: host)
        XCTAssertEqual(
            reloaded.cachedKeywords(for: clip.id, extensionID: installedExtension.id),
            ["alpha", "payload"]
        )
    }

    func testLoadPrunesMissingClipsAndChangedSourceFingerprints() async throws {
        let host = ExtensionHost()
        let catalog = ExtensionCatalog(directory: directory, host: host)
        let stable = try install(
            id: "com.example.stable-keywords",
            body: #"return ["stable"];"#,
            in: catalog
        )
        let changing = try install(
            id: "com.example.changing-keywords",
            body: #"return ["old"];"#,
            in: catalog
        )
        let retainedClip = ClipItem(type: .text, text: "retained")
        let removedClip = ClipItem(type: .text, text: "removed")
        let original = makeIndex(
            clips: [retainedClip, removedClip],
            catalog: catalog,
            host: host
        )

        await waitUntil { !original.isSweepActive && original.cachedPairCount == 4 }
        original.saveNow()
        _ = try catalog.install(
            source: keywordScript(
                id: changing.id,
                version: "2.0",
                body: #"return ["new"];"#
            )
        ).get()

        let reloaded = makeIndex(clips: [retainedClip], catalog: catalog, host: host)

        XCTAssertEqual(
            reloaded.cachedKeywords(for: retainedClip.id, extensionID: stable.id),
            ["stable"]
        )
        XCTAssertNil(
            reloaded.cachedKeywords(for: removedClip.id, extensionID: stable.id)
        )
        XCTAssertNil(
            reloaded.cachedKeywords(for: retainedClip.id, extensionID: changing.id)
        )
        XCTAssertEqual(reloaded.cachedPairCount, 1)
    }

    func testResultStoreForwardsForgetForgetAllAndPurge() async throws {
        let host = ExtensionHost()
        let catalog = ExtensionCatalog(directory: directory, host: host)
        let installedExtension = try install(
            id: "com.example.forwarded-eviction",
            body: #"return [clip.text];"#,
            in: catalog
        )
        let first = ClipItem(type: .text, text: "first")
        let second = ClipItem(type: .text, text: "second")
        var clips = [first, second]
        let index = makeIndex(
            clipsProvider: { clips },
            catalog: catalog,
            host: host
        )
        let resultStore = ExtensionResultStore(catalog: catalog, host: host)
        resultStore.attachKeywordIndex(index)

        await waitUntil { !index.isSweepActive && index.cachedPairCount == 2 }
        clips.removeAll { $0.id == first.id }
        resultStore.forget(first.id)
        XCTAssertNil(
            index.cachedKeywords(for: first.id, extensionID: installedExtension.id)
        )
        XCTAssertNotNil(
            index.cachedKeywords(for: second.id, extensionID: installedExtension.id)
        )

        resultStore.purge(extensionID: installedExtension.id)
        XCTAssertNil(
            index.cachedKeywords(for: second.id, extensionID: installedExtension.id)
        )
        await waitUntil { !index.isSweepActive && index.cachedPairCount == 1 }

        resultStore.forgetAll()
        XCTAssertEqual(index.cachedPairCount, 0)
    }

    func testEnableEventSweepsMoreThanOneChunkAndStopsWhenComplete() async throws {
        let host = ExtensionHost()
        let catalog = ExtensionCatalog(directory: directory, host: host)
        let installedExtension = try install(
            id: "com.example.chunked-keywords",
            body: #"return [clip.text];"#,
            enabled: false,
            in: catalog
        )
        let clips = (0..<30).map { ClipItem(type: .text, text: "Clip \($0)") }
        let index = makeIndex(clips: clips, catalog: catalog, host: host)
        let resultStore = ExtensionResultStore(catalog: catalog, host: host)
        resultStore.attachKeywordIndex(index)

        XCTAssertFalse(index.isSweepActive)
        catalog.setEnabled(true, id: installedExtension.id)
        await waitUntil { !index.isSweepActive && index.cachedPairCount == 30 }

        XCTAssertEqual(
            index.cachedKeywords(for: clips[29].id, extensionID: installedExtension.id),
            ["clip 29"]
        )
        index.scheduleSweep()
        XCTAssertFalse(index.isSweepActive)
    }

    func testStoreSaveNotificationDebouncesSweepForNewClips() async throws {
        let host = ExtensionHost()
        let catalog = ExtensionCatalog(directory: directory, host: host)
        let installedExtension = try install(
            id: "com.example.store-save-keywords",
            body: #"return [clip.text];"#,
            in: catalog
        )
        let first = ClipItem(type: .text, text: "first")
        let second = ClipItem(type: .text, text: "second")
        var clips = [first]
        let center = NotificationCenter()
        let index = makeIndex(
            clipsProvider: { clips },
            catalog: catalog,
            host: host,
            notificationCenter: center
        )
        await waitUntil { !index.isSweepActive && index.cachedPairCount == 1 }

        clips.append(second)
        center.post(name: .pestyStoreDidSave, object: nil)

        await waitUntil {
            !index.isSweepActive
                && index.cachedKeywords(
                    for: second.id,
                    extensionID: installedExtension.id
                ) == ["second"]
        }
    }

    func testFingerprintChangeMidFlightDropsStaleWrite() async throws {
        let host = ExtensionHost()
        let catalog = ExtensionCatalog(directory: directory, host: host)
        let extensionID = "com.example.stale-keywords"
        _ = try install(
            id: extensionID,
            body: #"var start = Date.now(); while (Date.now() - start < 50) {} return ["old"];"#,
            in: catalog
        )
        let clip = ClipItem(type: .text, text: "payload")
        let index = makeIndex(clips: [clip], catalog: catalog, host: host)

        _ = try catalog.install(
            source: keywordScript(
                id: extensionID,
                version: "2.0",
                body: #"return ["new"];"#
            )
        ).get()

        await waitUntil {
            !index.isSweepActive
                && index.cachedKeywords(for: clip.id, extensionID: extensionID) == ["new"]
        }
        XCTAssertEqual(index.contentVersion, 1)
    }

    func testMatchesAndSearchPredicateUseKeywordSubstringsCaseInsensitively() async throws {
        let host = ExtensionHost()
        let catalog = ExtensionCatalog(directory: directory, host: host)
        _ = try install(
            id: "com.example.searchable-keywords",
            body: #"return ["MixedCaseCategory", "JSON"];"#,
            in: catalog
        )
        let keywordClip = ClipItem(type: .text, text: "literal text")
        var titleClip = ClipItem(type: .text, text: "other text")
        titleClip.customTitle = "Visible Title"
        let index = makeIndex(clips: [keywordClip, titleClip], catalog: catalog, host: host)
        await waitUntil { !index.isSweepActive && index.cachedPairCount == 2 }

        XCTAssertTrue(
            index.matches(keywordClip.id, query: TextSearch.Query("CASEC".lowercased()))
        )
        XCTAssertTrue(index.matches(keywordClip.id, query: TextSearch.Query("son")))
        XCTAssertFalse(index.matches(keywordClip.id, query: TextSearch.Query("missing")))
        XCTAssertTrue(
            ExtensionSearchPredicate.matches(
                keywordClip,
                query: TextSearch.Query("json"),
                keywordIndex: index
            )
        )
        XCTAssertTrue(
            ExtensionSearchPredicate.matches(
                titleClip,
                query: TextSearch.Query("visible"),
                keywordIndex: index
            )
        )
    }

    func testSearchPredicateStaysFastAcrossFiveThousandSyntheticClips() throws {
        let host = ExtensionHost()
        let catalog = ExtensionCatalog(directory: directory, host: host)
        let installedExtension = try install(
            id: "com.example.performance-keywords",
            body: #"return ["unused"];"#,
            in: catalog
        )
        let clips = (0..<5_000).map {
            ClipItem(type: .text, text: "ordinary clip \($0)")
        }
        let persistedEntries = Dictionary(
            uniqueKeysWithValues: clips.enumerated().map { index, clip in
                let keyword = index.isMultiple(of: 10) ? "needle-tag" : "other-tag"
                return (clip.id.uuidString, [installedExtension.id: [keyword]])
            }
        )
        let state = ExtensionKeywordIndex.PersistedState(
            entries: persistedEntries,
            sourceFingerprints: [
                installedExtension.id: ExtensionKeywordIndex.sourceFingerprint(
                    for: installedExtension.source
                )
            ]
        )
        let data = try JSONEncoder().encode(state)
        try data.write(
            to: directory.appendingPathComponent("extension-keywords.json"),
            options: .atomic
        )
        let index = makeIndex(clips: clips, catalog: catalog, host: host)
        XCTAssertEqual(index.cachedPairCount, 5_000)

        let query = TextSearch.Query("needle")
        let startedAt = ProcessInfo.processInfo.systemUptime
        var matchCount = 0
        for clip in clips where ExtensionSearchPredicate.matches(
            clip,
            query: query,
            keywordIndex: index
        ) {
            matchCount += 1
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        XCTAssertEqual(matchCount, 500)
        XCTAssertLessThan(
            elapsed,
            0.1,
            "5,000 indexed predicates took \(elapsed)s, exceeding a keystroke budget"
        )
    }

    private func makeIndex(
        clips: [ClipItem],
        catalog: ExtensionCatalog,
        host: ExtensionHost
    ) -> ExtensionKeywordIndex {
        makeIndex(clipsProvider: { clips }, catalog: catalog, host: host)
    }

    private func makeIndex(
        clipsProvider: @escaping () -> [ClipItem],
        catalog: ExtensionCatalog,
        host: ExtensionHost,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> ExtensionKeywordIndex {
        ExtensionKeywordIndex(
            directory: directory,
            catalog: catalog,
            host: host,
            clipsProvider: clipsProvider,
            notificationCenter: notificationCenter,
            saveDelay: 0.01,
            storeSaveDebounce: 0.01,
            chunkDelay: 0.01
        )
    }

    @discardableResult
    private func install(
        id: String,
        version: String = "1.0",
        body: String,
        enabled: Bool = true,
        in catalog: ExtensionCatalog
    ) throws -> InstalledExtension {
        let manifest = try catalog.install(
            source: keywordScript(id: id, version: version, body: body)
        ).get()
        if enabled {
            catalog.setEnabled(true, id: id)
        }
        return try XCTUnwrap(catalog.extensions.first(where: { $0.id == manifest.id }))
    }

    private func keywordScript(id: String, version: String = "1.0", body: String) -> String {
        """
        pesty.register({
          id: "\(id)",
          name: "Keywords",
          version: "\(version)",
          api: 1,
          keywords: function (clip) { \(body) }
        });
        """
    }

    private func waitUntil(
        timeout: TimeInterval = 8,
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

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }
}
