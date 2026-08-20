import AppKit
import Observation

extension Notification.Name {
    static let pestyStoreDidSave = Notification.Name("PestyStoreDidSave")
}

enum BarSource: Equatable {
    case history
    case pinboard(UUID)
}

@Observable
@MainActor
final class ClipboardStore {
    static let shared = ClipboardStore()

    private(set) var history: [ClipItem] = []
    private(set) var pinboards: [Pinboard] = []
    private var deletionLedger = ClipDeletionLedger()
    private(set) var hasUndoableDeletion = false
    private var undoExpirationWorkItem: DispatchWorkItem?

    var source: BarSource = .history {
        didSet { if source != oldValue { clearMultiSelection() } }
    }
    var searchText: String = "" {
        didSet { if searchText != oldValue { clearMultiSelection() } }
    }
    var selectedID: UUID?
    var inlinePreviewVisible = false
    private(set) var multiSelectedIDs: Set<UUID> = []
    private var selectionAnchorID: UUID?

    /// Bumped every time the bar is about to present. The hosting view is
    /// built once and cached, so the strip keeps its scroll offset across
    /// hide/show; selection alone cannot reset it because the newest clip is
    /// usually already selected and `onChange` never fires for equal values.
    private(set) var barPresentationToken = 0

    var historyLimit: Int {
        get { Settings.shared.historyLimit }
        set { Settings.shared.historyLimit = newValue; trimHistory() }
    }

    private var storeURL: URL
    private var imagesDir: URL
    private var baseDir: URL
    private var saveWorkItem: DispatchWorkItem?

    private var fileWatch: DispatchSourceFileSystemObject?
    private var ignoreWatchUntil: Date = .distantPast

