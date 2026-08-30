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

    var errorDescription: String? {
        switch self {
        case .missingStore:
            return "The selected folder does not contain a Pesty-Alvie store.json file."
        case .unreadableStore:
            return "The selected Pesty-Alvie library could not be read."
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
    @ObservationIgnored private var contentVersion = 0
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
    private var saveWorkItem: DispatchWorkItem?
    private var undoExpirationWorkItem: DispatchWorkItem?
    private var deletionLedger = ClipDeletionLedger()
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
        imagesDir = base.appendingPathComponent("images", isDirectory: true)
        storeURL = base.appendingPathComponent("store.json")
        let hadStoreAtLaunch = FileManager.default.fileExists(atPath: storeURL.path)
        prepareDirectories()
        legacyLibraryMigrationResolved = FileManager.default.fileExists(
            atPath: legacyLibraryMigrationMarkerURL.path
        )
        cloudRetentionExcludedIDs = loadCloudRetentionExclusions()
        let tombstonesApplied = load()
        let historyChanged = applyHistoryPolicyNow()
        let deletionsChanged = refreshDeletionState(at: .now)
        let pixelsBackfilled = backfillImageFilePixels(at: .now)
        if tombstonesApplied || historyChanged || deletionsChanged || pixelsBackfilled { saveNow() }
        resolveBundledLegacyLibraryMigration(hadStoreAtLaunch: hadStoreAtLaunch)
        if Settings.shared.iCloudSync { startWatching() }
    }

    /// The on-disk store root (history JSON plus saved images), exposed so
    /// Settings can report how much space history actually uses.
    var dataDirectory: URL { baseDir }

    private func prepareDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseDir.path)
    }

    /// Search is memoized because `visibleItems` is a computed property that
    /// the bar evaluates several times per frame — the card strip, the empty
    /// state, the scroll targets, and the selection all ask for it — while
    /// matching a query against a multi-megabyte clip costs a full scan of it.
    /// Recomputing that per access is what made typing in the search field
    /// lock the bar up.
    @ObservationIgnored private var searchCache: (source: BarSource, query: String,
                                                  version: Int, items: [ClipItem])?

    private func searchResults(in base: [ClipItem], query: String) -> [ClipItem] {
        if let cache = searchCache,
           cache.version == contentVersion,
           cache.source == source,
           cache.query == query {
            return cache.items
        }
        let items = base.filter { $0.matches(query: query) }
        searchCache = (source, query, contentVersion, items)
        return items
    }

    var visibleItems: [ClipItem] {
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
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else {
            // Each saved Paste Stack is represented by one deck card on
            // Clipboard. Its member clips remain in history for persistence,
            // but should not also appear as individual Clipboard cards.
            guard case .history = source,
                  Settings.shared.pasteStacksEnabled,
                  PasteSequence.shared.hasSavedStacks else { return base }
            return base.filter { !PasteSequence.shared.containsHistoryItemID($0.id) }
        }
        return searchResults(in: base, query: q)
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

    func applyHistoryPolicy() { _ = applyHistoryPolicyNow(); scheduleSave() }

    /// A Copy from the Paste Bar is an intentional use of an existing clip.
    /// Promote it explicitly because the clipboard monitor correctly ignores
    /// Pesty's own pasteboard writes.
    @discardableResult
    func promoteCopiedItem(_ item: ClipItem, at date: Date = .now) -> ClipItem {
        var copied = item
        copied.createdAt = date
        copied.lastUsedAt = date
        copied.updatedAt = max(date, copied.updatedAt.addingTimeInterval(0.000_001))
        return addCaptured(copied)
    }

    func pasteStacksDidChange() {
        scheduleSave()
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
        for item in removed { deleteImageFile(item) }
        return true
    }

    /// `permanently` skips the Undo ledger entirely, so the deleted content
    /// never sits recoverable in store.json even for the five-minute window —
    /// either because the user turned that off globally in Settings, or held
    /// Option for this one deletion.
    func delete(_ item: ClipItem, at date: Date = .now, permanently: Bool = false) {
        let permanently = permanently || Settings.shared.deletePermanently
        let historyPlacements: [HistoryClipPlacement] = history.enumerated().compactMap { index, existing in
            guard existing.id == item.id else { return nil }
            return HistoryClipPlacement(
                index: index,
                item: existing,
                predecessorID: index > 0 ? history[index - 1].id : nil,
                successorID: index + 1 < history.count ? history[index + 1].id : nil
            )
        }
        let pinboardPlacements: [PinboardClipPlacement] = pinboards.flatMap { pinboard in
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
        let stackPlacements = Settings.shared.pasteStacksFollowHistory
            ? PasteSequence.shared.removeHistoryItems([item.id])
            : []
        let payload = ClipDeletionPayload(
            history: historyPlacements,
            pinboards: pinboardPlacements,
            pasteStackEntries: stackPlacements
        )
        guard !payload.allItems.isEmpty else { return }

        history.removeAll { $0.id == item.id }
        for i in pinboards.indices {
            pinboards[i].items.removeAll { $0.id == item.id }
            pinboards[i].prunePins()
        }
        if permanently {
            deletionLedger.recordRemoteDeletion(
                id: item.id,
                removesFromPasteStacks: Settings.shared.pasteStacksFollowHistory,
                at: date
            )
            for deletedItem in payload.allItems { deleteImageFile(deletedItem) }
        } else {
            deletionLedger.recordDeletion(
                id: item.id,
                payload: payload,
                removesFromPasteStacks: Settings.shared.pasteStacksFollowHistory,
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
        scheduleSave()
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
        guard let deletion = deletionLedger.undoMostRecent(at: date) else {
            if finalizedExpiredDeletion { saveNow() }
            return false
        }

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
        PasteSequence.shared.restoreHistoryItems(deletion.payload.pasteStackEntries)
        if PasteSequence.shared.item(withID: deletion.id) != nil { restoredSomewhere = true }

        // A clip that existed only in a pinboard still needs a destination if
        // that pinboard was deleted during the Undo window.
        if !restoredSomewhere, var fallback = deletion.payload.allItems.first {
            fallback.updatedAt = max(date, fallback.updatedAt.addingTimeInterval(0.000_001))
            history.insert(fallback, at: 0)
        }

        // Remove payload-only image copies for destinations that no longer
        // exist; restored references remain protected by reachability checks.
        for item in deletion.payload.allItems { deleteImageFile(item) }

        _ = refreshDeletionState(at: date)
        if visibleItems.contains(where: { $0.id == deletion.id }) {
            selectedID = deletion.id
        }
        scheduleSave()
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
        history.removeAll()
        selectedID = nil
        if Settings.shared.pasteStacksFollowHistory {
            PasteSequence.shared.removeHistoryItems(Set(old.map(\.id)))
        }
        for item in old {
            deletionLedger.recordRemoteDeletion(
                id: item.id,
                removesFromPasteStacks: Settings.shared.pasteStacksFollowHistory,
                at: .now
            )
        }
        for payload in finalizedPayloads {
            for item in payload.allItems { deleteImageFile(item) }
        }
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

    @discardableResult
    func addPinboard(name: String, colorHex: String = "#5B8DEF") -> Pinboard {
        let b = Pinboard(name: name, colorHex: colorHex, sortIndex: pinboards.count)
        pinboards.append(b)
        scheduleSave()
        return b
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
            deletionLedger.recordRemoteDeletion(
                id: item.id,
                removesFromPasteStacks: false,
                at: date
            )
        }
        for item in board.items { deleteImageFile(item) }
        for payload in finalizedPayloads {
            for item in payload.allItems { deleteImageFile(item) }
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
        var copy = item.copiedWithFreshID()
        if let dup = duplicateImageFile(item) { copy.imageFileName = dup }
        pinboards[i].items.insert(copy, at: 0)
        pinboards[i].touch()
        scheduleSave()
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

    func selectFirst() { selectedID = visibleItems.first?.id }

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
        guard let name = item.imageFileName else { return nil }
        return imagesDir.appendingPathComponent(name)
    }

    func loadImage(for item: ClipItem) -> NSImage? {
        guard let url = imageURL(for: item) else { return nil }
        return NSImage(contentsOf: url)
    }

    func storeImageData(_ data: Data) -> String? {
        let name = "\(UUID().uuidString).png"
        let url = imagesDir.appendingPathComponent(name)
        do {
            try data.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return name
        } catch { return nil }
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

        // Clips first: a Pinboard record in the same batch can then impose its
        // authoritative membership order in one pass.
        for decoded in clips {
            var item = decoded.item
            guard deletionLedger.permitsRemotePresence(id: item.id, updatedAt: item.updatedAt),
                  !Settings.shared.isIgnoringSourceApp(item.sourceBundleID) else { continue }
            if let source = decoded.imageAssetURL {
                item = copyRemoteImageAsset(for: item, from: source)
            }
            deletionLedger.acceptRemotePresence(id: item.id, at: item.updatedAt)

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
        var seen = Set(history.map(\.id))
        var changed = false

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
            || deletionLedger.retainsImageFile(named: name)
        if stillUsed { return }
        if let url = imageURL(for: item) { try? FileManager.default.removeItem(at: url) }
    }

    struct Snapshot: Codable {
        var history: [ClipItem]
        var pinboards: [Pinboard]
        var pasteStacks: [SavedPasteStack]?
        var deletionLedger: ClipDeletionLedger?
        var pendingPinboardDeletions: [PendingPinboardDeletion]?
    }

    private var legacyLibraryMigrationMarkerURL: URL {
        ClipboardStore.localBase.appendingPathComponent("legacy-library-migration-v1")
    }

    private var bundledLegacyLibraryURL: URL {
        ClipboardStore.localBase
            .deletingLastPathComponent()
            .appendingPathComponent("Pesty-Alvie Legacy Import", isDirectory: true)
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
                stacks[stackIndex].entries.removeAll { deletedIDs.contains($0.item.id) }
            }
            legacy.pasteStacks = stacks
        }

        let availableImages = copyLegacyImages(in: legacy, from: directory)
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
        saveNow()
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
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
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
        for name in Self.referencedImageNames(in: snapshot) where Self.isSafeImageFileName(name) {
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
        if var stacks = snapshot.pasteStacks {
            for stackIndex in stacks.indices {
                stacks[stackIndex].entries = stacks[stackIndex].entries.map { entry in
                    PasteStackEntry(
                        id: entry.id,
                        item: sanitized(entry.item),
                        imagePreview: nil,
                        isPasted: entry.isPasted
                    )
                }
            }
            snapshot.pasteStacks = stacks
        }
        return snapshot
    }

    @discardableResult
    private func load() -> Bool {
        guard let data = try? Data(contentsOf: storeURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return false }
        history = snap.history
        pinboards = snap.pinboards
        deletionLedger = snap.deletionLedger ?? ClipDeletionLedger()
        pendingPinboardDeletions = snap.pendingPinboardDeletions ?? []
        PasteSequence.shared.restoreSavedStacks(snap.pasteStacks ?? [])
        var removed = applyDeletionTombstones()
        let retentionExcluded = history.filter { cloudRetentionExcludedIDs.contains($0.id) }
        history.removeAll { cloudRetentionExcludedIDs.contains($0.id) }
        removed += retentionExcluded
        let migratedLegacyIDs = migrateLegacySharedClipIDs()
        let normalizedBoardOrder = normalizePinboardOrder(touchChanges: false)
        for item in removed { deleteImageFile(item) }
        selectFirst()
        return !removed.isEmpty || migratedLegacyIDs || normalizedBoardOrder
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Recomputes observable Undo state from absolute timestamps, so sleep,
    /// relaunch, and clock changes do not extend the five-minute window.
    @discardableResult
    private func refreshDeletionState(at date: Date) -> Bool {
        let expiredPayloads = deletionLedger.finalizeExpired(at: date)
        for payload in expiredPayloads {
            for item in payload.allItems { deleteImageFile(item) }
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

    func saveNow() {
        let snap = Snapshot(history: history,
                            pinboards: pinboards,
                            pasteStacks: PasteSequence.shared.savedStacks,
                            deletionLedger: deletionLedger,
                            pendingPinboardDeletions: pendingPinboardDeletions)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        do {
            try data.write(to: storeURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storeURL.path
            )
            lastSavedData = data
            NotificationCenter.default.post(name: .pestyStoreDidSave, object: self)
        } catch {
            return
        }
    }

    func setICloudSync(_ enabled: Bool) {
        stopWatching()
        let target = (enabled ? ClipboardStore.iCloudBase : ClipboardStore.localBase) ?? ClipboardStore.localBase
        let newImages = target.appendingPathComponent("images", isDirectory: true)
        let newStore = target.appendingPathComponent("store.json")
        let fm = FileManager.default
        try? fm.createDirectory(at: newImages, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])

        if fm.fileExists(atPath: newStore.path),
           let data = try? Data(contentsOf: newStore),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            copyImages(from: imagesDir, to: newImages)
            baseDir = target; imagesDir = newImages; storeURL = newStore
            mergeExternal(snap)
        } else {
            copyImages(from: imagesDir, to: newImages)
            baseDir = target; imagesDir = newImages; storeURL = newStore
            saveNow()
        }
        prepareDirectories()
        if enabled { startWatching() }
    }

    private func copyImages(from src: URL, to dst: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "png" {
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
        let isDeletedFromStacks: (ClipItem) -> Bool = {
            deletedStackItemIDs.contains($0.id)
        }
        var removed = history.filter(isDeleted)
        history.removeAll(where: isDeleted)

        for index in pinboards.indices {
            removed.append(contentsOf: pinboards[index].items.filter(isDeleted))
            pinboards[index].items.removeAll(where: isDeleted)
        }

        let filteredStacks = PasteSequence.shared.savedStacks.map { stack in
            var filtered = stack
            let removedEntries = filtered.entries.filter { isDeletedFromStacks($0.item) }
            removed.append(contentsOf: removedEntries.map { $0.item })
            filtered.entries.removeAll { isDeletedFromStacks($0.item) }
            if !removedEntries.isEmpty { filtered.updatedAt = .now }
            return filtered
        }
        PasteSequence.shared.restoreSavedStacks(
            filteredStacks.filter(\.hasEntries).sorted { $0.createdAt > $1.createdAt }
        )
        return removed
    }

    private func mergeExternal(_ snap: Snapshot) {
        let deletionCandidates = history + snap.history
            + pinboards.flatMap(\.items) + snap.pinboards.flatMap(\.items)
            + PasteSequence.shared.savedStacks.flatMap { $0.entries.map(\.item) }
            + (snap.pasteStacks ?? []).flatMap { $0.entries.map(\.item) }
        deletionLedger.merge(snap.deletionLedger ?? ClipDeletionLedger())
        let deletedIDs = deletionLedger.deletedIDs
        let isDeleted: (ClipItem) -> Bool = {
            deletedIDs.contains($0.id)
        }

        var combined = (history + snap.history)
            .filter { !isDeleted($0) && !cloudRetentionExcludedIDs.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
        var seen = Set<UUID>()
        var merged: [ClipItem] = []
        for it in combined where seen.insert(it.id).inserted { merged.append(it) }
        history = merged
        applyHistoryPolicyNow()

        // A pinboard deleted on another Mac disappears here too, and stays
        // undoable here for the rest of its window.
        for remotePending in snap.pendingPinboardDeletions ?? []
        where !pendingPinboardDeletions.contains(where: { $0.board.id == remotePending.board.id }) {
            if let index = pinboards.firstIndex(where: { $0.id == remotePending.board.id }) {
                guard pinboards[index].updatedAt < remotePending.deletedAt else { continue }
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
            if var existing = byID[b.id] {
                for it in b.items
                where !isDeleted(it)
                    && !existing.items.contains(where: { $0.id == it.id }) {
                    existing.items.append(it)
                }
                existing.items.removeAll(where: isDeleted)
                byID[b.id] = existing
            } else {
                var filtered = b
                filtered.items.removeAll(where: isDeleted)
                byID[b.id] = filtered
            }
        }
        pinboards = pinboards.map { byID[$0.id] ?? $0 }
            + byID.values.filter { b in !pinboards.contains(where: { $0.id == b.id }) }
        for index in pinboards.indices {
            pinboards[index].items.removeAll(where: isDeleted)
        }

        var stacksByID: [UUID: SavedPasteStack] = Dictionary(
            uniqueKeysWithValues: PasteSequence.shared.savedStacks.map { ($0.id, $0) }
        )
        for stack in snap.pasteStacks ?? [] {
            if let local = stacksByID[stack.id] {
                stacksByID[stack.id] = local.updatedAt >= stack.updatedAt ? local : stack
            } else {
                stacksByID[stack.id] = stack
            }
        }
        let deletedStackItemIDs = deletionLedger.deletedPasteStackItemIDs
        let isDeletedFromStacks: (ClipItem) -> Bool = { deletedStackItemIDs.contains($0.id) }
        let mergedStacks = stacksByID.values.map { stack in
            var filtered = stack
            filtered.entries.removeAll { isDeletedFromStacks($0.item) }
            if filtered.entries.count != stack.entries.count { filtered.updatedAt = .now }
            return filtered
        }
        PasteSequence.shared.restoreSavedStacks(
            mergedStacks.filter(\.hasEntries).sorted { $0.createdAt > $1.createdAt }
        )

        combined.removeAll()
        _ = refreshDeletionState(at: .now)
        for item in deletionCandidates where isDeleted(item) || isDeletedFromStacks(item) {
            deleteImageFile(item)
        }
        selectFirst()
        saveNow()
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
            defer { self.startWatching() }
            guard let data = try? Data(contentsOf: self.storeURL),
                  data != self.lastSavedData,
                  let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
            self.mergeExternal(snap)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        fileWatch = src
    }

    private func stopWatching() {
        fileWatch?.cancel()
        fileWatch = nil
    }
}
