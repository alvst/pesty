import AppKit
import Observation

enum BarSource: Equatable {
    case history
    case pasteStack
    case pinboard(UUID)
}

@Observable
@MainActor
final class ClipboardStore {
    static let shared = ClipboardStore()

    private(set) var history: [ClipItem] = []
    private(set) var pinboards: [Pinboard] = []

    var source: BarSource = .history {
        didSet {
            // A selection belongs to the visible strip, not to a clip UUID
            // globally. Pinboard copies intentionally share their source
            // item IDs, so carrying selection across sources is misleading.
            if source != oldValue { selectFirst() }
        }
    }
    var searchText: String = ""
    var selectedID: UUID?
    var inlinePreviewVisible = false
    /// Advances whenever the Paste Bar is presented so the strip can apply
    /// the user's initial-position preference once per presentation, rather
    /// than again on every arrow-key selection.
    private(set) var barPresentationID = 0
    /// Every selected clip in the current strip. `selectedID` remains the
    /// primary selection used by keyboard navigation and Return-to-paste.
    private(set) var selectedIDs: Set<UUID> = []
    private var selectionAnchorID: UUID?

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

    private init() {
        let base = (Settings.shared.iCloudSync ? ClipboardStore.iCloudBase : nil) ?? ClipboardStore.localBase
        baseDir = base
        imagesDir = base.appendingPathComponent("images", isDirectory: true)
        storeURL = base.appendingPathComponent("store.json")
        prepareDirectories()
        load()
        if applyHistoryPolicyNow() { saveNow() }
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
            // Paste Stack entries have their own identity and selection state.
            // PasteStackContentView renders them directly instead of folding
            // them into the clipboard history strip.
            base = []
        case .pinboard(let id):
            base = pinboards.first(where: { $0.id == id })?.items ?? []
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else {
            // Each saved Paste Stack is represented by one deck card on
            // Clipboard. Its clips remain in history for persistence, but do
            // not also appear as individual Clipboard cards.
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
        if let idx = history.firstIndex(where: { $0.sameContent(as: item) }) {
            if item.imageFileName != history[idx].imageFileName { deleteImageFile(item) }
            var existing = history.remove(at: idx)
            existing.createdAt = item.createdAt
            history.insert(existing, at: 0)
            applyHistoryPolicyNow()
            if source == .history && searchText.isEmpty { selectOnly(existing.id) }
            scheduleSave()
            return existing
        }
        history.insert(item, at: 0)
        applyHistoryPolicyNow()
        if source == .history && searchText.isEmpty {
            selectOnly(item.id)
        }
        scheduleSave()
        return item
    }

    func applyHistoryPolicy() {
        // Opening the bar runs the retention check. Do not schedule a full
        // JSON encode and disk write unless that check actually changed the
        // persisted history.
        if applyHistoryPolicyNow() {
            scheduleSave()
        }
    }

    /// A Copy from the Paste Bar is an intentional use of an existing clip.
    /// Promote it explicitly because ClipboardMonitor ignores Pesty's own
    /// pasteboard writes to avoid capturing duplicate history entries.
    @discardableResult
    func promoteCopiedItem(_ item: ClipItem, at date: Date = .now) -> ClipItem {
        var copied = item
        copied.createdAt = date
        return addCaptured(copied)
    }

    func noteBarPresented() {
        barPresentationID &+= 1
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
        reconcileSelection()
        return true
    }

    func delete(_ item: ClipItem) {
        delete([item])
    }

    func deleteSelected() {
        let items = visibleItems.filter { selectedIDs.contains($0.id) }
        if items.isEmpty, let selectedItem {
            delete(selectedItem)
        } else {
            delete(items)
        }
    }

    /// Deleting from a selected card follows Finder behavior: delete the
    /// entire current selection. A context menu opened on an unselected card
    /// only deletes that card.
    func deleteSelection(containing item: ClipItem) {
        if selectedIDs.contains(item.id) {
            deleteSelected()
        } else {
            delete(item)
        }
    }

    private func delete(_ items: [ClipItem]) {
        let ids = Set(items.map(\.id))
        guard !ids.isEmpty else { return }

        // A Pinboard is an independently saved collection. Deleting from the
        // current strip must not erase same-ID copies in other pinboards (or
        // from history), even though copies retain their source clip ID.
        let removed: [ClipItem]
        switch source {
        case .history:
            removed = history.filter { ids.contains($0.id) }
            history.removeAll { ids.contains($0.id) }
            if Settings.shared.pasteStacksFollowHistory {
                PasteSequence.shared.removeHistoryItems(ids)
            }
        case .pasteStack:
            return
        case .pinboard(let boardID):
            guard let boardIndex = pinboards.firstIndex(where: { $0.id == boardID }) else { return }
            removed = pinboards[boardIndex].items.filter { ids.contains($0.id) }
            pinboards[boardIndex].items.removeAll { ids.contains($0.id) }
        }
        for item in removed { deleteImageFile(item) }
        reconcileSelection()
        scheduleSave()
    }

    func clearHistory() {
        let old = history
        history.removeAll()
        if Settings.shared.pasteStacksFollowHistory {
            PasteSequence.shared.removeHistoryItems(Set(old.map(\.id)))
        }
        if source == .history {
            selectOnly(nil)
        } else {
            reconcileSelection()
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

    /// Moves a Pinboard relative to the tab currently under the drag. The
    /// ordered array is persisted as part of the normal store snapshot.
    func movePinboard(_ movedID: UUID, over targetID: UUID) {
        guard movedID != targetID,
              let from = pinboards.firstIndex(where: { $0.id == movedID }),
              let to = pinboards.firstIndex(where: { $0.id == targetID }) else { return }
        let moved = pinboards.remove(at: from)
        // `to` is the target's pre-removal index. Keeping that index means the
        // dragged tab lands after a target to its right and before one to its
        // left, matching the visual drop direction.
        pinboards.insert(moved, at: to)
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

    func deletePinboard(_ id: UUID) {
        guard let i = pinboards.firstIndex(where: { $0.id == id }) else { return }
        if case .pinboard(let cur) = source, cur == id { source = .history }
        let removedItems = pinboards[i].items
        pinboards.remove(at: i)
        for item in removedItems { deleteImageFile(item) }
        scheduleSave()
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
        if let i = history.firstIndex(where: { $0.id == item.id }) { history[i].customTitle = title }
        for b in pinboards.indices {
            if let i = pinboards[b].items.firstIndex(where: { $0.id == item.id }) {
                pinboards[b].items[i].customTitle = title
            }
        }
        scheduleSave()
    }

    func selectFirst() { selectOnly(visibleItems.first?.id) }

    /// Removes selections that are no longer in the current source or filter.
    /// This is called after structural changes so selection count, highlights,
    /// and bulk-delete always refer to the same visible cards.
    private func reconcileSelection() {
        let visibleIDs = Set(visibleItems.map(\.id))
        selectedIDs.formIntersection(visibleIDs)

        guard let selectedID, visibleIDs.contains(selectedID) else {
            if let first = visibleItems.first?.id {
                selectOnly(first)
            } else {
                selectOnly(nil)
            }
            return
        }

        selectedIDs.insert(selectedID)
        if let selectionAnchorID, !visibleIDs.contains(selectionAnchorID) {
            self.selectionAnchorID = selectedID
        }
    }

    /// Finds the current version of a clip after an edit. Pinboard items retain
    /// the history item's identity, so changing a clip can update every saved
    /// copy without matching unrelated clips that happen to have the same text.
    func item(withID id: UUID) -> ClipItem? {
        if let item = history.first(where: { $0.id == id }) { return item }
        return pinboards.lazy.flatMap(\.items).first(where: { $0.id == id })
    }

    /// Updates the saved payload of a text-like clip while retaining its
    /// identity, source attribution, creation date, and optional card title.
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

        guard changed else { return false }
        if selectedItem == nil { selectFirst() }
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

    func moveSelection(by delta: Int) {
        let items = visibleItems
        guard !items.isEmpty else { return }
        guard let id = selectedID, let idx = items.firstIndex(where: { $0.id == id }) else {
            selectOnly(items.first?.id); return
        }
        let next = max(0, min(items.count - 1, idx + delta))
        selectOnly(items[next].id)
    }

    /// Applies Finder-style selection to a card click:
    /// - a normal click selects only that clip;
    /// - Command-click toggles that clip without disturbing the other clips;
    /// - Shift-click selects the contiguous range from the selection anchor.
    /// Command-Shift-click adds that range to an existing selection.
    func select(_ id: UUID, with modifiers: NSEvent.ModifierFlags) {
        let items = visibleItems
        guard let targetIndex = items.firstIndex(where: { $0.id == id }) else { return }

        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)

        if flags.contains(.shift),
           let anchorID = selectionAnchorID ?? selectedID,
           let anchorIndex = items.firstIndex(where: { $0.id == anchorID }) {
            let range = Set(items[min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)].map(\.id))
            if command {
                selectedIDs.formUnion(range)
            } else {
                selectedIDs = range
            }
            selectedID = id
            return
        }

        if command {
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
                if selectedID == id {
                    selectedID = items.first(where: { selectedIDs.contains($0.id) })?.id
                }
                if selectionAnchorID == id {
                    selectionAnchorID = selectedID
                }
            } else {
                selectedIDs.insert(id)
                selectedID = id
                if selectionAnchorID == nil { selectionAnchorID = id }
            }
            return
        }

        selectOnly(id)
    }

    private func selectOnly(_ id: UUID?) {
        selectedID = id
        selectedIDs = id.map { [$0] } ?? []
        selectionAnchorID = id
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
        if stillUsed { return }
        if let url = imageURL(for: item) { try? FileManager.default.removeItem(at: url) }
    }

    private struct Snapshot: Codable {
        var history: [ClipItem]
        var pinboards: [Pinboard]
        var pasteStacks: [SavedPasteStack]?
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        history = snap.history
        pinboards = snap.pinboards
        PasteSequence.shared.restoreSavedStacks(snap.pasteStacks ?? [])
        selectFirst()
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        let snap = Snapshot(history: history,
                            pinboards: pinboards,
                            pasteStacks: PasteSequence.shared.savedStacks)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        ignoreWatchUntil = Date().addingTimeInterval(1.5)
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
        var combined = (history + snap.history).sorted { $0.createdAt > $1.createdAt }
        var seen = Set<String>()
        var merged: [ClipItem] = []
        for it in combined where seen.insert(contentKey(it)).inserted { merged.append(it) }
        history = merged
        applyHistoryPolicyNow()

        var byID: [UUID: Pinboard] = Dictionary(uniqueKeysWithValues: pinboards.map { ($0.id, $0) })
        for b in snap.pinboards {
            if var existing = byID[b.id] {
                for it in b.items where !existing.items.contains(where: { $0.sameContent(as: it) }) {
                    existing.items.append(it)
                }
                byID[b.id] = existing
            } else {
                byID[b.id] = b
            }
        }
        pinboards = pinboards.map { byID[$0.id] ?? $0 }
            + byID.values.filter { b in !pinboards.contains(where: { $0.id == b.id }) }

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
        PasteSequence.shared.restoreSavedStacks(
            stacksByID.values.sorted { $0.createdAt > $1.createdAt }
        )

        combined.removeAll()
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
