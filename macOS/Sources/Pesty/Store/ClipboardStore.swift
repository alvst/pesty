import AppKit
import Observation

extension Notification.Name {
    static let pestyStoreDidSave = Notification.Name("PestyStoreDidSave")
}

enum BarSource: Equatable {
    case history
    case pasteStack
    case pinboard(UUID)
}

enum BarInputMode: Equatable {
    case cards
    case search
}

struct LegacyLibraryImportSummary: Equatable {
    var historyClipCount: Int
    var pinboardCount: Int
    var pasteStackCount: Int
    var imageCount: Int
}

enum LegacyLibraryImportError: LocalizedError {
    case missingStore
    case unreadableStore
    case stackMigrationFailed

    var errorDescription: String? {
        switch self {
        case .missingStore:
            return "The selected folder does not contain a Pesty store.json file."
        case .unreadableStore:
            return "The selected Pesty library could not be read."
        case .stackMigrationFailed:
            return "The saved Paste Stacks could not be copied into local storage. No library data was imported."
        }
    }
}

@Observable
@MainActor
final class ClipboardStore {
    static let shared = ClipboardStore()

    private(set) var history: [ClipItem] = [] { didSet { contentVersion &+= 1 } }
    private(set) var pinboards: [Pinboard] = [] { didSet { contentVersion &+= 1 } }
    /// Deleted pinboards still inside their five-minute Undo window.
    private(set) var pendingPinboardDeletions: [PendingPinboardDeletion] = []

    /// Bumped by any change to the clips themselves, so the search cache below
    /// can tell "same query, same clips" from "same query, new clips" without
    /// comparing arrays.
    // Keep this observable: an exact search-cache hit intentionally avoids
    // materializing its source array, so this lightweight generation is what
    // invalidates the rendered results after a capture, edit, or deletion.
    private var contentVersion = 0
    private(set) var hasUndoableDeletion = false

    var source: BarSource = .history
    var searchText: String = ""
    /// Search owns native text editing until the user submits it or chooses a
    /// result. Card shortcuts only run while this is `.cards`.
    var barInputMode: BarInputMode = .cards
    /// The bar's card selection. `ClipSelection` owns the ordering rules; the
    /// store only supplies what is currently on screen.
    private(set) var selection = ClipSelection()

    /// The lead of the selection: the card arrow keys move from and the one
    /// every single-item action uses. Assigning it means "just this one",
    /// which is what the many existing callers (arrow keys, capture, tab
    /// switch, delete fallback) already intend — so it collapses any
    /// multi-selection.
    var selectedID: UUID? {
        get { selection.lead }
        set { selection.select(newValue) }
    }

    /// Every selected card.
    var selectedIDs: Set<UUID> { selection.ids }
    var inlinePreviewVisible = false
    /// Used by the strip to restore its opening position without animating from
    /// whichever card was selected the last time the bar was visible.
    var initialScrollTargetID: UUID?

    private var storeURL: URL
    private var imagesDir: URL
    private var baseDir: URL
    /// iCloud Drive keeps the legacy inline JSON contract for older Macs.
    private var compactLocalStore: Bool
    private var stackStoreURL: URL
    private var stackImagesDir: URL
    private var legacyStacksNeedMigration = false
    private var stackStoreLoadFailed = false
    private(set) var storeLoadFailed = false
    private var lastPersistedStacks: [SavedPasteStack] = []
    private var pendingStackRestorations: [UUID: [PasteStackEntryPlacement]] = [:]
    private var saveWorkItem: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "com.alvst.pesty.store-save", qos: .utility)
    private let externalDecodeQueue = DispatchQueue(label: "com.alvst.pesty.drive-decode", qos: .utility)
    private var externalDecodeGeneration: UInt64 = 0
    private var saveSequence: UInt64 = 0
    private var lastCompletedSaveSequence: UInt64 = 0
    private var undoExpirationWorkItem: DispatchWorkItem?
    private var deletionLedger = ClipDeletionLedger()
    private var currentDeletionOperationID: UUID?
    private var isDeletingBatch = false
    private var batchAssetsToDelete: [ClipItem] = []
    private(set) var cloudRetentionExcludedIDs: Set<UUID> = []

    private var fileWatch: DispatchSourceFileSystemObject?
    private var lastSavedData: Data?
    private(set) var legacyLibraryMigrationResolved = false

    /// Demo mode gets its own store. Seeding demo content into the real one
    /// would both bury the user's clipboard history and leave whatever
    /// Pinboards they happen to have sitting in the middle of a screenshot.
    static var isDemo: Bool { CommandLine.arguments.contains("--demo") }

    static var localBase: URL {
        let directory = isDemo
            ? "\(AppIdentity.storageDirectoryName)-Demo"
            : AppIdentity.storageDirectoryName
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directory, isDirectory: true)
    }

    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    static var iCloudBase: URL? {
        guard !isSandboxed, !isDemo else { return nil }
        let p = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: p.path) else { return nil }
        return p.appendingPathComponent(AppIdentity.storageDirectoryName, isDirectory: true)
    }

    var iCloudAvailable: Bool { ClipboardStore.iCloudBase != nil }

    private init() {
        let base = (!ClipboardStore.isDemo && Settings.shared.iCloudSync
                    ? ClipboardStore.iCloudBase : nil) ?? ClipboardStore.localBase
        baseDir = base
        compactLocalStore = base.standardizedFileURL == ClipboardStore.localBase.standardizedFileURL
        imagesDir = base.appendingPathComponent("images", isDirectory: true)
        storeURL = base.appendingPathComponent("store.json")
        let stackBase = ClipboardStore.localBase.appendingPathComponent("Paste Stacks", isDirectory: true)
        stackStoreURL = stackBase.appendingPathComponent("stacks.json")
        stackImagesDir = stackBase.appendingPathComponent("images", isDirectory: true)
        let hadStoreAtLaunch = FileManager.default.fileExists(atPath: storeURL.path)
        prepareDirectories()
        legacyLibraryMigrationResolved = FileManager.default.fileExists(
            atPath: legacyLibraryMigrationMarkerURL.path
        )
        cloudRetentionExcludedIDs = loadCloudRetentionExclusions()
        let tombstonesApplied = load()
        if !storeLoadFailed {
            let historyChanged = applyHistoryPolicyNow()
            let deletionsChanged = refreshDeletionState(at: .now)
            let pixelsBackfilled = backfillImageFilePixels(at: .now)
            if tombstonesApplied || historyChanged || deletionsChanged || pixelsBackfilled { saveNow() }
            resolveBundledLegacyLibraryMigration(hadStoreAtLaunch: hadStoreAtLaunch)
        }
        if !storeLoadFailed && Settings.shared.iCloudSync && !ClipboardStore.isDemo {
            startWatching()
        }
    }

#if DEBUG
    /// Isolated on-disk store used by store-level tests. Production always
    /// enters through `shared` and performs the full load/migration sequence.
    init(
        testingBaseDirectory base: URL,
        history: [ClipItem] = [],
        pinboards: [Pinboard] = [],
        loadExisting: Bool = false,
        compactLocalStore: Bool = true
    ) {
        self.history = history
        self.pinboards = pinboards
        baseDir = base
        self.compactLocalStore = compactLocalStore
        imagesDir = base.appendingPathComponent("images", isDirectory: true)
        storeURL = base.appendingPathComponent("store.json")
        let stackBase = base.appendingPathComponent("Paste Stacks", isDirectory: true)
        stackStoreURL = stackBase.appendingPathComponent("stacks.json")
        stackImagesDir = stackBase.appendingPathComponent("images", isDirectory: true)
        legacyLibraryMigrationResolved = true
        prepareDirectories()
        if loadExisting { _ = load() }
    }
