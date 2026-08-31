import CryptoKit
import Foundation

@MainActor
final class ExtensionKeywordIndex {
    static let shared: ExtensionKeywordIndex = {
        let index = ExtensionKeywordIndex(
            directory: ClipboardStore.localBase.appendingPathComponent(
                "extensions",
                isDirectory: true
            ),
            catalog: ExtensionCatalog.shared,
            host: ExtensionCatalog.sharedHost,
            clipsProvider: {
                let store = ClipboardStore.shared
                return store.history + store.pinboards.flatMap(\.items)
            }
        )
        // Catalog invalidation already has one fan-out point through the
        // result store. Attaching only the production singleton keeps unit
        // result stores independent from this persisted sidecar.
        ExtensionResultStore.shared.attachKeywordIndex(index)
        return index
    }()

    struct PersistedState: Codable, Equatable {
        var entries: [String: [String: [String]]]
        var sourceFingerprints: [String: String]
    }

    private struct ActiveKeywordExtension {
        let installedExtension: InstalledExtension
        let fingerprint: String
    }

    private struct PairKey: Hashable {
        let clipID: UUID
        let extensionID: String
    }

    private struct SweepPair {
        let item: ClipItem
        let installedExtension: InstalledExtension
        let fingerprint: String
        let settings: [String: ExtensionConfigValue]
        let invalidationGeneration: UInt64
    }

    private static let chunkSize = 25

    private let directory: URL
    private let storeURL: URL
    private let catalog: ExtensionCatalog
    private let host: ExtensionHost
    private let clipsProvider: () -> [ClipItem]
    private let notificationCenter: NotificationCenter
    private let saveDelay: TimeInterval
    private let storeSaveDebounce: TimeInterval
    private let chunkDelay: TimeInterval

    private var entries: [UUID: [String: [String]]] = [:]
    private var sourceFingerprints: [String: String] = [:]
    private var invalidationGeneration: UInt64 = 0
    private var saveWorkItem: DispatchWorkItem?
    private var storeSweepWorkItem: DispatchWorkItem?
    private var nextChunkWorkItem: DispatchWorkItem?
    private var storeSaveObserver: NSObjectProtocol?
    private var sweepRequested = false
    private var pendingChunkCount = 0
    private var activeChunkToken: UInt64 = 0
    private var activeChunkHasMore = false

    private(set) var isSweepActive = false
    private(set) var contentVersion: UInt64 = 0