    static var localBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pesty", isDirectory: true)
    }

    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    static var iCloudBase: URL? {
        guard !isSandboxed else { return nil }
        let p = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: p.path) else { return nil }
        return p.appendingPathComponent("Pesty", isDirectory: true)
    }

    var iCloudAvailable: Bool { ClipboardStore.iCloudBase != nil }

    /// The on-disk store root (history JSON plus saved images), exposed so
    /// Settings can report how much space history actually uses.
    var dataDirectory: URL { baseDir }

    private init() {
        let base = (Settings.shared.iCloudSync ? ClipboardStore.iCloudBase : nil) ?? ClipboardStore.localBase
        baseDir = base
        imagesDir = base.appendingPathComponent("images", isDirectory: true)
        storeURL = base.appendingPathComponent("store.json")
        prepareDirectories()
        load()
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
        case .pinboard(let id):
            base = pinboards.first(where: { $0.id == id })?.items ?? []
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { $0.searchableText.contains(q) }
    }

    var selectedItem: ClipItem? {
        guard let id = selectedID else { return nil }
        return visibleItems.first(where: { $0.id == id })
    }

    func addCaptured(_ item: ClipItem) {
        if let idx = history.firstIndex(where: { $0.sameContent(as: item) }) {
            if item.imageFileName != history[idx].imageFileName { deleteImageFile(item) }
            var existing = history.remove(at: idx)
            existing.createdAt = item.createdAt
            history.insert(existing, at: 0)
            if source == .history && searchText.isEmpty && multiSelectedIDs.isEmpty {
                selectedID = existing.id
                selectionAnchorID = existing.id
            }
            scheduleSave()
            return
        }
        history.insert(item, at: 0)
        trimHistory()
        if source == .history && searchText.isEmpty && multiSelectedIDs.isEmpty {
            selectedID = item.id
            selectionAnchorID = item.id
        }
        scheduleSave()
    }

    func promoteCopiedItem(_ item: ClipItem, at date: Date = .now) {
        var copied = item
        copied.createdAt = date
        addCaptured(copied)
    }

    func applyRetentionPolicy() { trimHistory(); scheduleSave() }

    func retentionRemovalCount(mode: HistoryRetentionMode, limit: Int, days: Int) -> Int {
        switch mode {
        case .itemCount:
            return max(0, history.count - max(20, limit))
        case .timeInterval:
            // days == 0 means "forever" - no age-based cutoff, just the safety cap.
            guard days > 0 else {
                return max(0, history.count - Self.timeRetentionSafetyCap)
            }
            let cutoff = Self.retentionCutoff(daysAgo: days)
            let byAge = history.filter { $0.createdAt < cutoff }.count
            return byAge + max(0, (history.count - byAge) - Self.timeRetentionSafetyCap)
        }
    }

    private static let timeRetentionSafetyCap = 5000

    private static func retentionCutoff(daysAgo days: Int) -> Date {
        Date().addingTimeInterval(-TimeInterval(max(1, days)) * 86_400)
    }

    private(set) var retentionPrunedRecordNames: Set<String> = []

    func isRetentionPruned(_ recordName: String) -> Bool {
        retentionPrunedRecordNames.contains(recordName)
    }

    private func trimHistory() {
        var removed: [ClipItem] = []
        switch Settings.shared.historyRetentionMode {
        case .itemCount:
            if history.count > historyLimit {
                removed = Array(history[historyLimit...])
                history.removeLast(history.count - historyLimit)
            }
        case .timeInterval:
            // days == 0 means "forever" - skip the age cutoff, keep the safety cap.
            let days = Settings.shared.historyRetentionDays
            if days > 0 {
                let cutoff = Self.retentionCutoff(daysAgo: days)
                let old = history.filter { $0.createdAt < cutoff }
                if !old.isEmpty {
                    removed += old
                    history.removeAll { $0.createdAt < cutoff }
                }
            }
            if history.count > Self.timeRetentionSafetyCap {
                removed += Array(history[Self.timeRetentionSafetyCap...])
                history.removeLast(history.count - Self.timeRetentionSafetyCap)
            }
        }
        guard !removed.isEmpty else { return }
        for item in removed { deleteImageFile(item) }
        markRetentionPruned(removed)
        if let sel = selectedID, removed.contains(where: { $0.id == sel }) { selectFirst() }
        reconcileMultiSelection()
    }

    private func markRetentionPruned(_ items: [ClipItem]) {
        let names = items.map { $0.id.uuidString }
        retentionPrunedRecordNames.formUnion(names)
        #if MAS
        CloudSyncService.shared.retainRemoteRecords(named: names)
        #endif
    }

    /// Deletes a clip from the collection currently on screen only. A Pinboard
    /// is an independently saved collection: deleting a card from history must
    /// not erase saved copies, and deleting a pinboard copy must not touch
    /// history or other pinboards, even for legacy clips that share an id.
    /// Deleting exactly what was removed also closes an image-file leak: the
    /// old cross-container removal deleted entries under two file names but
    /// cleaned up only one of them.
    func delete(_ item: ClipItem, at date: Date = .now, permanently: Bool = false) {
        delete(items: [item], at: date, permanently: permanently)
    }

    /// `permanently` skips the Undo ledger entirely, so the deleted content
    /// never sits recoverable in `store.json` even for the five-minute
    /// window — either because the user turned that off globally in
    /// Settings, or held Option for this one deletion.
    func delete(items: [ClipItem], at date: Date = .now, permanently: Bool = false) {
        let ids = Set(items.map(\.id))
        guard !ids.isEmpty else { return }
        let permanently = permanently || Settings.shared.deletePermanently
        // Captured before removal so repeated deletes walk down the list
        // instead of snapping back to the newest clip every time.
        let deletedIndex = visibleItems.firstIndex(where: { ids.contains($0.id) })
        let selectionDeleted = selectedID.map { ids.contains($0) } ?? false
        let removed: [ClipItem]
        switch source {
        case .history:
            let placements: [HistoryClipPlacement] = history.enumerated().compactMap { index, existing in
                guard ids.contains(existing.id) else { return nil }
                return HistoryClipPlacement(
                    index: index,
                    item: existing,
                    predecessorID: index > 0 ? history[index - 1].id : nil,
                    successorID: index + 1 < history.count ? history[index + 1].id : nil
                )
            }
            removed = placements.map(\.item)
            history.removeAll { ids.contains($0.id) }
            if !permanently {
                for placement in placements {
                    deletionLedger.recordDeletion(
                        id: placement.item.id,
                        payload: ClipDeletionPayload(history: [placement], pinboards: []),
                        at: date
                    )
                }
            }
        case .pinboard(let boardID):
            guard let boardIndex = pinboards.firstIndex(where: { $0.id == boardID }) else { return }
            let items = pinboards[boardIndex].items
            let placements: [PinboardClipPlacement] = items.enumerated().compactMap { index, existing in
                guard ids.contains(existing.id) else { return nil }
                return PinboardClipPlacement(
                    pinboardID: boardID,
                    index: index,
                    item: existing,
                    predecessorID: index > 0 ? items[index - 1].id : nil,
                    successorID: index + 1 < items.count ? items[index + 1].id : nil
                )
            }
            removed = placements.map(\.item)
            pinboards[boardIndex].items.removeAll { ids.contains($0.id) }
            if !permanently {
                for placement in placements {
                    deletionLedger.recordDeletion(
                        id: placement.item.id,
                        payload: ClipDeletionPayload(history: [], pinboards: [placement]),
                        at: date
                    )
                }
            }
        }
        for entry in removed { deleteImageFile(entry) }
        multiSelectedIDs.subtract(ids)
        if multiSelectedIDs.count <= 1 { multiSelectedIDs = [] }
        if selectionDeleted {
            let remaining = visibleItems
            if let index = deletedIndex, !remaining.isEmpty {
                selectedID = remaining[min(index, remaining.count - 1)].id
            } else {
                selectFirst()
            }
            selectionAnchorID = selectedID
        }
        reconcileMultiSelection()
        _ = refreshDeletionState(at: date)
        scheduleSave()
    }

    /// Restores the newest deletion whose five-minute window is still open.
    /// A newer active marker remains in the ledger so an older synced snapshot
    /// cannot immediately remove the clip again. Older independent deletions
    /// stay available, so repeated Undo presses walk backward in order.
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

        // A clip that existed only in a Pinboard still needs a destination if
        // that Pinboard was deleted during the Undo window.
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

    func clearHistory() {
        let old = history
        history.removeAll()
        selectedID = nil
        for item in old { deleteImageFile(item) }
        reconcileMultiSelection()
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

    func deletePinboard(_ id: UUID) {
        guard let i = pinboards.firstIndex(where: { $0.id == id }) else { return }
        if case .pinboard(let cur) = source, cur == id { source = .history }
        let removedItems = pinboards[i].items
        pinboards.remove(at: i)
        for item in removedItems { deleteImageFile(item) }
        reconcileMultiSelection()
        scheduleSave()
    }

    func saveToPinboard(_ item: ClipItem, boardID: UUID) {
        guard let i = pinboards.firstIndex(where: { $0.id == boardID }) else { return }
        if pinboards[i].items.contains(where: { $0.sameContent(as: item) }) { return }
        // Pinboard copies mint their own UUID (one sync record per container).
        var copy = ClipItem(
            type: item.type,
            text: item.text,
            rtfData: item.rtfData,
            imageFileName: item.imageFileName,
            imageHash: item.imageHash,
            fileURLs: item.fileURLs,
            colorHex: item.colorHex,
            sourceBundleID: item.sourceBundleID,
            sourceAppName: item.sourceAppName,
            customTitle: item.customTitle,
            createdAt: item.createdAt)
        if let dup = duplicateImageFile(item) { copy.imageFileName = dup }
        pinboards[i].items.insert(copy, at: 0)
        scheduleSave()
    }

    func item(withID id: UUID) -> ClipItem? {
        if let item = history.first(where: { $0.id == id }) { return item }
        return pinboards.lazy.flatMap(\.items).first(where: { $0.id == id })
    }

    @discardableResult
    func updateTextContent(_ text: String, richTextData: Data? = nil, for item: ClipItem) -> Bool {
        guard [.text, .richText, .link].contains(item.type),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let type: ClipType = richTextData != nil ? .richText : (isWebLink(text) ? .link : .text)
        return updateContent(of: item) { existing in
            var updated = existing
            updated.type = type
            updated.text = text
            updated.rtfData = richTextData
            updated.colorHex = nil
            return updated
        }
    }

    @discardableResult
    func updateColorContent(_ hex: String, for item: ClipItem) -> Bool {
        guard item.type == .color, let color = NSColor(hex: hex) else { return false }
        let normalized = color.hexString
        return updateContent(of: item) { existing in
            var updated = existing
            updated.type = .color
            updated.text = nil
            updated.rtfData = nil
            updated.colorHex = normalized
            return updated
        }
    }

    private func updateContent(of item: ClipItem, transform: (ClipItem) -> ClipItem) -> Bool {
        var changed = false
        let now = Date()

        if let i = history.firstIndex(where: { $0.id == item.id }) {
            var updated = transform(history[i])
            if updated != history[i] {
                updated.createdAt = now
                history.remove(at: i)
                removeContentDuplicates(of: updated, in: &history)
                history.insert(updated, at: 0)
                changed = true
            }
        }

        for b in pinboards.indices {
            guard let i = pinboards[b].items.firstIndex(where: { $0.id == item.id }) else { continue }
            var updated = transform(pinboards[b].items[i])
            if updated != pinboards[b].items[i] {
                updated.createdAt = now
                pinboards[b].items[i] = updated
                removeContentDuplicates(of: updated, in: &pinboards[b].items)
                changed = true
            }
        }

        guard changed else { return false }
        retentionPrunedRecordNames.remove(item.id.uuidString)
        if selectedItem == nil { selectFirst() }
        reconcileMultiSelection()
        scheduleSave()
        return true
    }

    private func removeContentDuplicates(of item: ClipItem, in items: inout [ClipItem]) {
        let key = contentKey(item)
        let duplicates = items.filter { $0.id != item.id && contentKey($0) == key }
        guard !duplicates.isEmpty else { return }
        items.removeAll { $0.id != item.id && contentKey($0) == key }
        for duplicate in duplicates { deleteImageFile(duplicate) }
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

    func setTitle(_ title: String, for item: ClipItem) {
        if let i = history.firstIndex(where: { $0.id == item.id }) { history[i].customTitle = title }
        for b in pinboards.indices {
            if let i = pinboards[b].items.firstIndex(where: { $0.id == item.id }) {
                pinboards[b].items[i].customTitle = title
            }
        }
        scheduleSave()
    }

    func selectFirst() { selectedID = visibleItems.first?.id }

    var effectiveSelectionIDs: Set<UUID> {
        if !multiSelectedIDs.isEmpty { return multiSelectedIDs }
        return selectedID.map { [$0] } ?? []
    }

    func isSelected(_ id: UUID) -> Bool {
        if multiSelectedIDs.isEmpty { return selectedID == id }
        return multiSelectedIDs.contains(id)
    }

    func select(_ id: UUID) {
        selectedID = id
        selectionAnchorID = id
        multiSelectedIDs = []
    }

    func toggleSelection(_ id: UUID) {
        guard visibleItems.contains(where: { $0.id == id }) else { return }
        if multiSelectedIDs.isEmpty, let sel = selectedID, sel != id,
           visibleItems.contains(where: { $0.id == sel }) {
            multiSelectedIDs = [sel]
        }
        if multiSelectedIDs.contains(id) {
            multiSelectedIDs.remove(id)
            if selectedID == id { selectedID = multiSelectedIDs.first ?? visibleItems.first?.id }
            if selectionAnchorID == id { selectionAnchorID = selectedID }
            if multiSelectedIDs.count <= 1 { multiSelectedIDs = [] }
        } else {
            multiSelectedIDs.insert(id)
            selectedID = id
            if selectionAnchorID == nil { selectionAnchorID = id }
            if multiSelectedIDs.count == 1 { multiSelectedIDs = [] }
        }
    }

    func extendSelection(to id: UUID) {
        let items = visibleItems
        guard let targetIndex = items.firstIndex(where: { $0.id == id }) else { return }
        guard let anchor = selectionAnchorID ?? selectedID,
              let anchorIndex = items.firstIndex(where: { $0.id == anchor }) else {
            select(id)
            return
        }
        let range = items[min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)]
        multiSelectedIDs = Set(range.map(\.id))
        selectedID = id
        selectionAnchorID = anchor
        if multiSelectedIDs.count <= 1 { multiSelectedIDs = [] }
    }

    func clearMultiSelection() {
        multiSelectedIDs = []
        selectionAnchorID = selectedID
    }

    private func reconcileMultiSelection() {
        guard !multiSelectedIDs.isEmpty else { return }
        let visible = Set(visibleItems.map(\.id))
        multiSelectedIDs.formIntersection(visible)
        if multiSelectedIDs.count <= 1 { multiSelectedIDs = [] }
        if let anchor = selectionAnchorID, !visible.contains(anchor) {
            selectionAnchorID = selectedID
        }
        if let sel = selectedID, !visible.contains(sel) {
            selectedID = multiSelectedIDs.first ?? visibleItems.first?.id
        }
    }

    func prepareForBarPresentation() {
        applyRetentionPolicy()
        clearMultiSelection()
        barPresentationToken &+= 1
        selectFirst()
    }

    func moveSelection(by delta: Int) {
        clearMultiSelection()
        let items = visibleItems
        guard !items.isEmpty else { return }
        guard let id = selectedID, let idx = items.firstIndex(where: { $0.id == id }) else {
            selectedID = items.first?.id; return
        }
        let next = max(0, min(items.count - 1, idx + delta))
        selectedID = items[next].id
        selectionAnchorID = selectedID
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
            try data.write(to: url, options: .atomic)
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
            || deletionLedger.retainsImageFile(named: name)
        if stillUsed { return }
        if let url = imageURL(for: item) { try? FileManager.default.removeItem(at: url) }
    }

    private struct Snapshot: Codable {
        var history: [ClipItem]
        var pinboards: [Pinboard]
        var deletionLedger: ClipDeletionLedger?
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        history = snap.history
        pinboards = snap.pinboards
        deletionLedger = snap.deletionLedger ?? ClipDeletionLedger()
        applyDeletionTombstones()
        _ = refreshDeletionState(at: .now)
        selectFirst()
    }

    /// Applies durable presence markers to every location after decoding a
    /// snapshot. This is deliberately independent of deletion-by-absence: an
    /// older payload may coexist with its tombstone after a merge conflict.
    private func applyDeletionTombstones() {
        let deletedIDs = deletionLedger.deletedIDs
        guard !deletedIDs.isEmpty else { return }
        let isDeleted: (ClipItem) -> Bool = { deletedIDs.contains($0.id) }
        let removed = history.filter(isDeleted)
            + pinboards.flatMap { $0.items.filter(isDeleted) }
        history.removeAll(where: isDeleted)
        for index in pinboards.indices {
            pinboards[index].items.removeAll(where: isDeleted)
        }
        for item in removed { deleteImageFile(item) }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        let snap = Snapshot(history: history, pinboards: pinboards, deletionLedger: deletionLedger)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        ignoreWatchUntil = Date().addingTimeInterval(1.5)
        try? data.write(to: storeURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
        NotificationCenter.default.post(name: .pestyStoreDidSave, object: nil)
    }

    // MARK: - Remote (CloudKit) apply

    /// Applies decoded CloudKit clips. Dedupe by contentKey keeps the newer
    /// createdAt; insertion stays newest-first. Callers update their own
    /// last-synced bookkeeping so these changes do not loop back into sync.
    func applyRemote(clips: [(ClipItem, container: String, imageSourceURL: URL?)]) {
        guard !clips.isEmpty else { return }
        for entry in clips {
            let item = entry.0
            // The per-app exclusion list is local to each Mac and is not synced, so a
            // clip from an ignored app copied on another device would otherwise arrive
            // here and land in history anyway. A privacy filter that leaks across
            // devices is not a privacy filter.
            guard !Settings.shared.isIgnoringSourceApp(item.sourceBundleID) else { continue }
            if let src = entry.imageSourceURL, let name = item.imageFileName {
                let dst = imagesDir.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: src, to: dst)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
            }
            if entry.container == "history" {
                applyRemoteToHistory(item)
            } else if let boardID = UUID(uuidString: entry.container) {
                applyRemoteToPinboard(item, boardID: boardID)
            }
        }
        trimHistory()
        if selectedID == nil { selectFirst() }
        reconcileMultiSelection()
        scheduleSave()
    }

    func applyRemoteDeletes(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        let removedHistory = history.filter { set.contains($0.id) }
        history.removeAll { set.contains($0.id) }
        var removedPinned: [ClipItem] = []
        for i in pinboards.indices {
            removedPinned += pinboards[i].items.filter { set.contains($0.id) }
            pinboards[i].items.removeAll { set.contains($0.id) }
        }
        let removedBoards = pinboards.filter { set.contains($0.id) }
        pinboards.removeAll { set.contains($0.id) }
        if case .pinboard(let cur) = source, set.contains(cur) { source = .history }
        for item in removedHistory + removedPinned + removedBoards.flatMap(\.items) {
            deleteImageFile(item)
        }
        if let sel = selectedID, set.contains(sel) { selectFirst() }
        reconcileMultiSelection()
        scheduleSave()
    }

    /// Upserts pinboard name/color only; item membership syncs through clip records.
    func applyRemote(pinboards boards: [Pinboard]) {
        guard !boards.isEmpty else { return }
        for b in boards {
            if let i = pinboards.firstIndex(where: { $0.id == b.id }) {
                pinboards[i].name = b.name
                pinboards[i].colorHex = b.colorHex
            } else {
                pinboards.append(Pinboard(id: b.id, name: b.name, colorHex: b.colorHex, items: []))
            }
        }
        scheduleSave()
    }

    private func applyRemoteToHistory(_ item: ClipItem) {
        let replaced = history.filter { $0.id == item.id }
        history.removeAll { $0.id == item.id }
        let key = contentKey(item)
        if let dupIdx = history.firstIndex(where: { contentKey($0) == key }) {
            let dup = history[dupIdx]
            if dup.createdAt >= item.createdAt {
                deleteImageFile(item)
                for old in replaced { deleteImageFile(old) }
                return
            }
            history.remove(at: dupIdx)
            deleteImageFile(dup)
        }
        insertSortedByDate(item, into: &history)
        retentionPrunedRecordNames.remove(item.id.uuidString)
        // Same-id replace: drop the old image file unless something still uses it.
        for old in replaced { deleteImageFile(old) }
    }

    private func applyRemoteToPinboard(_ item: ClipItem, boardID: UUID) {
        // Placeholder board if the clip record arrives before its Pinboard record.
        if !pinboards.contains(where: { $0.id == boardID }) {
            pinboards.append(Pinboard(id: boardID, name: "Pinboard", items: []))
        }
        guard let i = pinboards.firstIndex(where: { $0.id == boardID }) else { return }
        // Legacy shared-id records: a pinboard clip also evicts the same id from history.
        var replaced = history.filter { $0.id == item.id }
        history.removeAll { $0.id == item.id }
        replaced += pinboards[i].items.filter { $0.id == item.id }
        pinboards[i].items.removeAll { $0.id == item.id }
        let key = contentKey(item)
        if let dupIdx = pinboards[i].items.firstIndex(where: { contentKey($0) == key }) {
            let dup = pinboards[i].items[dupIdx]
            if dup.createdAt >= item.createdAt {
                deleteImageFile(item)
                for old in replaced { deleteImageFile(old) }
                return
            }
            pinboards[i].items.remove(at: dupIdx)
            deleteImageFile(dup)
        }
        insertSortedByDate(item, into: &pinboards[i].items)
        retentionPrunedRecordNames.remove(item.id.uuidString)
        // Same-id replace: drop the old image file unless something still uses it.
        for old in replaced { deleteImageFile(old) }
    }

    private func insertSortedByDate(_ item: ClipItem, into items: inout [ClipItem]) {
        let idx = items.firstIndex(where: { $0.createdAt < item.createdAt }) ?? items.endIndex
        items.insert(item, at: idx)
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

    private func contentKey(_ item: ClipItem) -> String {
        switch item.type {
        case .image: return "img:" + (item.imageHash ?? item.imageFileName ?? item.id.uuidString)
        case .color: return "col:" + (item.colorHex ?? "")
        case .file:  return "file:" + item.fileURLs.joined(separator: "|")
        default:     return "txt:" + (item.text ?? "")
        }
    }

    private func mergeExternal(_ snap: Snapshot) {
        let before = history.count
        deletionLedger.merge(snap.deletionLedger ?? ClipDeletionLedger())
        let deletedIDs = deletionLedger.deletedIDs
        let isDeleted: (ClipItem) -> Bool = { deletedIDs.contains($0.id) }

        var combined = (history + snap.history)
            .filter { !isDeleted($0) }
            .sorted { $0.createdAt > $1.createdAt }
        var seen = Set<String>()
        var merged: [ClipItem] = []
        for it in combined where seen.insert(contentKey(it)).inserted { merged.append(it) }
        history = merged
        trimHistory()

        var byID: [UUID: Pinboard] = Dictionary(uniqueKeysWithValues: pinboards.map { ($0.id, $0) })
        for b in snap.pinboards {
            if var existing = byID[b.id] {
                for it in b.items
                where !isDeleted(it) && !existing.items.contains(where: { $0.sameContent(as: it) }) {
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

        combined.removeAll()
        _ = refreshDeletionState(at: .now)
        selectFirst()
        if history.count != before || !snap.history.isEmpty { saveNow() }
    }

    private func startWatching() {
        stopWatching()
        let fd = open(storeURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            if Date() < self.ignoreWatchUntil { return }
            if let data = try? Data(contentsOf: self.storeURL),
               let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
                self.mergeExternal(snap)
            }
            self.startWatching()
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
