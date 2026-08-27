import AppKit
import Observation

enum BarSource: Equatable {
    case history
    case pasteStack
    case pinboard(UUID)
}

enum BarInputMode: Equatable {
    case cards
    case search
}

@Observable
@MainActor
final class ClipboardStore {
    static let shared = ClipboardStore()

    private(set) var history: [ClipItem] = []
    private(set) var pinboards: [Pinboard] = []
    private(set) var hasUndoableDeletion = false

    var source: BarSource = .history
    var searchText: String = ""
    /// Search owns native text editing until the user submits it or chooses a
    /// result. Card shortcuts only run while this is `.cards`.
    var barInputMode: BarInputMode = .cards
    var selectedID: UUID?
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

    private var fileWatch: DispatchSourceFileSystemObject?
    private var lastSavedData: Data?

    static var localBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.storageDirectoryName, isDirectory: true)
    }

    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    static var iCloudBase: URL? {
        guard !isSandboxed else { return nil }
        let p = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: p.path) else { return nil }
        return p.appendingPathComponent(AppIdentity.storageDirectoryName, isDirectory: true)
    }

    var iCloudAvailable: Bool { ClipboardStore.iCloudBase != nil }

    private init() {
        let base = (Settings.shared.iCloudSync ? ClipboardStore.iCloudBase : nil) ?? ClipboardStore.localBase
        baseDir = base
        imagesDir = base.appendingPathComponent("images", isDirectory: true)
        storeURL = base.appendingPathComponent("store.json")
        prepareDirectories()
        let tombstonesApplied = load()
        let historyChanged = applyHistoryPolicyNow()
        let deletionsChanged = refreshDeletionState(at: .now)
        if tombstonesApplied || historyChanged || deletionsChanged { saveNow() }
        if Settings.shared.iCloudSync { startWatching() }
    }

    private func prepareDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseDir.path)
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
        return base.filter { $0.searchableText.contains(q) }
    }

    var selectedItem: ClipItem? {
        guard let id = selectedID else { return nil }
        return visibleItems.first(where: { $0.id == id })
    }

    @discardableResult
    func addCaptured(_ item: ClipItem) -> ClipItem {
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
            for deletedItem in payload.allItems { deleteImageFile(deletedItem) }
        } else {
            deletionLedger.recordDeletion(
                id: item.id,
                payload: payload,
                removesFromPasteStacks: Settings.shared.pasteStacksFollowHistory,
                at: date
            )
        }
        if selectedID == item.id { selectFirst() }
        _ = refreshDeletionState(at: date)
        scheduleSave()
    }

    /// Restores the newest deletion whose five-minute window is still open.
    /// A newer active marker remains in the ledger so an older synced tombstone
    /// cannot immediately remove the clip again.
    @discardableResult
    func undoLastDelete(at date: Date = .now) -> Bool {
        let finalizedExpiredDeletion = refreshDeletionState(at: date)
        guard let deletion = deletionLedger.undoMostRecent(at: date) else {
            if finalizedExpiredDeletion { saveNow() }
            return false
        }

        var restoredSomewhere = history.contains(where: { $0.id == deletion.id })
            || pinboards.contains { $0.items.contains(where: { $0.id == deletion.id }) }
        for placement in deletion.payload.history.sorted(by: { $0.index < $1.index }) {
            guard !history.contains(where: { $0.id == placement.item.id }) else { continue }
            let index = restorationIndex(
                originalIndex: placement.index,
                predecessorID: placement.predecessorID,
                successorID: placement.successorID,
                in: history
            )
            history.insert(placement.item, at: index)
            restoredSomewhere = true
        }
        for placement in deletion.payload.pinboards {
            guard let boardIndex = pinboards.firstIndex(where: { $0.id == placement.pinboardID }),
                  !pinboards[boardIndex].items.contains(where: { $0.id == placement.item.id }) else {
                continue
            }
            let index = restorationIndex(
                originalIndex: placement.index,
                predecessorID: placement.predecessorID,
                successorID: placement.successorID,
                in: pinboards[boardIndex].items
            )
            pinboards[boardIndex].items.insert(placement.item, at: index)
            restoredSomewhere = true
        }
        PasteSequence.shared.restoreHistoryItems(deletion.payload.pasteStackEntries)
        if PasteSequence.shared.item(withID: deletion.id) != nil { restoredSomewhere = true }

        // A clip that existed only in a pinboard still needs a destination if
        // that pinboard was deleted during the Undo window.
        if !restoredSomewhere, let fallback = deletion.payload.allItems.first {
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
        history.removeAll()
        selectedID = nil
        if Settings.shared.pasteStacksFollowHistory {
            PasteSequence.shared.removeHistoryItems(Set(old.map(\.id)))
        }
        for item in old { deleteImageFile(item) }
        scheduleSave()
    }

    @discardableResult
    func addPinboard(name: String, colorHex: String = "#5B8DEF") -> Pinboard {
        let b = Pinboard(name: name, colorHex: colorHex)
        pinboards.append(b)
        scheduleSave()
        return b
    }

    func renamePinboard(_ id: UUID, to name: String) {
        guard let i = pinboards.firstIndex(where: { $0.id == id }) else { return }
        pinboards[i].name = name
        scheduleSave()
    }

    func setPinboardColor(_ id: UUID, to colorHex: String) {
        guard let i = pinboards.firstIndex(where: { $0.id == id }) else { return }
        pinboards[i].colorHex = colorHex
        scheduleSave()
    }

    func deletePinboard(_ id: UUID) {
        guard let i = pinboards.firstIndex(where: { $0.id == id }) else { return }
        if case .pinboard(let cur) = source, cur == id { source = .history }
        let removedItems = pinboards[i].items
        pinboards.remove(at: i)
        for item in removedItems { deleteImageFile(item) }
        scheduleSave()
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
            return
        }
        pinboards.insert(moved, at: targetIndex)
        scheduleSave()
    }

    func movePinboard(_ id: UUID, by offset: Int) {
        guard let from = pinboards.firstIndex(where: { $0.id == id }) else { return }
        let to = min(pinboards.count - 1, max(0, from + offset))
        guard from != to else { return }
        pinboards.swapAt(from, to)
        scheduleSave()
    }

    func movePinboardToEnd(_ id: UUID) {
        guard let from = pinboards.firstIndex(where: { $0.id == id }),
              from != pinboards.count - 1 else { return }
        let moved = pinboards.remove(at: from)
        pinboards.append(moved)
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
        var copy = item
        if let dup = duplicateImageFile(item) { copy.imageFileName = dup }
        pinboards[i].items.insert(copy, at: 0)
        scheduleSave()
    }

    func setTitle(_ title: String, for item: ClipItem) {
        var changed = false
        if let i = history.firstIndex(where: { $0.id == item.id }),
           history[i].customTitle != title {
            history[i].customTitle = title
            changed = true
        }
        for b in pinboards.indices {
            if let i = pinboards[b].items.firstIndex(where: { $0.id == item.id }),
               pinboards[b].items[i].customTitle != title {
                pinboards[b].items[i].customTitle = title
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
            let updated = transform(history[i])
            if updated != history[i] {
                history[i] = updated
                changed = true
            }
        }

        for boardIndex in pinboards.indices {
            for itemIndex in pinboards[boardIndex].items.indices
            where pinboards[boardIndex].items[itemIndex].id == item.id {
                let updated = transform(pinboards[boardIndex].items[itemIndex])
                if updated != pinboards[boardIndex].items[itemIndex] {
                    pinboards[boardIndex].items[itemIndex] = updated
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

    func moveSelection(by delta: Int) {
        let items = visibleItems
        guard !items.isEmpty else { return }
        guard let id = selectedID, let idx = items.firstIndex(where: { $0.id == id }) else {
            selectedID = items.first?.id; return
        }
        let next = max(0, min(items.count - 1, idx + delta))
        selectedID = items[next].id
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

    private func deleteImageFile(_ item: ClipItem) {
        guard let name = item.imageFileName else { return }
        let stillUsed = history.contains { $0.imageFileName == name }
            || pinboards.contains { $0.items.contains { $0.imageFileName == name } }
            || PasteSequence.shared.savedStacks.contains { stack in
                stack.entries.contains { $0.item.imageFileName == name }
            }
            || deletionLedger.retainsImageFile(named: name)
        if stillUsed { return }
        if let url = imageURL(for: item) { try? FileManager.default.removeItem(at: url) }
    }

    private struct Snapshot: Codable {
        var history: [ClipItem]
        var pinboards: [Pinboard]
        var pasteStacks: [SavedPasteStack]?
        var deletionLedger: ClipDeletionLedger?
    }

    @discardableResult
    private func load() -> Bool {
        guard let data = try? Data(contentsOf: storeURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return false }
        history = snap.history
        pinboards = snap.pinboards
        deletionLedger = snap.deletionLedger ?? ClipDeletionLedger()
        PasteSequence.shared.restoreSavedStacks(snap.pasteStacks ?? [])
        let removed = applyDeletionTombstones()
        for item in removed { deleteImageFile(item) }
        selectFirst()
        return !removed.isEmpty
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

        hasUndoableDeletion = deletionLedger.hasUndoableDeletion(at: date)
        scheduleNextUndoExpiration(after: date)
        return !expiredPayloads.isEmpty
    }

    private func scheduleNextUndoExpiration(after date: Date) {
        undoExpirationWorkItem?.cancel()
        undoExpirationWorkItem = nil
        guard let expiration = deletionLedger.nextExpirationDate(after: date) else { return }

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
                            deletionLedger: deletionLedger)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        lastSavedData = data
        try? data.write(to: storeURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
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
            .filter { !isDeleted($0) }
            .sorted { $0.createdAt > $1.createdAt }
        var seen = Set<UUID>()
        var merged: [ClipItem] = []
        for it in combined where seen.insert(it.id).inserted { merged.append(it) }
        history = merged
        applyHistoryPolicyNow()

        var byID: [UUID: Pinboard] = Dictionary(uniqueKeysWithValues: pinboards.map { ($0.id, $0) })
        for b in snap.pinboards {
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