    init(
        directory: URL,
        catalog: ExtensionCatalog,
        host: ExtensionHost,
        clipsProvider: @escaping () -> [ClipItem],
        notificationCenter: NotificationCenter = .default,
        saveDelay: TimeInterval = 0.5,
        storeSaveDebounce: TimeInterval = 0.5,
        chunkDelay: TimeInterval = 0.2
    ) {
        self.directory = directory
        self.storeURL = directory.appendingPathComponent("extension-keywords.json")
        self.catalog = catalog
        self.host = host
        self.clipsProvider = clipsProvider
        self.notificationCenter = notificationCenter
        self.saveDelay = saveDelay
        self.storeSaveDebounce = storeSaveDebounce
        self.chunkDelay = chunkDelay

        prepareDirectory()
        loadAndPrune()
        storeSaveObserver = notificationCenter.addObserver(
            forName: .pestyStoreDidSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleStoreSaveSweep()
            }
        }
        scheduleSweep()
    }

    deinit {
        saveWorkItem?.cancel()
        storeSweepWorkItem?.cancel()
        nextChunkWorkItem?.cancel()
        if let storeSaveObserver {
            notificationCenter.removeObserver(storeSaveObserver)
        }
    }

    func matches(_ clipID: UUID, query: TextSearch.Query) -> Bool {
        guard !query.text.isEmpty, let extensionEntries = entries[clipID] else {
            return false
        }
        for keywords in extensionEntries.values {
            for keyword in keywords where TextSearch.contains(keyword, query: query) {
                return true
            }
        }
        return false
    }

    func scheduleSweep() {
        if isSweepActive {
            sweepRequested = true
            return
        }
        guard !activeKeywordExtensions().isEmpty else {
            sweepRequested = false
            return
        }
        isSweepActive = true
        sweepRequested = false
        processNextChunk()
    }

    func forget(_ clipID: UUID) {
        invalidationGeneration &+= 1
        guard entries.removeValue(forKey: clipID) != nil else {
            if isSweepActive { sweepRequested = true }
            return
        }
        contentVersion &+= 1
        scheduleSave()
        if isSweepActive { sweepRequested = true }
    }

    func forgetAll() {
        invalidationGeneration &+= 1
        let hadEntries = !entries.isEmpty
        entries.removeAll(keepingCapacity: true)
        if hadEntries {
            contentVersion &+= 1
            scheduleSave()
        }
        if isSweepActive { sweepRequested = true }
    }

    func purge(extensionID: String) {
        invalidationGeneration &+= 1
        let removedEntries = removeEntries(forExtensionID: extensionID)
        let removedFingerprint = sourceFingerprints.removeValue(forKey: extensionID) != nil
        if removedEntries {
            contentVersion &+= 1
        }
        if removedEntries || removedFingerprint {
            scheduleSave()
        }
        scheduleSweep()
    }

    func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        guard let data = try? JSONEncoder().encode(persistedState) else { return }
        do {
            try data.write(to: storeURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storeURL.path
            )
        } catch {
            return
        }
    }

    func cachedKeywords(for clipID: UUID, extensionID: String) -> [String]? {
        entries[clipID]?[extensionID]
    }

    var cachedClipCount: Int { entries.count }

    var cachedPairCount: Int {
        entries.values.reduce(0) { $0 + $1.count }
    }

    static func sourceFingerprint(for source: String) -> String {
        SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private var persistedState: PersistedState {
        PersistedState(
            entries: Dictionary(
                uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value) }
            ),
            sourceFingerprints: sourceFingerprints
        )
    }

    private func prepareDirectory() {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func loadAndPrune() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return
        }

        let clipIDs = Set(clipsProvider().map(\.id))
        let activeExtensions = activeKeywordExtensions()
        let activeByID = Dictionary(
            uniqueKeysWithValues: activeExtensions.map {
                ($0.installedExtension.id, $0.fingerprint)
            }
        )
        var loadedEntries: [UUID: [String: [String]]] = [:]
        for (rawClipID, extensionEntries) in decoded.entries {
            guard let clipID = UUID(uuidString: rawClipID), clipIDs.contains(clipID) else {
                continue
            }
            var retained: [String: [String]] = [:]
            for (extensionID, keywords) in extensionEntries {
                guard let fingerprint = activeByID[extensionID],
                      decoded.sourceFingerprints[extensionID] == fingerprint else { continue }
                retained[extensionID] = keywords
            }
            if !retained.isEmpty {
                loadedEntries[clipID] = retained
            }
        }
        entries = loadedEntries
        sourceFingerprints = decoded.sourceFingerprints.filter { extensionID, fingerprint in
            activeByID[extensionID] == fingerprint
        }

        if persistedState != decoded {
            scheduleSave()
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    private func scheduleStoreSaveSweep() {
        storeSweepWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scheduleSweep() }
        storeSweepWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + storeSaveDebounce, execute: work)
    }

    private func activeKeywordExtensions() -> [ActiveKeywordExtension] {
        catalog.enabledExtensions.compactMap { installedExtension in
            guard installedExtension.manifest.effectiveHooks.contains("keywords") else {
                return nil
            }
            return ActiveKeywordExtension(
                installedExtension: installedExtension,
                fingerprint: Self.sourceFingerprint(for: installedExtension.source)
            )
        }
    }

    private func processNextChunk() {
        guard isSweepActive else { return }
        nextChunkWorkItem = nil

        let activeExtensions = activeKeywordExtensions()
        reconcileFingerprints(with: activeExtensions)
        guard !activeExtensions.isEmpty else {
            finishSweep()
            return
        }

        var pairs = missingPairs(
            from: clipsProvider(),
            extensions: activeExtensions,
            limit: Self.chunkSize + 1
        )
        guard !pairs.isEmpty else {
            finishSweep()
            return
        }

        activeChunkHasMore = pairs.count > Self.chunkSize
        if activeChunkHasMore {
            pairs.removeLast(pairs.count - Self.chunkSize)
        }
        activeChunkToken &+= 1
        let token = activeChunkToken
        pendingChunkCount = pairs.count

        for pair in pairs {
            host.keywords(
                clipType: pair.item.type.rawValue,
                text: pair.item.text ?? "",
                extension: pair.installedExtension,
                settings: pair.settings
            ) { [weak self] keywords in
                self?.finish(pair: pair, keywords: keywords, chunkToken: token)
            }
        }
    }

    private func missingPairs(
        from clips: [ClipItem],
        extensions: [ActiveKeywordExtension],
        limit: Int
    ) -> [SweepPair] {
        var pairs: [SweepPair] = []
        var seen: Set<PairKey> = []
        for item in clips {
            for activeExtension in extensions {
                let installedExtension = activeExtension.installedExtension
                guard installedExtension.manifest.supports(clipType: item.type.rawValue) else {
                    continue
                }
                let key = PairKey(clipID: item.id, extensionID: installedExtension.id)
                guard seen.insert(key).inserted,
                      entries[item.id]?[installedExtension.id] == nil else { continue }
                pairs.append(
                    SweepPair(
                        item: item,
                        installedExtension: installedExtension,
                        fingerprint: activeExtension.fingerprint,
                        settings: catalog.effectiveSettings(for: installedExtension.id),
                        invalidationGeneration: invalidationGeneration
                    )
                )
                if pairs.count >= limit { return pairs }
            }
        }
        return pairs
    }

    private func finish(pair: SweepPair, keywords: [String], chunkToken: UInt64) {
        guard isSweepActive, activeChunkToken == chunkToken else { return }

        if pairIsCurrent(pair) {
            var extensionEntries = entries[pair.item.id] ?? [:]
            if extensionEntries[pair.installedExtension.id] != keywords {
                extensionEntries[pair.installedExtension.id] = keywords
                entries[pair.item.id] = extensionEntries
                sourceFingerprints[pair.installedExtension.id] = pair.fingerprint
                contentVersion &+= 1
                scheduleSave()
            }
        } else {
            sweepRequested = true
        }

        pendingChunkCount -= 1
        guard pendingChunkCount == 0 else { return }
        if activeChunkHasMore {
            scheduleNextChunk()
        } else {
            finishSweep()
        }
    }

    private func pairIsCurrent(_ pair: SweepPair) -> Bool {
        guard invalidationGeneration == pair.invalidationGeneration,
              let current = catalog.extensions.first(where: {
                  $0.id == pair.installedExtension.id
              }),
              current.enabled,
              !catalog.isQuarantined(current.id),
              current.manifest.effectiveHooks.contains("keywords"),
              current.manifest.supports(clipType: pair.item.type.rawValue) else {
            return false
        }
        return Self.sourceFingerprint(for: current.source) == pair.fingerprint
    }

    private func scheduleNextChunk() {
        nextChunkWorkItem?.cancel()
        let work = DispatchWorkItem(qos: .utility) { [weak self] in
            self?.processNextChunk()
        }
        nextChunkWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + chunkDelay, execute: work)
    }

    private func finishSweep() {
        nextChunkWorkItem?.cancel()
        nextChunkWorkItem = nil
        pendingChunkCount = 0
        isSweepActive = false
        let shouldSweepAgain = sweepRequested
        sweepRequested = false
        if shouldSweepAgain {
            scheduleSweep()
        }
    }

    private func reconcileFingerprints(with activeExtensions: [ActiveKeywordExtension]) {
        let activeByID = Dictionary(
            uniqueKeysWithValues: activeExtensions.map {
                ($0.installedExtension.id, $0.fingerprint)
            }
        )
        var knownExtensionIDs = Set(sourceFingerprints.keys)
        for extensionEntries in entries.values {
            knownExtensionIDs.formUnion(extensionEntries.keys)
        }

        var persistentStateChanged = false
        var searchStateChanged = false
        for extensionID in knownExtensionIDs {
            guard let currentFingerprint = activeByID[extensionID] else {
                searchStateChanged = removeEntries(forExtensionID: extensionID)
                    || searchStateChanged
                persistentStateChanged = sourceFingerprints.removeValue(
                    forKey: extensionID
                ) != nil || persistentStateChanged
                continue
            }
            if sourceFingerprints[extensionID] != currentFingerprint {
                searchStateChanged = removeEntries(forExtensionID: extensionID)
                    || searchStateChanged
                sourceFingerprints[extensionID] = currentFingerprint
                persistentStateChanged = true
            }
        }
        for activeExtension in activeExtensions
        where sourceFingerprints[activeExtension.installedExtension.id] == nil {
            sourceFingerprints[activeExtension.installedExtension.id] = activeExtension.fingerprint
            persistentStateChanged = true
        }

        if searchStateChanged {
            contentVersion &+= 1
        }
        if searchStateChanged || persistentStateChanged {
            scheduleSave()
        }
    }

    @discardableResult
    private func removeEntries(forExtensionID extensionID: String) -> Bool {
        var removed = false
        for clipID in Array(entries.keys) {
            guard var extensionEntries = entries[clipID],
                  extensionEntries.removeValue(forKey: extensionID) != nil else { continue }
            removed = true
            if extensionEntries.isEmpty {
                entries.removeValue(forKey: clipID)
            } else {
                entries[clipID] = extensionEntries
            }
        }
        return removed
    }
}

@MainActor
enum ExtensionSearchPredicate {
    static func matches(
        _ item: ClipItem,
        query: TextSearch.Query,
        keywordIndex: ExtensionKeywordIndex
    ) -> Bool {
        item.matches(query: query) || keywordIndex.matches(item.id, query: query)
    }
}