#endif

    /// The on-disk store root (history JSON plus saved images), exposed so
    /// Settings can report how much space history actually uses.
    var dataDirectory: URL { baseDir }

    private func prepareDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseDir.path)
        try? fm.createDirectory(at: stackImagesDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    }

    /// Search is memoized because `visibleItems` is a computed property that
    /// the bar evaluates several times per frame — the card strip, the empty
    /// state, the scroll targets, and the selection all ask for it — while
    /// matching a query against a multi-megabyte clip costs a full scan of it.
    /// Recomputing that per access is what made typing in the search field
    /// lock the bar up.
    @ObservationIgnored private var searchCache: (
        source: BarSource,
        query: String,
        version: Int,
        keywordVersion: UInt64,
        items: [ClipItem]
    )?

    private func cachedSearchResults(for query: String, keywordVersion: UInt64) -> [ClipItem]? {
        guard let cache = searchCache,
              cache.version == contentVersion,
              cache.keywordVersion == keywordVersion,
              cache.source == source,
              cache.query == query else { return nil }
        return cache.items
    }

    private func searchResults(
        in base: [ClipItem],
        query: String,
        keywordIndex: ExtensionKeywordIndex
    ) -> [ClipItem] {
        let keywordVersion = keywordIndex.contentVersion
        if let cached = cachedSearchResults(
            for: query,
            keywordVersion: keywordVersion
        ) { return cached }

        // Appending characters can only narrow substring-search results. Use
        // the previous matches as candidates while typing forward; deletion,
        // replacement, source changes, and content changes correctly restart
        // from the complete source list.
        let preparedQuery = TextSearch.Query(query)
        let candidates: [ClipItem]
        if let cache = searchCache,
           cache.version == contentVersion,
           cache.keywordVersion == keywordVersion,
           cache.source == source,
           preparedQuery.canNarrowResults(from: TextSearch.Query(cache.query)) {
            candidates = cache.items
        } else {
            candidates = base
        }
        let items = candidates.filter {
            ExtensionSearchPredicate.matches(
                $0,
                query: preparedQuery,
                keywordIndex: keywordIndex
            )
        }
        searchCache = (source, query, contentVersion, keywordVersion, items)
        return items
    }

    var visibleItems: [ClipItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // ClipboardStore computes visibleItems while its singleton is loading.
        // Defer the keyword singleton until a real query exists so index startup
        // cannot recursively ask for ClipboardStore.shared during that load.
        let keywordIndex: ExtensionKeywordIndex? = q.isEmpty ? nil : .shared
        // A cached query can return before a Pinboard rebuilds its promoted
        // ordering dictionaries and arrays for every SwiftUI consumer.
        if let keywordIndex,
           let cached = cachedSearchResults(
               for: q,
               keywordVersion: keywordIndex.contentVersion
           ) {
            return cached
        }

        let base: [ClipItem]
        switch source {
        case .history:
            base = history
        case .pasteStack:
            // Paste Stack has its own entry IDs and selection state. Its full
            // view is rendered separately by BarView rather than being folded
            // into clipboard history items.
            base = []
        case .pinboard(let id):
            base = pinboards.first(where: { $0.id == id })?.orderedItems ?? []
        }
        guard let keywordIndex else {
            // Each saved Paste Stack is represented by one deck card on
            // Clipboard. Its member clips remain in history for persistence,
            // but should not also appear as individual Clipboard cards.
            guard case .history = source,
                  Settings.shared.pasteStacksEnabled,
                  PasteSequence.shared.hasSavedStacks else { return base }
            let stackedIDs = PasteSequence.shared.savedHistoryItemIDs
            return base.filter { !stackedIDs.contains($0.id) }
        }
        return searchResults(in: base, query: q, keywordIndex: keywordIndex)
    }

    var selectedItem: ClipItem? {
        guard let id = selectedID else { return nil }
        return visibleItems.first(where: { $0.id == id })
    }

    /// The selection in visible (left-to-right) order — a `Set` has none, and
    /// an action over several clips has to be reproducible. Falls back to the
    /// lead alone so callers can treat this as "what the user means right now"
    /// without special-casing an empty multi-selection.
    var selectedItems: [ClipItem] {
        let items = visibleItems.filter { selectedIDs.contains($0.id) }
        if items.isEmpty, let selectedItem { return [selectedItem] }
        return items
    }

    var hasMultipleSelection: Bool { selection.isMultiple }

    /// ⌘-click.
    func toggleSelection(of id: UUID) { selection.toggle(id, in: visibleOrder) }

    /// ⇧-click and ⇧-arrow.
    func extendSelection(to id: UUID) { selection.extend(to: id, in: visibleOrder) }

    func selectAllVisible() { selection.selectAll(in: visibleOrder) }

    /// Drops anything no longer on screen out of the selection — after a
    /// delete, a search, or a switch to another Pinboard.
    func pruneSelection() { selection.prune(to: visibleOrder) }

    private var visibleOrder: [UUID] { visibleItems.map(\.id) }

    @discardableResult
    func addCaptured(_ item: ClipItem) -> ClipItem {
        guard !storeLoadFailed else { return item }
        if cloudRetentionExcludedIDs.remove(item.id) != nil {
            saveCloudRetentionExclusions()
        }
        let itemRestoration = deletionLedger.restoreItemIfNeeded(item.id, at: item.createdAt)
        if itemRestoration != nil { _ = refreshDeletionState(at: item.createdAt) }
        defer {
            for deletedItem in itemRestoration?.deletionPayload?.allItems ?? [] {
                deleteImageFile(deletedItem)
            }
        }
        if let idx = history.firstIndex(where: { $0.sameContent(as: item) }) {
            if item.imageFileName != history[idx].imageFileName { deleteImageFile(item) }
            var existing = history.remove(at: idx)
            existing.createdAt = item.createdAt
            existing.lastUsedAt = item.createdAt
            existing.updatedAt = max(item.updatedAt, item.createdAt)
            history.insert(existing, at: 0)
            applyHistoryPolicyNow()
            if source == .history && searchText.isEmpty { selectedID = existing.id }
            scheduleSave()
            return existing
        }
        history.insert(item, at: 0)
        applyHistoryPolicyNow()
        if source == .history && searchText.isEmpty {
            selectedID = item.id
        }
        scheduleSave()

        return item
    }

    /// Inserts a text item the user deliberately authored. Unlike clipboard
    /// capture, creating the same text twice should create two editable cards.
    @discardableResult
    func addCreatedTextItem(
        _ text: String,
        richTextData: Data?,
        title: String?
    ) -> ClipItem? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let type: ClipType = richTextData != nil ? .richText : (isWebLink(text) ? .link : .text)
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = ClipItem(
            type: type,
            text: text,
            rtfData: richTextData,
            customTitle: trimmedTitle?.isEmpty == false ? trimmedTitle : nil
        )
        searchText = ""
        barInputMode = .cards
        if case .pinboard(let boardID) = source,
           let boardIndex = pinboards.firstIndex(where: { $0.id == boardID }) {
            pinboards[boardIndex].items.insert(item, at: 0)
            pinboards[boardIndex].touch()
        } else {
            history.insert(item, at: 0)
            _ = applyHistoryPolicyNow()
            source = .history
        }
        selectedID = item.id
        scheduleSave()
        return item
    }

    func applyHistoryPolicy() {
        if applyHistoryPolicyNow() { scheduleSave() }
    }

    /// A Copy from the Paste Bar is an intentional use of an existing clip.
    /// Promote it explicitly because the clipboard monitor correctly ignores
    /// Pesty's own pasteboard writes.
    @discardableResult
    func promoteCopiedItem(_ item: ClipItem, at date: Date = .now) -> ClipItem {
        var copied = item
        if PasteSequence.shared.item(withID: item.id) != nil
            || pinboards.contains(where: { $0.items.contains(where: { $0.id == item.id }) }) {
            copied = copyWithFreshIdentityAndOwnedImage(item, at: date)
            // A Stack or Pinboard image must not become a History reference
            // if its independent copy could not be written.
            if item.imageFileName != nil,
               copied.imageFileName == item.imageFileName {
                copied.imageFileName = nil
                copied.imageHash = nil
            }
        }
        copied.createdAt = date
        copied.lastUsedAt = date
        copied.updatedAt = max(date, copied.updatedAt.addingTimeInterval(0.000_001))
        return addCaptured(copied)
    }

    func pasteStacksDidChange() {
        if isDeletingBatch { return }
        if legacyStacksNeedMigration || stackStoreLoadFailed {
            PasteSequence.shared.restoreSavedStacks(lastPersistedStacks)
            pruneUnreferencedStackImages()
            return
        }
        if savePasteStacks(PasteSequence.shared.savedStacks) {
            pruneUnreferencedStackImages()
        } else {
            PasteSequence.shared.restoreSavedStacks(lastPersistedStacks)
            pruneUnreferencedStackImages()
        }
    }

    var hasStoredPasteStacks: Bool {
        !PasteSequence.shared.savedStacks.isEmpty || !pendingStackRestorations.isEmpty
    }

    var canModifyPasteStacks: Bool {
        !stackStoreLoadFailed && !legacyStacksNeedMigration
    }

    /// Erases every local Stack, including entries still held for History Undo.
    /// History Undo remains available, but cannot recreate an erased Stack.
    @discardableResult
    func deleteAllPasteStacks() -> Bool {
        let oldStacks = PasteSequence.shared.savedStacks
        let oldRestorations = pendingStackRestorations
        let oldLegacyMigration = legacyStacksNeedMigration
        let oldLoadFailure = stackStoreLoadFailed
        let oldStackData = try? Data(contentsOf: stackStoreURL)
        let oldLedger = deletionLedger
        let legacyUndoPlacements = deletionLedger.extractStackPlacements()
        PasteSequence.shared.restoreSavedStacks([])
        pendingStackRestorations.removeAll()
        // Deleting every Stack is an explicit reset of an unreadable local
        // Stack file. Ordinary History actions must leave that file intact.
        stackStoreLoadFailed = false
        legacyStacksNeedMigration = false
        guard savePasteStacks([]) else {
            stackStoreLoadFailed = oldLoadFailure
            legacyStacksNeedMigration = oldLegacyMigration
            deletionLedger = oldLedger
            pendingStackRestorations = oldRestorations
            PasteSequence.shared.restoreSavedStacks(oldStacks)
            return false
        }
        if (oldLegacyMigration || !legacyUndoPlacements.isEmpty) && !saveNow() {
            legacyStacksNeedMigration = oldLegacyMigration
            stackStoreLoadFailed = oldLoadFailure
            deletionLedger = oldLedger
            pendingStackRestorations = oldRestorations
            PasteSequence.shared.restoreSavedStacks(oldStacks)
            if let oldStackData {
                try? oldStackData.write(to: stackStoreURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: stackStoreURL)
            }
            lastPersistedStacks = oldStacks
            return false
        }
        pruneUnreferencedStackImages()
        return true
    }

    @discardableResult
    private func applyHistoryPolicyNow() -> Bool {
        let removed: [ClipItem]
        switch Settings.shared.historyRetentionMode {
        case .itemCount:
            guard history.count > Settings.shared.historyLimit else { return false }
            removed = Array(history[Settings.shared.historyLimit...])
            history.removeLast(history.count - Settings.shared.historyLimit)
        case .timePeriod:
            guard let cutoff = Settings.shared.historyRetention.cutoffDate else { return false }
            removed = history.filter { $0.createdAt < cutoff }
            guard !removed.isEmpty else { return false }
            history.removeAll { $0.createdAt < cutoff }
        }
        if Settings.shared.pasteStacksFollowHistory {
            PasteSequence.shared.removeHistoryItems(Set(removed.map(\.id)))
        }
        recordCloudRetentionExclusions(removed.map(\.id))
        for item in removed {
            ExtensionResultStore.shared.forget(item.id)
            deleteImageFile(item)
        }
        return true
    }

    /// `permanently` skips the Undo ledger entirely, so the deleted content
    /// never sits recoverable in store.json even for the five-minute window —
    /// either because the user turned that off globally in Settings, or held
    /// Option for this one deletion.
    func delete(_ item: ClipItem, at date: Date = .now, permanently: Bool = false) {
        _ = delete([item], at: date, permanently: permanently)
    }

    private func deleteOne(_ item: ClipItem, at date: Date, permanently: Bool) {
        let permanently = permanently || Settings.shared.deletePermanently
        let historyPlacements: [HistoryClipPlacement] = (source == .history ? history : []).enumerated().compactMap { index, existing in
            guard existing.id == item.id else { return nil }
            return HistoryClipPlacement(
                index: index,
                item: existing,
                predecessorID: index > 0 ? history[index - 1].id : nil,
                successorID: index + 1 < history.count ? history[index + 1].id : nil
            )
        }
        let pinboardPlacements: [PinboardClipPlacement] = pinboards.filter { board in
            if case .pinboard(let id) = source { return board.id == id }
            return false
        }.flatMap { pinboard in
            pinboard.items.enumerated().compactMap { index, existing in
                guard existing.id == item.id else { return nil }
                return PinboardClipPlacement(
                    pinboardID: pinboard.id,
                    index: index,
                    item: existing,
                    predecessorID: index > 0 ? pinboard.items[index - 1].id : nil,
                    successorID: index + 1 < pinboard.items.count ? pinboard.items[index + 1].id : nil
                )
            }
        }
        guard !historyPlacements.isEmpty || !pinboardPlacements.isEmpty else { return }
        let stackPlacements = source == .history && Settings.shared.pasteStacksFollowHistory
            && !legacyStacksNeedMigration && !stackStoreLoadFailed
            ? PasteSequence.shared.removeHistoryItems([item.id])
            : []
        let payload = ClipDeletionPayload(
            history: historyPlacements,
            pinboards: pinboardPlacements,
            pasteStackEntries: []
        )
        guard !payload.allItems.isEmpty else { return }

        if source == .history { history.removeAll { $0.id == item.id } }
        for i in pinboards.indices where pinboardPlacements.contains(where: { $0.pinboardID == pinboards[i].id }) {
            pinboards[i].items.removeAll { $0.id == item.id }
            pinboards[i].prunePins()
        }
        if permanently {
            pendingStackRestorations.removeValue(forKey: item.id)
            ExtensionResultStore.shared.forget(item.id)
            deletionLedger.recordRemoteDeletion(
                id: item.id,
                removesFromPasteStacks: source == .history && Settings.shared.pasteStacksFollowHistory,
                at: date
            )
            if isDeletingBatch {
                batchAssetsToDelete += payload.allItems + stackPlacements.map { $0.entry.item }
            } else {
                for deletedItem in payload.allItems + stackPlacements.map({ $0.entry.item }) {
                    deleteImageFile(deletedItem)
                }
            }
        } else {
            if !stackPlacements.isEmpty { pendingStackRestorations[item.id] = stackPlacements }
            deletionLedger.recordDeletion(
                id: item.id,
                payload: payload,
                removesFromPasteStacks: source == .history && Settings.shared.pasteStacksFollowHistory,
                operationID: currentDeletionOperationID ?? UUID(),
                at: date
            )
        }
        if selectedID == item.id {
            // The lead is gone; the rest of a multi-selection is not, so keep
            // it and just promote a survivor rather than collapsing to first.
            let survivors = selectedIDs.subtracting([item.id])
            if survivors.isEmpty { selectFirst() } else { pruneSelection() }
        } else {
            pruneSelection()
        }
        _ = refreshDeletionState(at: date)
    }

    /// One selection is one durable user action and one Undo operation. A
    /// failed write restores the complete in-memory state before any image is
    /// unlinked or sync change notification is sent.
    @discardableResult
    func delete(_ items: [ClipItem], at date: Date = .now, permanently: Bool = false) -> Bool {
        guard !items.isEmpty else { return false }
        let before = Snapshot(
            history: history, pinboards: pinboards,
            pasteStacks: PasteSequence.shared.savedStacks,
            deletionLedger: deletionLedger,
            pendingPinboardDeletions: pendingPinboardDeletions
        )
        let previousSelection = selection
        let previousStackRestorations = pendingStackRestorations
        currentDeletionOperationID = UUID()
        isDeletingBatch = true
        batchAssetsToDelete = []
        for item in items {
            deleteOne(item, at: date, permanently: permanently)
        }
        isDeletingBatch = false
        currentDeletionOperationID = nil
        saveWorkItem?.cancel()
        saveWorkItem = nil
        guard saveStacksForDeletionTransaction(
            before: before.pasteStacks ?? [],
            restorations: previousStackRestorations
        ) else {
            restoreDeletionTransaction(before, selection: previousSelection,
                                       stackRestorations: previousStackRestorations, at: date)
            return false
        }
        guard saveNow() else {
            pendingStackRestorations = previousStackRestorations
            _ = savePasteStacks(before.pasteStacks ?? [])
            restoreDeletionTransaction(before, selection: previousSelection,
                                       stackRestorations: previousStackRestorations, at: date)
            return false
        }
        for item in batchAssetsToDelete { deleteImageFile(item) }
        batchAssetsToDelete = []
        pruneUnreferencedStackImages()
        return true
    }

    private func restoreDeletionTransaction(
        _ before: Snapshot, selection previousSelection: ClipSelection,
        stackRestorations: [UUID: [PasteStackEntryPlacement]], at date: Date
    ) {
        history = before.history
        pinboards = before.pinboards
        deletionLedger = before.deletionLedger ?? ClipDeletionLedger()
        pendingPinboardDeletions = before.pendingPinboardDeletions ?? []
        PasteSequence.shared.restoreSavedStacks(before.pasteStacks ?? [])
        pendingStackRestorations = stackRestorations
        selection = previousSelection
        batchAssetsToDelete = []
        _ = refreshDeletionState(at: date)
    }

    /// Restores the newest deletion whose five-minute window is still open.
    /// A newer active marker remains in the ledger so an older synced tombstone
    /// cannot immediately remove the clip again.
    @discardableResult
    func undoLastDelete(at date: Date = .now) -> Bool {
        let finalizedExpiredDeletion = refreshDeletionState(at: date)
        // Clip and pinboard deletions share one Undo: whichever happened
        // last comes back first.
        if let pending = newestUndoablePinboardDeletion(at: date),
           pending.deletedAt >= (deletionLedger.latestUndoableDeletionDate(at: date) ?? .distantPast) {
            restorePinboard(pending, at: date)
            _ = refreshDeletionState(at: date)
            scheduleSave()
            return true
        }
        let before = Snapshot(
            history: history, pinboards: pinboards,
            pasteStacks: PasteSequence.shared.savedStacks,
            deletionLedger: deletionLedger,
            pendingPinboardDeletions: pendingPinboardDeletions
        )
        let previousSelection = selection
        let previousStackRestorations = pendingStackRestorations
        guard let deletions = deletionLedger.undoMostRecent(at: date) else {
            if finalizedExpiredDeletion { saveNow() }
            return false
        }
        isDeletingBatch = true
        for deletion in deletions {
            var restoredSomewhere = history.contains(where: { $0.id == deletion.id })
                || pinboards.contains { $0.items.contains(where: { $0.id == deletion.id }) }
            for placement in deletion.payload.history.sorted(by: { $0.index < $1.index }) {
                guard !history.contains(where: { $0.id == placement.item.id }) else { continue }
                var restoredItem = placement.item
                restoredItem.updatedAt = max(date, restoredItem.updatedAt.addingTimeInterval(0.000_001))
                let index = restorationIndex(
                    originalIndex: placement.index,
                    predecessorID: placement.predecessorID,
                    successorID: placement.successorID,
                    in: history
                )
                history.insert(restoredItem, at: index)
                restoredSomewhere = true
            }
            for placement in deletion.payload.pinboards {
                guard let boardIndex = pinboards.firstIndex(where: { $0.id == placement.pinboardID }),
                      !pinboards[boardIndex].items.contains(where: { $0.id == placement.item.id }) else {
                    continue
                }
                var restoredItem = placement.item
                restoredItem.updatedAt = max(date, restoredItem.updatedAt.addingTimeInterval(0.000_001))
                let index = restorationIndex(
                    originalIndex: placement.index,
                    predecessorID: placement.predecessorID,
                    successorID: placement.successorID,
                    in: pinboards[boardIndex].items
                )
                pinboards[boardIndex].items.insert(restoredItem, at: index)
                pinboards[boardIndex].touch(at: date)
                restoredSomewhere = true
            }
            let stackPlacements = pendingStackRestorations.removeValue(forKey: deletion.id)
                ?? deletion.payload.pasteStackEntries
            PasteSequence.shared.restoreHistoryItems(stackPlacements)
            if !stackPlacements.isEmpty { restoredSomewhere = true }

            // A deleted Pinboard can disappear during the grace period. Keep
            // its clip recoverable in History rather than dropping the payload.
            if !restoredSomewhere, var fallback = deletion.payload.allItems.first {
                fallback.updatedAt = max(date, fallback.updatedAt.addingTimeInterval(0.000_001))
                history.insert(fallback, at: 0)
            }
        }
        isDeletingBatch = false

        _ = refreshDeletionState(at: date)
        let restoredIDs = Set(deletions.map { $0.id })
        selection.restore(restoredIDs, in: visibleOrder)
        saveWorkItem?.cancel()
        saveWorkItem = nil
        guard saveStacksForDeletionTransaction(
            before: before.pasteStacks ?? [],
            restorations: previousStackRestorations
        ) else {
            restoreDeletionTransaction(before, selection: previousSelection,
                                       stackRestorations: previousStackRestorations, at: date)
            return false
        }
        guard saveNow() else {
            pendingStackRestorations = previousStackRestorations
            _ = savePasteStacks(before.pasteStacks ?? [])
            restoreDeletionTransaction(before, selection: previousSelection,
                                       stackRestorations: previousStackRestorations, at: date)
            return false
        }
        for deletion in deletions {
            for item in deletion.payload.allItems { deleteImageFile(item) }
        }
        pruneUnreferencedStackImages()
        return true
    }

    private func restorationIndex(originalIndex: Int,
                                  predecessorID: UUID?,
                                  successorID: UUID?,
                                  in items: [ClipItem]) -> Int {
        if let predecessorID,
           let index = items.firstIndex(where: { $0.id == predecessorID }) {
            return index + 1
        }
        if let successorID,
           let index = items.firstIndex(where: { $0.id == successorID }) {
            return index
        }
        return min(max(0, originalIndex), items.count)
    }

    func clearHistory() {
        let old = history
        let finalizedPayloads = deletionLedger.finalizePendingHistoryDeletions(at: .now)
        let pendingStackItems = pendingStackRestorations.values.flatMap { $0.map { $0.entry.item } }
        pendingStackRestorations.removeAll()
        history.removeAll()
        selectedID = nil
        if Settings.shared.pasteStacksFollowHistory {
            PasteSequence.shared.removeHistoryItems(Set(old.map(\.id)))
        }
        _ = savePasteStacks(PasteSequence.shared.savedStacks)
        for item in old { ExtensionResultStore.shared.forget(item.id) }
        deletionLedger.recordRemoteDeletions(
            ids: old.map(\.id),
            removesFromPasteStacks: Settings.shared.pasteStacksFollowHistory,
            at: .now
        )
        for payload in finalizedPayloads {
            for item in payload.allItems {
                ExtensionResultStore.shared.forget(item.id)
                deleteImageFile(item)
            }
        }
        for item in pendingStackItems { deleteImageFile(item) }
        for item in old { deleteImageFile(item) }
        scheduleSave()
    }

    /// Used only to build the demo store's fixed contents.
    func replaceAllForDemo(history newHistory: [ClipItem], pinboards newPinboards: [Pinboard]) {
        guard ClipboardStore.isDemo else { return }
        history = newHistory
        pinboards = newPinboards
        selectFirst()
        saveNow()
    }

    /// Merges clips from a foreign clipboard manager without touching its files.
    func mergeImportedLibrary(history importedHistory: [ClipItem], pinboards importedPinboards: [Pinboard]) {
        for item in importedHistory where !history.contains(where: { $0.sameContent(as: item) }) {
            history.append(item)
        }
        for imported in importedPinboards {
            var board = imported
            if let existing = pinboards.firstIndex(where: { $0.name == board.name }) {
                for item in board.items where !pinboards[existing].items.contains(where: { $0.sameContent(as: item) }) {
                    pinboards[existing].items.append(item)
                }
                pinboards[existing].touch()
            } else {
                board.sortIndex = pinboards.count
                pinboards.append(board)
            }
        }
        history.sort { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }
        normalizePinboardOrder(touchChanges: false)
        applyHistoryPolicyNow()
        selectFirst()
        saveNow()
    }

    @discardableResult
    func addPinboard(name: String, colorHex: String = "#5B8DEF") -> Pinboard {
        let b = Pinboard(name: name, colorHex: colorHex, sortIndex: pinboards.count)
        pinboards.append(b)
        scheduleSave()
        return b
    }

    /// Shared by Pinboard tab clicks and keyboard jumps so both preserve the
    /// current search and select its first visible result in exactly the same way.
    func selectPinboard(_ id: UUID) {
        guard pinboards.contains(where: { $0.id == id }) else { return }
        source = .pinboard(id)
        selectFirst()
    }

    func renamePinboard(_ id: UUID, to name: String) {
        guard let i = pinboards.firstIndex(where: { $0.id == id }) else { return }
        pinboards[i].name = name
        pinboards[i].touch()
        scheduleSave()
    }

    func setPinboardColor(_ id: UUID, to colorHex: String) {
        guard let i = pinboards.firstIndex(where: { $0.id == id }) else { return }
        pinboards[i].colorHex = colorHex
        pinboards[i].touch()
        scheduleSave()
    }

    /// Deleting a pinboard is undoable for the same five minutes as deleting
    /// a clip: the board leaves the tabs immediately but is kept whole in
    /// `pendingPinboardDeletions` until the window closes. `permanently` (or
    /// the global setting) skips the window, as it does for clips.
    func deletePinboard(_ id: UUID, at date: Date = .now, permanently: Bool = false) {
        let permanently = permanently || Settings.shared.deletePermanently
        guard let i = pinboards.firstIndex(where: { $0.id == id }) else { return }
        if case .pinboard(let cur) = source, cur == id { source = .history }
        let board = pinboards.remove(at: i)
        _ = normalizePinboardOrder(touchChanges: true)
        if permanently {
            finalizeRemovedPinboard(board, at: date)
        } else {
            pendingPinboardDeletions.removeAll { $0.board.id == id }
            pendingPinboardDeletions.append(PendingPinboardDeletion(board: board, deletedAt: date))
        }
        _ = refreshDeletionState(at: date)
        scheduleSave()
    }

    /// The irreversible half of a pinboard deletion: sync tombstones for its
    /// clips and image cleanup. Runs at once for a permanent delete, and when
    /// a pending deletion's Undo window closes. The board must already be out
    /// of both `pinboards` and `pendingPinboardDeletions`, or its images
    /// still count as referenced.
    private func finalizeRemovedPinboard(_ board: Pinboard, at date: Date) {
        let finalizedPayloads = deletionLedger.finalizePendingDeletions(inPinboard: board.id, at: date)
        for item in board.items {
            ExtensionResultStore.shared.forget(item.id)
            deletionLedger.recordRemoteDeletion(
                id: item.id,
                removesFromPasteStacks: false,
                at: date
            )
        }
        for item in board.items { deleteImageFile(item) }
        for payload in finalizedPayloads {
            for item in payload.allItems {
                ExtensionResultStore.shared.forget(item.id)
                deleteImageFile(item)
            }
        }
    }

    private func newestUndoablePinboardDeletion(at date: Date) -> PendingPinboardDeletion? {
        pendingPinboardDeletions
            .filter { $0.isUndoable(at: date) }
            .max { $0.deletedAt < $1.deletedAt }
    }

    private func restorePinboard(_ pending: PendingPinboardDeletion, at date: Date) {
        pendingPinboardDeletions.removeAll { $0.board.id == pending.board.id }
        guard !pinboards.contains(where: { $0.id == pending.board.id }) else { return }
        var board = pending.board
        // Clips deleted from history while the board was gone stay gone;
        // their tombstones would remove them again on the next launch anyway.
        let tombstoned = deletionLedger.deletedIDs
        board.items.removeAll { tombstoned.contains($0.id) }
        board.prunePins()
        board.touch(at: date)
        pinboards.insert(board, at: min(max(0, board.sortIndex), pinboards.count))
        _ = normalizePinboardOrder(touchChanges: true)
    }

    /// Moves a Pinboard relative to the tab currently under the drag. The
    /// ordered array is already part of the persisted store snapshot.
    func movePinboard(_ movedID: UUID, over targetID: UUID) {
        guard movedID != targetID,
              let from = pinboards.firstIndex(where: { $0.id == movedID }),
              let to = pinboards.firstIndex(where: { $0.id == targetID }) else { return }
        let moved = pinboards.remove(at: from)
        // `to` is the target's pre-removal index. Inserting at that same index
        // lands after it when dragging right, and before it when dragging left.
        pinboards.insert(moved, at: to)
        _ = normalizePinboardOrder(touchChanges: true)
        scheduleSave()
    }

    /// Moves a Pinboard to sit immediately before `targetID`, regardless of
    /// which direction the drag came from — unlike `over:`, whose landing
    /// side depends on the pre-move index order. Used by row-wide drop
    /// resolution, where the insertion point is picked purely from the
    /// drop's x-position rather than from a specific tab's own bounds.
    func movePinboard(_ movedID: UUID, before targetID: UUID) {
        guard movedID != targetID,
              let from = pinboards.firstIndex(where: { $0.id == movedID }) else { return }
        let moved = pinboards.remove(at: from)
        guard let targetIndex = pinboards.firstIndex(where: { $0.id == targetID }) else {
            pinboards.insert(moved, at: min(from, pinboards.count))
            _ = normalizePinboardOrder(touchChanges: true)
            scheduleSave()
            return
        }
        pinboards.insert(moved, at: targetIndex)
        _ = normalizePinboardOrder(touchChanges: true)
        scheduleSave()
    }

    func movePinboard(_ id: UUID, by offset: Int) {
        guard let from = pinboards.firstIndex(where: { $0.id == id }) else { return }
        let to = min(pinboards.count - 1, max(0, from + offset))
        guard from != to else { return }
        pinboards.swapAt(from, to)
        _ = normalizePinboardOrder(touchChanges: true)
        scheduleSave()
    }

    func movePinboardToEnd(_ id: UUID) {
        guard let from = pinboards.firstIndex(where: { $0.id == id }),
              from != pinboards.count - 1 else { return }
        let moved = pinboards.remove(at: from)
        pinboards.append(moved)
        _ = normalizePinboardOrder(touchChanges: true)
        scheduleSave()
    }

    /// Reorders an item within its Pinboard. `targetID` is the item the moved
    /// one lands in front of — nil appends at the end. Anchoring to a neighbor
    /// rather than an index keeps drops correct while a search filter hides
    /// some of the board's items.
    func movePinboardItem(_ id: UUID, before targetID: UUID?, inBoard boardID: UUID) {
        guard id != targetID,
              let b = pinboards.firstIndex(where: { $0.id == boardID }),
              let from = pinboards[b].items.firstIndex(where: { $0.id == id }) else { return }
        let item = pinboards[b].items.remove(at: from)
        if let targetID, let to = pinboards[b].items.firstIndex(where: { $0.id == targetID }) {
            pinboards[b].items.insert(item, at: to)
        } else {
            pinboards[b].items.append(item)
        }
        // Dragging a card to a chosen position is an explicit statement about
        // where it belongs, so it stops being promoted — otherwise it would
        // spring back to the front and look like the drag was ignored.
        pinboards[b].pinnedItemIDs.removeAll { $0 == item.id }
        pinboards[b].touch()
        scheduleSave()
    }

    /// Promotes a clip to the front of its board, or returns it to the manual
    /// order. Pinning is per board: the same clip can sit on two boards and be
    /// promoted on only one of them.
    func togglePin(_ itemID: UUID, inBoard boardID: UUID) {
        guard let b = pinboards.firstIndex(where: { $0.id == boardID }),
              pinboards[b].items.contains(where: { $0.id == itemID }) else { return }
        if pinboards[b].pinnedItemIDs.contains(itemID) {
            pinboards[b].pinnedItemIDs.removeAll { $0 == itemID }
        } else {
            pinboards[b].pinnedItemIDs.insert(itemID, at: 0)
        }
        pinboards[b].prunePins()
        pinboards[b].touch()
        scheduleSave()
    }

    func isPinned(_ itemID: UUID, inBoard boardID: UUID) -> Bool {
        pinboards.first(where: { $0.id == boardID })?.isPinned(itemID) ?? false
    }

    /// The board the bar is currently showing, if any — cards need it to know
    /// whether they are promoted.
    var currentPinboardID: UUID? {
        if case .pinboard(let id) = source { return id }
        return nil
    }

    func saveToPinboard(_ item: ClipItem, boardID: UUID) {
        guard let i = pinboards.firstIndex(where: { $0.id == boardID }) else { return }
        if pinboards[i].items.contains(where: { $0.sameContent(as: item) }) { return }
        let copy = copyWithFreshIdentityAndOwnedImage(item)
        pinboards[i].items.insert(copy, at: 0)
        pinboards[i].touch()
        scheduleSave()
    }

    /// Duplicates the clip in the container currently shown by the bar. The
    /// new copy sits immediately before the original: History is newest-first,
    /// and the leading side is also the consistent adjacent side on Pinboards.
    @discardableResult
    func duplicate(_ item: ClipItem, at date: Date = .now) -> ClipItem? {
        switch source {
        case .history:
            guard let index = history.firstIndex(where: { $0.id == item.id }) else { return nil }
            let copy = copyWithFreshIdentityAndOwnedImage(history[index], at: date)
            history.insert(copy, at: index)
            _ = applyHistoryPolicyNow()
            selectedID = copy.id
            scheduleSave()
            return copy

        case .pinboard(let boardID):
            guard let boardIndex = pinboards.firstIndex(where: { $0.id == boardID }),
                  let itemIndex = pinboards[boardIndex].items.firstIndex(
                      where: { $0.id == item.id }
                  ) else { return nil }
            let original = pinboards[boardIndex].items[itemIndex]
            let copy = copyWithFreshIdentityAndOwnedImage(original, at: date)
            pinboards[boardIndex].items.insert(copy, at: itemIndex)
            if let pinnedIndex = pinboards[boardIndex].pinnedItemIDs.firstIndex(of: original.id) {
                pinboards[boardIndex].pinnedItemIDs.insert(copy.id, at: pinnedIndex)
            }
            pinboards[boardIndex].touch(at: date)
            selectedID = copy.id
            scheduleSave()
            return copy

        case .pasteStack:
            return nil
        }
    }

    /// Fresh container identity is paired with a fresh owned image file when
    /// one exists. If a legacy backing file is already missing, retaining its
    /// name matches the established Pinboard-copy fallback; deletion protects
    /// shared names with a reachability check.
    private func copyWithFreshIdentityAndOwnedImage(
        _ item: ClipItem,
        at date: Date = .now
    ) -> ClipItem {
        var copy = item.copiedWithFreshID(at: date)
        if let duplicateName = duplicateImageFile(item) {
            copy.imageFileName = duplicateName
        }
        return copy
    }

    /// `nil` or an all-whitespace title clears the card's name rather than
    /// storing an empty one, so `displayTitle` falls back to the contents and
    /// search never matches on a blank.
    func setTitle(_ title: String?, for item: ClipItem) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String? = (trimmed?.isEmpty ?? true) ? nil : trimmed
        var changed = false
        if let i = history.firstIndex(where: { $0.id == item.id }),
           history[i].customTitle != title {
            history[i].customTitle = title
            history[i].updatedAt = max(.now, history[i].updatedAt.addingTimeInterval(0.000_001))
            changed = true
        }
        for b in pinboards.indices {
            if let i = pinboards[b].items.firstIndex(where: { $0.id == item.id }),
               pinboards[b].items[i].customTitle != title {
                pinboards[b].items[i].customTitle = title
                pinboards[b].items[i].updatedAt = max(
                    .now,
                    pinboards[b].items[i].updatedAt.addingTimeInterval(0.000_001)
                )
                pinboards[b].touch()
                changed = true
            }
        }
        let stackChanged = PasteSequence.shared.updateItem(item.id) { existing in
            var updated = existing
            updated.customTitle = title
            return updated
        }
        if changed || stackChanged { scheduleSave() }
    }

    /// Finds the current version of a clip after it changes. A clip may live
    /// in history, a Pinboard, or a saved Paste Stack while keeping its ID.
    func item(withID id: UUID) -> ClipItem? {
        if let item = history.first(where: { $0.id == id }) { return item }
        if let item = pinboards.lazy.flatMap(\.items).first(where: { $0.id == id }) { return item }
        return PasteSequence.shared.item(withID: id)
    }

    /// Updates text, rich text, and links in place. The item identity and
    /// source attribution remain stable so every saved reference can update.
    @discardableResult
    func updateTextContent(_ text: String, richTextData: Data? = nil, for item: ClipItem) -> Bool {
        guard [.text, .richText, .link].contains(item.type),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        let type: ClipType = richTextData != nil ? .richText : (isWebLink(text) ? .link : .text)
        return updateContent(for: item) { existing in
            var updated = existing
            updated.type = type
            updated.text = text
            updated.rtfData = richTextData
            // Editor-produced RTF is now the authoritative rich payload. The
            // captured HTML described the pre-edit contents, and keeping it
            // would make Clean/Markdown paste prefer stale formatting/text.
            updated.htmlData = nil
            updated.colorHex = nil
            return updated
        }
    }

    /// Updates a color clip with a normalized sRGB hex value.
    @discardableResult
    func updateColorContent(_ hex: String, for item: ClipItem) -> Bool {
        guard item.type == .color, let color = NSColor(hex: hex) else { return false }
        let normalizedHex = color.hexString
        return updateContent(for: item) { existing in
            var updated = existing
            updated.type = .color
            updated.text = nil
            updated.rtfData = nil
            updated.colorHex = normalizedHex
            return updated
        }
    }

    @discardableResult
    private func updateContent(for item: ClipItem,
                               transform: (ClipItem) -> ClipItem) -> Bool {
        var changed = false

        if let i = history.firstIndex(where: { $0.id == item.id }) {
            var updated = transform(history[i])
            if updated != history[i] {
                updated.updatedAt = max(.now, history[i].updatedAt.addingTimeInterval(0.000_001))
                history[i] = updated
                changed = true
            }
        }

        for boardIndex in pinboards.indices {
            for itemIndex in pinboards[boardIndex].items.indices
            where pinboards[boardIndex].items[itemIndex].id == item.id {
                var updated = transform(pinboards[boardIndex].items[itemIndex])
                if updated != pinboards[boardIndex].items[itemIndex] {
                    updated.updatedAt = max(
                        .now,
                        pinboards[boardIndex].items[itemIndex].updatedAt.addingTimeInterval(0.000_001)
                    )
                    pinboards[boardIndex].items[itemIndex] = updated
                    pinboards[boardIndex].touch()
                    changed = true
                }
            }
        }

        if PasteSequence.shared.updateItem(item.id, transform: transform) {
            changed = true
        }

        guard changed else { return false }
        if selectedID != nil, selectedItem == nil { selectFirst() }
        scheduleSave()
        return true
    }

    private func isWebLink(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains(" "), !value.contains("\n"),
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return false }
        return true
    }

    func selectFirst() {
        let firstID = visibleItems.first?.id
        let alreadySelected = selection.lead == firstID
            && selection.count == (firstID == nil ? 0 : 1)
        guard !alreadySelected else { return }
        selectedID = firstID
    }

    func prepareForBarPresentation() {
        if refreshDeletionState(at: .now) { saveNow() }
        let firstID = visibleItems.first?.id
        initialScrollTargetID = firstID
        selectedID = firstID
    }

    /// `extending` is ⇧-arrow: it grows or shrinks the run from the anchor
    /// instead of moving a single selection.
    func moveSelection(by delta: Int, extending: Bool = false) {
        let items = visibleItems
        guard !items.isEmpty else { return }
        guard let id = selectedID, let idx = items.firstIndex(where: { $0.id == id }) else {
            selectedID = items.first?.id; return
        }
        let next = max(0, min(items.count - 1, idx + delta))
        if extending {
            extendSelection(to: items[next].id)
        } else {
            selectedID = items[next].id
        }
    }

    func imageURL(for item: ClipItem) -> URL? {
        guard let name = item.imageFileName,
              URL(fileURLWithPath: name).lastPathComponent == name else { return nil }
        if name.hasPrefix("stack-") {
            return stackImagesDir.appendingPathComponent(name)
        }
        return imagesDir.appendingPathComponent(name)
    }

    func loadImage(for item: ClipItem) -> NSImage? {
        guard let url = imageURL(for: item) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// The image a clip should show in Pesty's preview surfaces.
    ///
    /// Image-file clips retain their original file URL so they still paste as
    /// files. A sandboxed build (including the Xcode Mac Development scheme)
    /// cannot necessarily read that URL again, though, so fall back to the
    /// private pixel copy captured alongside it.
    func loadPreviewImage(for item: ClipItem) -> NSImage? {
        switch item.type {
        case .image:
            return loadImage(for: item)
        case .file:
            guard item.fileURLs.count == 1 else { return nil }
            if let value = item.fileURLs.first,
               let url = URL(string: value),
               url.isFileURL,
               let image = NSImage(contentsOf: url) {
                return image
            }
            return loadImage(for: item)
        default:
            return loadImage(for: item)
        }
    }

    func storeImageData(_ data: Data, imageHash: String? = nil) -> String? {
        if let imageHash {
            let existing = history.lazy.filter { $0.imageHash == imageHash }
                .compactMap(\.imageFileName).first { name in
                    FileManager.default.fileExists(atPath: imagesDir.appendingPathComponent(name).path)
                }
                ?? pinboards.lazy.flatMap(\.items).filter { $0.imageHash == imageHash }
                    .compactMap(\.imageFileName).first { name in
                        FileManager.default.fileExists(atPath: imagesDir.appendingPathComponent(name).path)
                    }
            if let existing { return existing }
        }
        let name = "\(UUID().uuidString).png"
        let url = imagesDir.appendingPathComponent(name)
        do {
            try data.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return name
        } catch { return nil }
    }

    /// A Stack owns a separate clip identity and a separate local image. Its
    /// payload never depends on History, a Pinboard, or an iCloud Drive image.
    func makePasteStackCopy(of item: ClipItem) -> ClipItem? {
        localStackCopy(of: item)
    }

    private func localStackCopy(of item: ClipItem, imageSource: URL? = nil) -> ClipItem? {
        var copy = item.copiedWithFreshID()
        if item.imageFileName != nil {
            guard let source = imageSource ?? imageURL(for: item),
                  let data = try? Data(contentsOf: source),
                  data.count <= CKSchema.maximumAssetBytes else { return nil }
            let name = "stack-\(UUID().uuidString).png"
            let destination = stackImagesDir.appendingPathComponent(name)
            do {
                try data.write(to: destination, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: destination.path
                )
            } catch { return nil }
            copy.imageFileName = name
        }
        return copy
    }

    // MARK: - CloudKit bridge (Mac App Store build)

    struct CloudSyncClip {
        var item: ClipItem
        var container: String
    }

    /// Pending five-minute deletions remain visible to the sync engine until
    /// their payload expires. At that boundary they disappear from this
    /// projection and CKSyncEngine queues the hard record deletion.
    /// Every pinboard the cloud should still know about: the live ones plus
    /// those whose deletion can still be undone. A board is only removed
    /// from the cloud once its Undo window has closed.
    var cloudSyncPinboards: [Pinboard] {
        pinboards + pendingPinboardDeletions.map(\.board)
    }

    var cloudSyncClips: [CloudSyncClip] {
        var byID: [UUID: CloudSyncClip] = [:]
        for board in cloudSyncPinboards {
            for item in board.items {
                byID[item.id] = CloudSyncClip(item: item, container: board.id.uuidString)
            }
        }
        for item in history where byID[item.id] == nil {
            byID[item.id] = CloudSyncClip(item: item, container: CKSchema.historyContainerValue)
        }
        for record in deletionLedger.records
        where record.isDeleted && record.finalizedAt == nil {
            guard let payload = record.payload else { continue }
            for placement in payload.pinboards where byID[placement.item.id] == nil {
                byID[placement.item.id] = CloudSyncClip(
                    item: placement.item,
                    container: placement.pinboardID.uuidString
                )
            }
            for placement in payload.history where byID[placement.item.id] == nil {
                byID[placement.item.id] = CloudSyncClip(
                    item: placement.item,
                    container: CKSchema.historyContainerValue
                )
            }
        }
        return Array(byID.values)
    }

    func applyRemote(
        clips: [CloudRecordCodec.DecodedClip],
        boards: [CloudRecordCodec.DecodedBoard],
        deletedIDs: [UUID],
        at date: Date = .now
    ) {
        guard !clips.isEmpty || !boards.isEmpty || !deletedIDs.isEmpty else { return }
        var removedAssets: [ClipItem] = []
        var displacedStackRestorations: [UUID: [PasteStackEntryPlacement]] = [:]
        var displacedStackItems: [ClipItem] = []

        // Clips first: a Pinboard record in the same batch can then impose its
        // authoritative membership order in one pass.
        for decoded in clips {
            var item = decoded.item
            guard deletionLedger.permitsRemotePresence(id: item.id, updatedAt: item.updatedAt),
                  !Settings.shared.isIgnoringSourceApp(item.sourceBundleID) else { continue }
            // CloudKit can deliver an older edit after a newer local one.
            // Keep the local winner so the sync engine can publish it again.
            let local = history.first(where: { $0.id == item.id })
                ?? pinboards.lazy.flatMap(\.items).first(where: { $0.id == item.id })
            if let local, local.updatedAt > item.updatedAt { continue }
            if let source = decoded.imageAssetURL {
                item = copyRemoteImageAsset(for: item, from: source)
            }
            deletionLedger.acceptRemotePresence(id: item.id, at: item.updatedAt)
            if !deletionLedger.hasPendingDeletion(id: item.id) {
                if let placements = pendingStackRestorations.removeValue(forKey: item.id) {
                    displacedStackRestorations[item.id] = placements
                    displacedStackItems += placements.map { $0.entry.item }
                }
            }

            if decoded.container == CKSchema.historyContainerValue {
                removedAssets += removeClipEverywhere(id: item.id)
                if let duplicateIndex = history.firstIndex(where: { $0.sameContent(as: item) }) {
                    let duplicate = history[duplicateIndex]
                    if duplicate.updatedAt > item.updatedAt {
                        removedAssets.append(item)
                        continue
                    }
                    removedAssets.append(history.remove(at: duplicateIndex))
                }
                insertByUsageDate(item, into: &history)
            } else if let boardID = UUID(uuidString: decoded.container) {
                removedAssets += removeClipEverywhere(id: item.id)
                if !pinboards.contains(where: { $0.id == boardID }) {
                    pinboards.append(Pinboard(
                        id: boardID,
                        name: "Pinboard",
                        items: [],
                        createdAt: .distantPast,
                        updatedAt: .distantPast,
                        sortIndex: Int.max
                    ))
                }
                guard let boardIndex = pinboards.firstIndex(where: { $0.id == boardID }) else { continue }
                if let duplicateIndex = pinboards[boardIndex].items.firstIndex(
                    where: { $0.sameContent(as: item) }
                ) {
                    let duplicate = pinboards[boardIndex].items[duplicateIndex]
                    if duplicate.updatedAt > item.updatedAt {
                        removedAssets.append(item)
                        continue
                    }
                    removedAssets.append(pinboards[boardIndex].items.remove(at: duplicateIndex))
                }
                insertByUsageDate(item, into: &pinboards[boardIndex].items)
            }
        }

        for decoded in boards {
            let remote = decoded.board
            // A board deleted here and still undoable keeps its local state;
            // the cloud record it came from is ours until the window closes.
            if pendingPinboardDeletions.contains(where: { $0.board.id == remote.id }) { continue }
            if let index = pinboards.firstIndex(where: { $0.id == remote.id }) {
                guard remote.updatedAt >= pinboards[index].updatedAt else { continue }
                let existingByID = Dictionary(
                    pinboards[index].items.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                let ordered = decoded.clipIDs.compactMap { existingByID[$0] }
                let retainedIDs = Set(ordered.map(\.id))
                removedAssets += pinboards[index].items.filter { !retainedIDs.contains($0.id) }
                pinboards[index].name = remote.name
                pinboards[index].colorHex = remote.colorHex
                pinboards[index].createdAt = remote.createdAt
                pinboards[index].updatedAt = remote.updatedAt
                pinboards[index].sortIndex = remote.sortIndex
                pinboards[index].items = ordered
                pinboards[index].pinnedItemIDs = remote.pinnedItemIDs.filter(retainedIDs.contains)
            } else {
                pinboards.append(remote)
            }
        }
        pinboards.sort {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.id.uuidString < $1.id.uuidString
        }

        if !deletedIDs.isEmpty {
            let deleted = Set(deletedIDs)
            let removedBoards = pinboards.filter { deleted.contains($0.id) }
                + pendingPinboardDeletions.filter { deleted.contains($0.board.id) }.map(\.board)
            pendingPinboardDeletions.removeAll { deleted.contains($0.board.id) }
            removedAssets += removedBoards.flatMap(\.items)
            for item in removedBoards.flatMap(\.items) {
                deletionLedger.recordRemoteDeletion(
                    id: item.id,
                    removesFromPasteStacks: false,
                    at: date
                )
            }
            pinboards.removeAll { deleted.contains($0.id) }
            for id in deletedIDs {
                if let placements = pendingStackRestorations.removeValue(forKey: id) {
                    displacedStackRestorations[id] = placements
                    displacedStackItems += placements.map { $0.entry.item }
                }
                if cloudRetentionExcludedIDs.remove(id) != nil {
                    saveCloudRetentionExclusions()
                }
                let removed = removeClipEverywhere(id: id)
                removedAssets += removed
                if !removed.isEmpty || deletionLedger.records.contains(where: { $0.id == id }) {
                    deletionLedger.recordRemoteDeletion(
                        id: id,
                        removesFromPasteStacks: Settings.shared.pasteStacksFollowHistory,
                        at: date
                    )
                }
                if !removed.isEmpty, Settings.shared.pasteStacksFollowHistory {
                    PasteSequence.shared.removeHistoryItems([id])
                }
            }
            if case .pinboard(let current) = source, deleted.contains(current) {
                source = .history
            }
        }

        _ = normalizePinboardOrder(touchChanges: false)

        applyHistoryPolicyNow()
        for index in pinboards.indices { pinboards[index].prunePins() }
        pruneSelection()
        if selectedID == nil { selectFirst() }
        _ = refreshDeletionState(at: date)
        if !displacedStackItems.isEmpty {
            if savePasteStacks(PasteSequence.shared.savedStacks) {
                for item in displacedStackItems { deleteImageFile(item) }
            } else {
                pendingStackRestorations.merge(displacedStackRestorations) {
                    existing, _ in existing
                }
            }
        }
        for item in removedAssets { deleteImageFile(item) }
        saveNow()
    }

    private func removeClipEverywhere(id: UUID) -> [ClipItem] {
        var removed = history.filter { $0.id == id }
        history.removeAll { $0.id == id }
        for index in pinboards.indices {
            removed += pinboards[index].items.filter { $0.id == id }
            pinboards[index].items.removeAll { $0.id == id }
            pinboards[index].pinnedItemIDs.removeAll { $0 == id }
        }
        return removed
    }

    private func insertByUsageDate(_ item: ClipItem, into items: inout [ClipItem]) {
        let date = item.lastUsedAt ?? item.createdAt
        let index = items.firstIndex {
            ($0.lastUsedAt ?? $0.createdAt) < date
        } ?? items.endIndex
        items.insert(item, at: index)
    }

    private func copyRemoteImageAsset(for item: ClipItem, from source: URL) -> ClipItem {
        var item = item
        guard let name = item.imageFileName,
              URL(fileURLWithPath: name).lastPathComponent == name,
              let data = try? Data(contentsOf: source),
              data.count <= CKSchema.maximumAssetBytes else {
            item.imageFileName = nil
            return item
        }
        let destination = imagesDir.appendingPathComponent(name)
        do {
            try data.write(to: destination, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        } catch {
            item.imageFileName = nil
        }
        return item
    }

    private func duplicateImageFile(_ item: ClipItem) -> String? {
        guard let src = imageURL(for: item), FileManager.default.fileExists(atPath: src.path) else { return nil }
        let name = "\(UUID().uuidString).png"
        let dst = imagesDir.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: src, to: dst)
            return name
        } catch {
            return nil
        }
    }

    /// Stores written before per-container identity could reuse one UUID in
    /// History and one or more Pinboards. Repair only collisions: already
    /// distinct Pinboard entities retain their stable IDs.
    @discardableResult
    /// Screenshots captured before Pesty kept a copy of a copied image file
    /// have only a path. Where that file is still readable, take the pixels
    /// now so the card survives the file moving and the iPhone gets a
    /// picture. `updatedAt` moves so the other devices accept the new
    /// version. Bounded per launch: this reads files on the main thread.
    private func backfillImageFilePixels(at date: Date, limit: Int = 50) -> Bool {
        var remaining = limit
        var changed = false
        func fill(_ item: inout ClipItem) {
            guard remaining > 0,
                  item.type == .file, item.imageFileName == nil, item.fileURLs.count == 1,
                  let url = URL(string: item.fileURLs[0]),
                  let data = ClipboardMonitor.imageFileData(at: url),
                  let name = storeImageData(data) else { return }
            remaining -= 1
            item.imageFileName = name
            item.imageHash = ClipboardMonitor.sha256Hex(data)
            item.updatedAt = max(date, item.updatedAt.addingTimeInterval(0.000_001))
            changed = true
        }
        for index in history.indices { fill(&history[index]) }
        for boardIndex in pinboards.indices {
            for index in pinboards[boardIndex].items.indices { fill(&pinboards[boardIndex].items[index]) }
        }
        return changed
    }

    private func migrateLegacySharedClipIDs() -> Bool {
        // Older stores could use one ID for both History and a Pinboard.
        // Include a deleted History item's ID so a surviving Pinboard copy is
        // remapped before the History tombstone is applied below.
        let deletedHistoryIDs = Set(deletionLedger.records.compactMap { record in
            record.isDeleted && record.payload?.history.isEmpty == false ? record.id : nil
        })
        let deletedPinboardIDs = Set(deletionLedger.records.compactMap { record in
            record.isDeleted && record.payload?.pinboards.isEmpty == false
                && record.payload?.history.isEmpty != false ? record.id : nil
        })
        // Finalized legacy records no longer carry their Undo payload, so the
        // original container cannot be recovered. A live copy in store.json
        // is the only surviving evidence of the shared-ID bug; preserve it
        // under a new ID instead of letting the old tombstone erase it.
        let finalizedIDs = Set(deletionLedger.records.compactMap { record in
            record.isDeleted && record.payload == nil ? record.id : nil
        })
        var changed = false

        for index in history.indices
        where deletedPinboardIDs.contains(history[index].id)
            || finalizedIDs.contains(history[index].id) {
            let item = history[index]
            var copy = item.copiedWithFreshID()
            if let duplicateName = duplicateImageFile(item) { copy.imageFileName = duplicateName }
            history[index] = copy
            changed = true
        }

        var seen = Set(history.map(\.id))
            .union(deletedHistoryIDs)
            .union(finalizedIDs)

        for boardIndex in pinboards.indices {
            var remappedPins: [UUID: UUID] = [:]
            for itemIndex in pinboards[boardIndex].items.indices {
                let item = pinboards[boardIndex].items[itemIndex]
                guard !seen.insert(item.id).inserted else { continue }

                var copy = item.copiedWithFreshID()
                if let duplicateName = duplicateImageFile(item) {
                    copy.imageFileName = duplicateName
                }
                pinboards[boardIndex].items[itemIndex] = copy
                remappedPins[item.id] = copy.id
                seen.insert(copy.id)
                changed = true
            }
            if !remappedPins.isEmpty {
                pinboards[boardIndex].pinnedItemIDs = pinboards[boardIndex].pinnedItemIDs.map {
                    remappedPins[$0] ?? $0
                }
                pinboards[boardIndex].touch()
            }
        }
        return changed
    }

    @discardableResult
    private func normalizePinboardOrder(
        at date: Date = .now,
        touchChanges: Bool
    ) -> Bool {
        var changed = false
        for index in pinboards.indices where pinboards[index].sortIndex != index {
            pinboards[index].sortIndex = index
            if touchChanges { pinboards[index].touch(at: date) }
            changed = true
        }
        return changed
    }

    private var cloudRetentionExclusionsURL: URL {
        ClipboardStore.localBase.appendingPathComponent("ck-retention-exclusions.json")
    }

    private func loadCloudRetentionExclusions() -> Set<UUID> {
        guard let data = try? Data(contentsOf: cloudRetentionExclusionsURL),
              let ids = try? JSONDecoder().decode(Set<UUID>.self, from: data) else { return [] }
        return ids
    }

    private func recordCloudRetentionExclusions<S: Sequence>(_ ids: S) where S.Element == UUID {
        let previousCount = cloudRetentionExcludedIDs.count
        cloudRetentionExcludedIDs.formUnion(ids)
        guard cloudRetentionExcludedIDs.count != previousCount else { return }
        saveCloudRetentionExclusions()
    }

    private func saveCloudRetentionExclusions() {
        guard let data = try? JSONEncoder().encode(cloudRetentionExcludedIDs) else { return }
        try? FileManager.default.createDirectory(
            at: ClipboardStore.localBase,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: cloudRetentionExclusionsURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: cloudRetentionExclusionsURL.path
        )
    }

    private func deleteImageFile(_ item: ClipItem) {
        guard let name = item.imageFileName else { return }
        let stillUsed = history.contains { $0.imageFileName == name }
            || pinboards.contains { $0.items.contains { $0.imageFileName == name } }
            || pendingPinboardDeletions.contains { $0.board.items.contains { $0.imageFileName == name } }
            || PasteSequence.shared.savedStacks.contains { stack in
                stack.entries.contains { $0.item.imageFileName == name }
            }
            || pendingStackRestorations.values.contains { placements in
                placements.contains { $0.entry.item.imageFileName == name }
            }
            || deletionLedger.retainsImageFile(named: name)
        if stillUsed { return }
        if let url = imageURL(for: item) { try? FileManager.default.removeItem(at: url) }
    }

    struct Snapshot: Codable {
        var history: [ClipItem]
        var pinboards: [Pinboard]
        /// Decode-only legacy field. New Stack data is device-local.
        var pasteStacks: [SavedPasteStack]?
        var deletionLedger: ClipDeletionLedger?
        var pendingPinboardDeletions: [PendingPinboardDeletion]?
    }

    private struct LocalStackSnapshot: Codable {
        let version: Int
        let stacks: [SavedPasteStack]
        let pendingRestorations: [UUID: [PasteStackEntryPlacement]]

        init(version: Int, stacks: [SavedPasteStack],
             pendingRestorations: [UUID: [PasteStackEntryPlacement]]) {
            self.version = version
            self.stacks = stacks
            self.pendingRestorations = pendingRestorations
        }

        private enum CodingKeys: String, CodingKey { case version, stacks, pendingRestorations }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            stacks = try container.decode([SavedPasteStack].self, forKey: .stacks)
            pendingRestorations = try container.decodeIfPresent(
                [UUID: [PasteStackEntryPlacement]].self, forKey: .pendingRestorations
            ) ?? [:]
        }
    }

    private func loadLocalStacks() -> LocalStackSnapshot? {
        guard FileManager.default.fileExists(atPath: stackStoreURL.path) else { return nil }
        guard let data = try? Data(contentsOf: stackStoreURL),
              let snapshot = try? JSONDecoder().decode(LocalStackSnapshot.self, from: data),
              snapshot.version == 1 else {
            // Never overwrite an unreadable stack store with an empty one.
            stackStoreLoadFailed = true
            return nil
        }
        return snapshot
    }

    @discardableResult
    private func savePasteStacks(_ stacks: [SavedPasteStack]) -> Bool {
        guard !stackStoreLoadFailed, !legacyStacksNeedMigration,
              let data = try? JSONEncoder().encode(LocalStackSnapshot(
                  version: 1, stacks: stacks, pendingRestorations: pendingStackRestorations
              )) else {
            return false
        }
        do {
            try data.write(to: stackStoreURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: stackStoreURL.path
            )
            lastPersistedStacks = stacks
            return true
        } catch { return false }
    }

    /// A damaged Stack store must not block a History operation that did not
    /// change any Stack data. The encoded form omits transient image previews.
    private func saveStacksForDeletionTransaction(
        before stacks: [SavedPasteStack],
        restorations: [UUID: [PasteStackEntryPlacement]]
    ) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = LocalStackSnapshot(
            version: 1, stacks: stacks, pendingRestorations: restorations
        )
        let after = LocalStackSnapshot(
            version: 1, stacks: PasteSequence.shared.savedStacks,
            pendingRestorations: pendingStackRestorations
        )
        guard let oldData = try? encoder.encode(before),
              let newData = try? encoder.encode(after) else { return false }
        if oldData == newData { return true }
        return savePasteStacks(PasteSequence.shared.savedStacks)
    }

    private func migrateLegacyStacks(
        _ stacks: [SavedPasteStack],
        historyIDs: Set<UUID>? = nil,
        legacyImagesDir: URL? = nil
    ) -> [SavedPasteStack]? {
        var migrated: [SavedPasteStack] = []
        var copiedItems: [ClipItem] = []
        let origins = historyIDs ?? Set(history.map(\.id))
        for stack in stacks {
            var copy = stack
            var entries: [PasteStackEntry] = []
            for entry in stack.entries {
                let imageSource = entry.item.imageFileName.flatMap { name in
                    legacyImagesDir?.appendingPathComponent(name)
                }
                guard let item = localStackCopy(of: entry.item, imageSource: imageSource) else {
                    for copied in copiedItems { deleteImageFile(copied) }
                    return nil
                }
                copiedItems.append(item)
                let origin = entry.originHistoryID
                    ?? (origins.contains(entry.item.id) ? entry.item.id : nil)
                entries.append(PasteStackEntry(
                    id: entry.id, item: item, originHistoryID: origin,
                    imagePreview: nil, isPasted: entry.isPasted
                ))
            }
            copy.entries = entries
            migrated.append(copy)
        }
        return migrated
    }

    private func pruneUnreferencedStackImages() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: stackImagesDir, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("stack-")
            && file.pathExtension.lowercased() == "png" {
            deleteImageFile(ClipItem(type: .image, imageFileName: file.lastPathComponent))
        }
    }

    private var legacyLibraryMigrationMarkerURL: URL {
        ClipboardStore.localBase.appendingPathComponent("legacy-library-migration-v1")
    }

    private var bundledLegacyLibraryURL: URL {
        ClipboardStore.localBase
            .deletingLastPathComponent()
            .appendingPathComponent("Pesty Legacy Import", isDirectory: true)
    }

    private func resolveBundledLegacyLibraryMigration(hadStoreAtLaunch: Bool) {
        guard ClipboardStore.isSandboxed, !legacyLibraryMigrationResolved else { return }
        let legacyStore = bundledLegacyLibraryURL.appendingPathComponent("store.json")
        if FileManager.default.fileExists(atPath: legacyStore.path) {
            _ = try? importLegacyLibrary(at: bundledLegacyLibraryURL)
        } else if !hadStoreAtLaunch {
            // A brand-new sandbox has no pre-sandbox library to migrate. Mark
            // it resolved so first-time users are not shown an irrelevant picker.
            markLegacyLibraryMigrationResolved()
        }
    }

    func markLegacyLibraryMigrationResolved() {
        try? Data().write(to: legacyLibraryMigrationMarkerURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: legacyLibraryMigrationMarkerURL.path
        )
        legacyLibraryMigrationResolved = true
    }

    func previewLegacyLibrary(at directory: URL) throws -> LegacyLibraryImportSummary {
        let snapshot = try Self.loadLegacySnapshot(from: directory)
        let images = Self.referencedImageNames(in: snapshot).filter { name in
            guard Self.isSafeImageFileName(name) else { return false }
            let url = directory
                .appendingPathComponent("images", isDirectory: true)
                .appendingPathComponent(name)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                return false
            }
            return size >= 0 && size <= CKSchema.maximumAssetBytes
        }
        return LegacyLibraryImportSummary(
            historyClipCount: snapshot.history.count,
            pinboardCount: snapshot.pinboards.count,
            pasteStackCount: snapshot.pasteStacks?.count ?? 0,
            imageCount: images.count
        )
    }

    @discardableResult
    func importLegacyLibrary(at directory: URL) throws -> LegacyLibraryImportSummary {
        var legacy = try Self.loadLegacySnapshot(from: directory)
        let deletedIDs = Set(deletionLedger.records.filter(\.isDeleted).map(\.id))
        legacy.history.removeAll { deletedIDs.contains($0.id) }
        for index in legacy.pinboards.indices {
            legacy.pinboards[index].items.removeAll { deletedIDs.contains($0.id) }
            legacy.pinboards[index].prunePins()
        }
        if var stacks = legacy.pasteStacks {
            for stackIndex in stacks.indices {
                stacks[stackIndex].entries.removeAll {
                    deletedIDs.contains($0.originHistoryID ?? $0.item.id)
                }
            }
            legacy.pasteStacks = stacks
        }

        let availableImages = copyLegacyImages(in: legacy, from: directory)
        if let stacks = legacy.pasteStacks {
            guard let migrated = migrateLegacyStacks(
                stacks,
                historyIDs: Set(history.map(\.id)).union(legacy.history.map(\.id)),
                legacyImagesDir: directory.appendingPathComponent("images", isDirectory: true)
            ) else { throw LegacyLibraryImportError.stackMigrationFailed }
            legacy.pasteStacks = migrated
        }
        legacy = Self.removingUnavailableImages(from: legacy, available: availableImages)
        let summary = LegacyLibraryImportSummary(
            historyClipCount: legacy.history.count,
            pinboardCount: legacy.pinboards.count,
            pasteStackCount: legacy.pasteStacks?.count ?? 0,
            imageCount: availableImages.count
        )
        let current = Snapshot(
            history: history,
            pinboards: pinboards,
            pasteStacks: PasteSequence.shared.savedStacks,
            deletionLedger: deletionLedger
        )
        let merged = Self.mergingSnapshots(current: current, legacy: legacy)
        guard savePasteStacks(merged.pasteStacks ?? []) else {
            throw LegacyLibraryImportError.stackMigrationFailed
        }
        history = merged.history.sorted {
            ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt)
        }
        let importedHistoryIDs = Set(legacy.history.map(\.id))
        let previousExclusionCount = cloudRetentionExcludedIDs.count
        cloudRetentionExcludedIDs.subtract(importedHistoryIDs)
        if cloudRetentionExcludedIDs.count != previousExclusionCount {
            saveCloudRetentionExclusions()
        }
        expandHistoryPolicyToPreserveMigration()
        pinboards = merged.pinboards
        PasteSequence.shared.restoreSavedStacks(merged.pasteStacks ?? [])
        _ = migrateLegacySharedClipIDs()
        _ = normalizePinboardOrder(touchChanges: false)
        _ = applyHistoryPolicyNow()
        for index in pinboards.indices { pinboards[index].prunePins() }
        selectFirst()
        guard saveNow() else { throw LegacyLibraryImportError.unreadableStore }
        markLegacyLibraryMigrationResolved()
        return summary
    }

    private func expandHistoryPolicyToPreserveMigration() {
        switch Settings.shared.historyRetentionMode {
        case .itemCount:
            if history.count > Settings.shared.historyLimit {
                Settings.shared.historyLimit = min(5_000, history.count)
            }
        case .timePeriod:
            guard let oldestCreationDate = history.map(\.createdAt).min(),
                  let currentCutoff = Settings.shared.historyRetention.cutoffDate,
                  oldestCreationDate < currentCutoff else { return }
            let preservingRetention = HistoryRetention.allCases.first { retention in
                guard let cutoff = retention.cutoffDate else { return true }
                return oldestCreationDate >= cutoff
            } ?? .forever
            Settings.shared.historyRetention = preservingRetention
        }
    }

    static func mergingSnapshots(current: Snapshot, legacy: Snapshot) -> Snapshot {
        var history = current.history
        var historyIDs = Set(history.map(\.id))
        history.append(contentsOf: legacy.history.filter { historyIDs.insert($0.id).inserted })

        var pinboards = current.pinboards
        var boardIDs = Set(pinboards.map(\.id))
        pinboards.append(contentsOf: legacy.pinboards.filter { boardIDs.insert($0.id).inserted })

        var pasteStacks = current.pasteStacks ?? []
        var stackIDs = Set(pasteStacks.map(\.id))
        pasteStacks.append(contentsOf: (legacy.pasteStacks ?? []).filter {
            stackIDs.insert($0.id).inserted
        })

        return Snapshot(
            history: history,
            pinboards: pinboards,
            pasteStacks: pasteStacks,
            deletionLedger: current.deletionLedger
        )
    }

    private static func loadLegacySnapshot(from directory: URL) throws -> Snapshot {
        let store = directory.appendingPathComponent("store.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: store.path) else {
            throw LegacyLibraryImportError.missingStore
        }
        guard let data = try? Data(contentsOf: store),
              let snapshot = try? Self.decodeSnapshot(data, from: store) else {
            throw LegacyLibraryImportError.unreadableStore
        }
        return snapshot
    }

    private static func referencedImageNames(in snapshot: Snapshot) -> Set<String> {
        var items = snapshot.history + snapshot.pinboards.flatMap(\.items)
        items += (snapshot.pasteStacks ?? []).flatMap(\.entries).map(\.item)
        return Set(items.compactMap(\.imageFileName))
    }

    private static func isSafeImageFileName(_ name: String) -> Bool {
        !name.isEmpty && URL(fileURLWithPath: name).lastPathComponent == name
    }

    private func copyLegacyImages(in snapshot: Snapshot, from directory: URL) -> Set<String> {
        let sourceDirectory = directory.appendingPathComponent("images", isDirectory: true)
        var available: Set<String> = []
        let mainItems = snapshot.history + snapshot.pinboards.flatMap(\.items)
        for name in Set(mainItems.compactMap(\.imageFileName))
        where Self.isSafeImageFileName(name) {
            let source = sourceDirectory.appendingPathComponent(name)
            let destination = imagesDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                available.insert(name)
                continue
            }
            guard let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size >= 0,
                  size <= CKSchema.maximumAssetBytes else { continue }
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destination.path
                )
                available.insert(name)
            } catch {
                continue
            }
        }
        return available
    }

    private static func removingUnavailableImages(
        from snapshot: Snapshot,
        available: Set<String>
    ) -> Snapshot {
        func sanitized(_ item: ClipItem) -> ClipItem {
            var item = item
            if let name = item.imageFileName, !available.contains(name) {
                item.imageFileName = nil
            }
            return item
        }

        var snapshot = snapshot
        snapshot.history = snapshot.history.map(sanitized)
        for index in snapshot.pinboards.indices {
            snapshot.pinboards[index].items = snapshot.pinboards[index].items.map(sanitized)
        }
        return snapshot
    }

    @discardableResult
    private func load() -> Bool {
        let storeExists = FileManager.default.fileExists(atPath: storeURL.path)
        guard let data = try? Data(contentsOf: storeURL),
              let snap = try? Self.decodeSnapshot(data, from: storeURL) else {
            if storeExists {
                // An unreadable library is not an empty library. In particular,
                // startup policy and future captures must not replace it.
                storeLoadFailed = true
                return false
            }
            let local = loadLocalStacks()
            pendingStackRestorations = local?.pendingRestorations ?? [:]
            lastPersistedStacks = local?.stacks ?? []
            PasteSequence.shared.restoreSavedStacks(local?.stacks ?? [])
            return false
        }
        history = snap.history
        pinboards = snap.pinboards
        deletionLedger = snap.deletionLedger ?? ClipDeletionLedger()
        pendingPinboardDeletions = snap.pendingPinboardDeletions ?? []
        var migratedStacks = false
        if let local = loadLocalStacks() {
            pendingStackRestorations = local.pendingRestorations
            lastPersistedStacks = local.stacks
            PasteSequence.shared.restoreSavedStacks(local.stacks)
            migratedStacks = snap.pasteStacks != nil
        } else if let legacyStacks = snap.pasteStacks, !legacyStacks.isEmpty {
            let localStacks = stackStoreLoadFailed ? nil : migrateLegacyStacks(legacyStacks)
            if let localStacks, savePasteStacks(localStacks) {
                PasteSequence.shared.restoreSavedStacks(localStacks)
                migratedStacks = true
            } else {
                lastPersistedStacks = legacyStacks
                PasteSequence.shared.restoreSavedStacks(legacyStacks)
                legacyStacksNeedMigration = true
                // A partially copied migration must not leave an extra image
                // for each attempted edit or each subsequent launch.
                pruneUnreferencedStackImages()
            }
        } else {
            PasteSequence.shared.restoreSavedStacks([])
        }
        let oldLedger = deletionLedger
        let oldRestorations = pendingStackRestorations
        let legacyRestorations = deletionLedger.extractStackPlacements()
        pendingStackRestorations.merge(legacyRestorations) { existing, _ in existing }
        pendingStackRestorations = pendingStackRestorations.filter {
            deletionLedger.hasPendingDeletion(id: $0.key)
        }
        if !legacyRestorations.isEmpty
            || Set(oldRestorations.keys) != Set(pendingStackRestorations.keys) {
            if !legacyStacksNeedMigration,
               savePasteStacks(PasteSequence.shared.savedStacks) {
                migratedStacks = true
            } else {
                deletionLedger = oldLedger
                pendingStackRestorations = oldRestorations
            }
        }
        let migratedLegacyIDs = migrateLegacySharedClipIDs()
        var removed = applyDeletionTombstones()
        if legacyStacksNeedMigration {
            lastPersistedStacks = PasteSequence.shared.savedStacks
        }
        let retentionExcluded = history.filter { cloudRetentionExcludedIDs.contains($0.id) }
        history.removeAll { cloudRetentionExcludedIDs.contains($0.id) }
        removed += retentionExcluded
        let normalizedBoardOrder = normalizePinboardOrder(touchChanges: false)
        for item in removed { deleteImageFile(item) }
        selectFirst()
        if migratedStacks { pruneUnreferencedStackImages() }
        return !removed.isEmpty || migratedLegacyIDs || normalizedBoardOrder || migratedStacks
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveInBackground() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Capture a value snapshot on the main actor, then do the expensive JSON
    /// encoding and atomic file write away from the card and hotkey UI. Explicit
    /// transactions still call saveNow() and wait for their durability result.
    private func saveInBackground() {
        guard !storeLoadFailed else { return }
        guard let snapshot = snapshotForSave() else { return }
        let url = storeURL
        let useSidecars = compactLocalStore
        saveSequence &+= 1
        let sequence = saveSequence
        saveQueue.async { [weak self] in
            guard let data = Self.write(snapshot, to: url, useSidecars: useSidecars) else { return }
            DispatchQueue.main.async {
                self?.recordCompletedSave(data, sequence: sequence)
            }
        }
    }

    private func recordCompletedSave(_ data: Data, sequence: UInt64) {
        guard sequence > lastCompletedSaveSequence else { return }
        lastCompletedSaveSequence = sequence
        lastSavedData = data
        NotificationCenter.default.post(name: .pestyStoreDidSave, object: self)
    }

    private func snapshotForSave() -> Snapshot? {
        let previousLedger = deletionLedger
        let previousRestorations = pendingStackRestorations
        let legacyRestorations = deletionLedger.extractStackPlacements()
        if !legacyRestorations.isEmpty {
            pendingStackRestorations.merge(legacyRestorations) { existing, _ in existing }
            guard !legacyStacksNeedMigration,
                  savePasteStacks(PasteSequence.shared.savedStacks) else {
                deletionLedger = previousLedger
                pendingStackRestorations = previousRestorations
                return nil
            }
        }
        return Snapshot(history: history,
                        pinboards: pinboards,
                        pasteStacks: legacyStacksNeedMigration
                            ? PasteSequence.shared.savedStacks : nil,
                        deletionLedger: deletionLedger,
                        pendingPinboardDeletions: pendingPinboardDeletions)
    }

    nonisolated private static func decodeSnapshot(_ data: Data, from url: URL) throws -> Snapshot {
        let decoder = JSONDecoder()
        decoder.userInfo[ClipPayloadSidecars.codingKey] = ClipPayloadSidecars(
            directory: url.deletingLastPathComponent().appendingPathComponent("payloads", isDirectory: true)
        )
        return try decoder.decode(Snapshot.self, from: data)
    }

    nonisolated private static func write(
        _ snapshot: Snapshot, to url: URL, useSidecars: Bool
    ) -> Data? {
        let encoder = JSONEncoder()
        let sidecars = useSidecars ? ClipPayloadSidecars(
            directory: url.deletingLastPathComponent().appendingPathComponent("payloads", isDirectory: true)
        ) : nil
        if let sidecars { encoder.userInfo[ClipPayloadSidecars.codingKey] = sidecars }
        guard let data = try? encoder.encode(snapshot) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            sidecars?.pruneUnreferenced()
            return data
        } catch {
            return nil
        }
    }

    /// Recomputes observable Undo state from absolute timestamps, so sleep,
    /// relaunch, and clock changes do not extend the five-minute window.
    @discardableResult
    private func refreshDeletionState(at date: Date) -> Bool {
        let expiredStackIDs = deletionLedger.expiredPendingIDs(at: date)
        let expiredPayloads = deletionLedger.finalizeExpired(at: date)
        let previousStackRestorations = pendingStackRestorations
        let expiredStackItems = expiredStackIDs.flatMap { id in
            pendingStackRestorations.removeValue(forKey: id)?.map { $0.entry.item } ?? []
        }
        for payload in expiredPayloads {
            for item in payload.allItems {
                ExtensionResultStore.shared.forget(item.id)
                deleteImageFile(item)
            }
        }
        if !expiredStackItems.isEmpty {
            if savePasteStacks(PasteSequence.shared.savedStacks) {
                for item in expiredStackItems { deleteImageFile(item) }
            } else {
                pendingStackRestorations = previousStackRestorations
            }
        }
        let expiredBoards = pendingPinboardDeletions.filter { !$0.isUndoable(at: date) }
        if !expiredBoards.isEmpty {
            pendingPinboardDeletions.removeAll { !$0.isUndoable(at: date) }
            for pending in expiredBoards { finalizeRemovedPinboard(pending.board, at: date) }
        }

        hasUndoableDeletion = deletionLedger.hasUndoableDeletion(at: date)
            || newestUndoablePinboardDeletion(at: date) != nil
        scheduleNextUndoExpiration(after: date)
        return !expiredPayloads.isEmpty || !expiredBoards.isEmpty
    }

    private func scheduleNextUndoExpiration(after date: Date) {
        undoExpirationWorkItem?.cancel()
        undoExpirationWorkItem = nil
        let expirations = [deletionLedger.nextExpirationDate(after: date)].compactMap { $0 }
            + pendingPinboardDeletions.map(\.expiresAt).filter { $0 > date }
        guard let expiration = expirations.min() else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let changed = self.refreshDeletionState(at: .now)
            if changed { self.saveNow() }
        }
        undoExpirationWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, expiration.timeIntervalSince(date)),
            execute: work
        )
    }

    @discardableResult
    func saveNow() -> Bool {
        guard !storeLoadFailed else { return false }
        guard let snapshot = snapshotForSave() else { return false }
        let url = storeURL
        let useSidecars = compactLocalStore
        saveSequence &+= 1
        let sequence = saveSequence
        guard let data = saveQueue.sync(execute: {
            Self.write(snapshot, to: url, useSidecars: useSidecars)
        }) else {
            return false
        }
        recordCompletedSave(data, sequence: sequence)
        return true
    }

    @discardableResult
    func setICloudSync(_ enabled: Bool) -> Bool {
        guard !ClipboardStore.isDemo else { return true }
        guard !storeLoadFailed else { return false }
        let target = (enabled ? ClipboardStore.iCloudBase : ClipboardStore.localBase) ?? ClipboardStore.localBase
        let newImages = target.appendingPathComponent("images", isDirectory: true)
        let newStore = target.appendingPathComponent("store.json")
        let fm = FileManager.default
        let destinationExists = fm.fileExists(atPath: newStore.path)
        let destinationData = destinationExists ? try? Data(contentsOf: newStore) : nil
        let destinationSnapshot = destinationData.flatMap {
            try? Self.decodeSnapshot($0, from: newStore)
        }
        // Check before moving the active store or disabling its watcher.
        guard !destinationExists || destinationSnapshot != nil else { return false }
        let previousBase = baseDir
        let previousImages = imagesDir
        let previousStore = storeURL
        let previousCompactLocalStore = compactLocalStore
        stopWatching()
        try? fm.createDirectory(at: newImages, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])

        let saved: Bool
        if let data = destinationData, let snap = destinationSnapshot {
            copyImages(from: imagesDir, to: newImages)
            baseDir = target; imagesDir = newImages; storeURL = newStore
            compactLocalStore = target.standardizedFileURL == ClipboardStore.localBase.standardizedFileURL
            saved = mergeExternal(snap, rawData: data)
        } else {
            copyImages(from: imagesDir, to: newImages)
            baseDir = target; imagesDir = newImages; storeURL = newStore
            compactLocalStore = target.standardizedFileURL == ClipboardStore.localBase.standardizedFileURL
            saved = saveNow()
        }
        if !saved {
            baseDir = previousBase
            imagesDir = previousImages
            storeURL = previousStore
            compactLocalStore = previousCompactLocalStore
            if Settings.shared.iCloudSync { startWatching() }
            return false
        }
        prepareDirectories()
        if enabled { startWatching() }
        return saved
    }

    /// Pulls any iCloud Drive snapshot already delivered to this Mac into the
    /// in-memory library, then writes the merged result back so iCloud Drive
    /// has a fresh change to upload. Enabling and disabling sync remains a
    /// Settings action; the bar's cloud button only requests this refresh.
    func refreshICloudSync() {
        guard !ClipboardStore.isDemo,
              Settings.shared.iCloudSync else { return }
        saveWorkItem?.cancel()
        saveWorkItem = nil
        requestExternalMerge(forceUploadIfUnchanged: true)
    }

    private func copyImages(from src: URL, to dst: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "png"
            && !f.lastPathComponent.hasPrefix("stack-") {
            let target = dst.appendingPathComponent(f.lastPathComponent)
            if !fm.fileExists(atPath: target.path) { try? fm.copyItem(at: f, to: target) }
        }
    }

    /// Applies durable presence markers to every location after decoding a
    /// snapshot. This is deliberately independent of deletion-by-absence: an
    /// older payload may coexist with its tombstone after an iCloud conflict.
    @discardableResult
    private func applyDeletionTombstones() -> [ClipItem] {
        let deletedIDs = deletionLedger.deletedIDs
        let deletedStackItemIDs = deletionLedger.deletedPasteStackItemIDs
        let isDeleted: (ClipItem) -> Bool = {
            deletedIDs.contains($0.id)
        }
        let isDeletedFromStacks: (PasteStackEntry) -> Bool = {
            $0.originHistoryID.map(deletedStackItemIDs.contains) == true
        }
        var removed = history.filter(isDeleted)
        history.removeAll(where: isDeleted)

        for index in pinboards.indices {
            removed.append(contentsOf: pinboards[index].items.filter(isDeleted))
            pinboards[index].items.removeAll(where: isDeleted)
        }

        let previousStacks = PasteSequence.shared.savedStacks
        var removedStackEntries = false
        var removedStackItems: [ClipItem] = []
        let filteredStacks = PasteSequence.shared.savedStacks.map { stack in
            var filtered = stack
            let removedEntries = filtered.entries.filter(isDeletedFromStacks)
            removedStackItems.append(contentsOf: removedEntries.map { $0.item })
            filtered.entries.removeAll(where: isDeletedFromStacks)
            if !removedEntries.isEmpty {
                removedStackEntries = true
                filtered.updatedAt = .now
            }
            return filtered
        }
        PasteSequence.shared.restoreSavedStacks(
            filteredStacks.filter(\.hasEntries).sorted { $0.createdAt > $1.createdAt }
        )
        if !legacyStacksNeedMigration && removedStackEntries {
            if savePasteStacks(PasteSequence.shared.savedStacks) {
                removed += removedStackItems
            } else {
                PasteSequence.shared.restoreSavedStacks(previousStacks)
            }
        } else {
            removed += removedStackItems
        }
        return removed
    }

    @discardableResult
    private func mergeExternal(_ snap: Snapshot, rawData: Data) -> Bool {
        let deletionCandidates = history + snap.history
            + pinboards.flatMap(\.items) + snap.pinboards.flatMap(\.items)
            + PasteSequence.shared.savedStacks.flatMap { $0.entries.map(\.item) }
        deletionLedger.merge(snap.deletionLedger ?? ClipDeletionLedger())
        let displacedStackItems = pendingStackRestorations
            .filter { !deletionLedger.hasPendingDeletion(id: $0.key) }
            .values.flatMap { $0.map { $0.entry.item } }
        pendingStackRestorations = pendingStackRestorations.filter {
            deletionLedger.hasPendingDeletion(id: $0.key)
        }
        let deletedIDs = deletionLedger.deletedIDs
        let isDeleted: (ClipItem) -> Bool = {
            deletedIDs.contains($0.id)
        }

        history = Self.mergeHistory(history, snap.history)
            .filter { !isDeleted($0) && !cloudRetentionExcludedIDs.contains($0.id) }
        applyHistoryPolicyNow()

        // A pinboard deleted on another Mac disappears here too, and stays
        // undoable here for the rest of its window.
        for remotePending in snap.pendingPinboardDeletions ?? []
        where !pendingPinboardDeletions.contains(where: { $0.board.id == remotePending.board.id }) {
            if let index = pinboards.firstIndex(where: { $0.id == remotePending.board.id }) {
                guard pinboards[index].updatedAt <= remotePending.deletedAt else { continue }
                pinboards.remove(at: index)
                if case .pinboard(let cur) = source, cur == remotePending.board.id { source = .history }
            }
            pendingPinboardDeletions.append(remotePending)
        }

        var byID: [UUID: Pinboard] = Dictionary(uniqueKeysWithValues: pinboards.map { ($0.id, $0) })
        for b in snap.pinboards {
            if let pending = pendingPinboardDeletions.first(where: { $0.board.id == b.id }) {
                // Edited elsewhere after we deleted it (an undo there, say):
                // the newer board wins. Otherwise our deletion stands.
                guard b.updatedAt > pending.deletedAt else { continue }
                pendingPinboardDeletions.removeAll { $0.board.id == b.id }
            }
            if let existing = byID[b.id] {
                var merged = Self.mergePinboard(existing, b)
                merged.items.removeAll(where: isDeleted)
                merged.prunePins()
                byID[b.id] = merged
            } else {
                var filtered = b
                filtered.items.removeAll(where: isDeleted)
                byID[b.id] = filtered
            }
        }
        pinboards = byID.values.sorted {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.id.uuidString < $1.id.uuidString
        }
        for index in pinboards.indices {
            pinboards[index].items.removeAll(where: isDeleted)
        }

        // An old iCloud Drive snapshot may still carry Stack data. Import it
        // once only when this device has no local stacks, then write it back
        // without the legacy field. Never merge future remote Stack changes.
        if PasteSequence.shared.savedStacks.isEmpty,
           let remoteStacks = snap.pasteStacks, !remoteStacks.isEmpty {
            if let local = migrateLegacyStacks(remoteStacks), savePasteStacks(local) {
                PasteSequence.shared.restoreSavedStacks(local)
                legacyStacksNeedMigration = false
            } else {
                PasteSequence.shared.restoreSavedStacks(remoteStacks)
                lastPersistedStacks = remoteStacks
                legacyStacksNeedMigration = true
            }
        }
        let deletedStackItemIDs = deletionLedger.deletedPasteStackItemIDs
        let isDeletedFromStacks: (PasteStackEntry) -> Bool = {
            $0.originHistoryID.map(deletedStackItemIDs.contains) == true
        }
        let mergedStacks = PasteSequence.shared.savedStacks.map { stack in
            var filtered = stack
            filtered.entries.removeAll(where: isDeletedFromStacks)
            if filtered.entries.count != stack.entries.count { filtered.updatedAt = .now }
            return filtered
        }
        PasteSequence.shared.restoreSavedStacks(
            mergedStacks.filter(\.hasEntries).sorted { $0.createdAt > $1.createdAt }
        )
        if legacyStacksNeedMigration { lastPersistedStacks = PasteSequence.shared.savedStacks }
        let stacksPersisted = legacyStacksNeedMigration
            ? false : savePasteStacks(PasteSequence.shared.savedStacks)

        _ = refreshDeletionState(at: .now)
        for item in deletionCandidates where isDeleted(item) {
            deleteImageFile(item)
        }
        if stacksPersisted {
            for item in displacedStackItems { deleteImageFile(item) }
            pruneUnreferencedStackImages()
        }
        selectFirst()
        if matchesExternalSnapshot(snap) {
            // A delivered snapshot that changes nothing locally should not
            // trigger another whole-file iCloud Drive upload on each Mac.
            lastSavedData = rawData
            return true
        } else {
            return saveNow()
        }
    }

    private func matchesExternalSnapshot(_ snapshot: Snapshot) -> Bool {
        guard !legacyStacksNeedMigration,
              snapshot.pasteStacks == nil,
              history == snapshot.history,
              pinboards == snapshot.pinboards else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let sortRecords: ([ClipDeletionRecord]) -> [ClipDeletionRecord] = {
            $0.sorted { $0.id.uuidString < $1.id.uuidString }
        }
        let sortPending: ([PendingPinboardDeletion]) -> [PendingPinboardDeletion] = {
            $0.sorted { $0.id.uuidString < $1.id.uuidString }
        }
        guard let localLedger = try? encoder.encode(sortRecords(deletionLedger.records)),
              let remoteLedger = try? encoder.encode(sortRecords(snapshot.deletionLedger?.records ?? [])),
              let localPendingBoards = try? encoder.encode(sortPending(pendingPinboardDeletions)),
              let remotePendingBoards = try? encoder.encode(sortPending(snapshot.pendingPinboardDeletions ?? []))
        else { return false }
        return localLedger == remoteLedger && localPendingBoards == remotePendingBoards
    }

    /// The same clip can be present in both full-file snapshots. Its edit
    /// timestamp, rather than the file delivery order, decides which payload
    /// survives. Stable tie-breaking keeps simultaneous merges convergent.
    static func mergeHistory(_ local: [ClipItem], _ remote: [ClipItem]) -> [ClipItem] {
        var byID: [UUID: ClipItem] = [:]
        for item in local + remote {
            if let previous = byID[item.id] {
                byID[item.id] = newerClip(previous, item)
            } else {
                byID[item.id] = item
            }
        }
        return byID.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func newerClip(_ first: ClipItem, _ second: ClipItem) -> ClipItem {
        if first.updatedAt != second.updatedAt {
            return first.updatedAt > second.updatedAt ? first : second
        }
        if first == second { return first }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let firstData = (try? encoder.encode(first)) ?? Data()
        let secondData = (try? encoder.encode(second)) ?? Data()
        return firstData.lexicographicallyPrecedes(secondData) ? second : first
    }

    static func mergePinboard(_ local: Pinboard, _ remote: Pinboard) -> Pinboard {
        if local == remote { return local }
        let winner: Pinboard
        let loser: Pinboard
        if local.updatedAt != remote.updatedAt {
            (winner, loser) = local.updatedAt > remote.updatedAt
                ? (local, remote) : (remote, local)
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let localData = (try? encoder.encode(local)) ?? Data()
            let remoteData = (try? encoder.encode(remote)) ?? Data()
            (winner, loser) = localData.lexicographicallyPrecedes(remoteData)
                ? (remote, local) : (local, remote)
        }
        var merged = winner
        var byID = Dictionary(winner.items.map { ($0.id, $0) },
                              uniquingKeysWith: newerClip)
        for item in loser.items {
            if let existing = byID[item.id] {
                byID[item.id] = newerClip(existing, item)
            } else {
                byID[item.id] = item
            }
        }
        var orderedIDs = Set<UUID>()
        merged.items = (winner.items + loser.items).compactMap { item in
            orderedIDs.insert(item.id).inserted ? byID[item.id] : nil
        }
        merged.prunePins()
        return merged
    }

    private func startWatching() {
        stopWatching()
        let fd = open(storeURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            // Atomic saves replace the watched inode. Reattach even when this
            // event is one of our own writes that should not be merged.
            self.startWatching()
            self.requestExternalMerge(forceUploadIfUnchanged: false)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        fileWatch = src
    }

    private func stopWatching() {
        externalDecodeGeneration &+= 1
        fileWatch?.cancel()
        fileWatch = nil
    }

    /// The watched file can be tens of megabytes in an older inline Drive
    /// library. Read and decode it away from the card UI; apply only the latest
    /// result for the currently selected store root.
    private func requestExternalMerge(forceUploadIfUnchanged: Bool) {
        externalDecodeGeneration &+= 1
        let generation = externalDecodeGeneration
        let url = storeURL
        let knownData = lastSavedData
        externalDecodeQueue.async { [weak self] in
            guard let data = try? Data(contentsOf: url) else { return }
            // Most watcher events are our own atomic writes. Skip decoding a
            // full inline Drive library when its bytes are already known.
            let snapshot = data == knownData ? nil : try? Self.decodeSnapshot(data, from: url)
            DispatchQueue.main.async {
                guard let self,
                      self.externalDecodeGeneration == generation,
                      self.storeURL == url,
                      !self.storeLoadFailed else { return }
                if data == self.lastSavedData {
                    if forceUploadIfUnchanged { self.saveNow() }
                } else {
                    guard let snapshot else { return }
                    _ = self.mergeExternal(snapshot, rawData: data)
                }
            }
        }
    }
}
