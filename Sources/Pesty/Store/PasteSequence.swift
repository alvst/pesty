import AppKit
import Observation

struct PasteStackEntry: Identifiable {
    let id: UUID
    let item: ClipItem
    /// Keeps an image pasteable even if its source history item is removed while
    /// the stack is open.
    let imagePreview: NSImage?
    var isPasted: Bool

    init(item: ClipItem, imagePreview: NSImage? = nil) {
        self.id = UUID()
        self.item = item
        self.imagePreview = imagePreview
        self.isPasted = false
    }
}

@Observable
@MainActor
final class PasteSequence {
    static let shared = PasteSequence()

    private(set) var entries: [PasteStackEntry] = []
    private(set) var isCollecting = false
    private(set) var selectedEntryID: UUID?

    var count: Int { pendingCount }
    var pendingCount: Int { entries.count(where: { !$0.isPasted }) }
    var pastedCount: Int { entries.count - pendingCount }
    var hasEntries: Bool { !entries.isEmpty }
    var isRunning: Bool { !isCollecting && pendingCount > 0 }

    func containsHistoryItemID(_ id: UUID) -> Bool {
        entries.contains { $0.item.id == id }
    }
    /// Pending clips come first; clips already pasted stay at the bottom of
    /// the stack so the next clip is always visually on top.
    var displayEntries: [PasteStackEntry] {
        let pending = entries.filter { !$0.isPasted }
        let queued = Settings.shared.stackPasteInReverse ? Array(pending.reversed()) : pending
        return queued + entries.filter(\.isPasted)
    }
    var displayItems: [ClipItem] { displayEntries.map(\.item) }
    var selectedEntry: PasteStackEntry? {
        guard let selectedEntryID else { return nil }
        return entries.first(where: { $0.id == selectedEntryID })
    }

    // Kept as an alias while the main bar transitions from the old queue mode.
    var isBuilding: Bool { isCollecting }

    private init() {}

    /// Opens the stack for collection without discarding its pasted history.
    func begin() {
        isCollecting = true
        if selectedEntryID == nil { selectFirst() }
    }

    func pause() {
        isCollecting = false
    }

    func newStack() {
        entries.removeAll()
        isCollecting = true
        selectedEntryID = nil
    }

    @discardableResult
    func addIfNeeded(_ item: ClipItem) -> Bool {
        guard isCollecting,
              !entries.contains(where: { $0.item.id == item.id }) else { return false }
        let preview = item.type == .image ? ClipboardStore.shared.loadImage(for: item) : nil
        entries.append(PasteStackEntry(item: item, imagePreview: preview))
        if selectedEntryID == nil { selectFirst() }
        return true
    }

    func selectFirst() {
        selectedEntryID = displayEntries.first?.id
    }

    /// After one clip is pasted, selection always advances to the first
    /// remaining pending clip in the visible stack order. This intentionally
    /// skips the pasted clip that just moved to the bottom.
    private func selectNextPendingEntry() {
        let displayed = displayEntries
        selectedEntryID = displayed.first(where: { !$0.isPasted })?.id ?? displayed.first?.id
    }

    func select(_ entry: PasteStackEntry) {
        selectedEntryID = entry.id
    }

    func moveSelection(by delta: Int) {
        let displayed = displayEntries
        guard !displayed.isEmpty else { selectedEntryID = nil; return }
        guard let selectedEntryID,
              let index = displayed.firstIndex(where: { $0.id == selectedEntryID }) else {
            self.selectedEntryID = displayed.first?.id
            return
        }
        let next = max(0, min(displayed.count - 1, index + delta))
        self.selectedEntryID = displayed[next].id
    }

    /// Returns the next pending entry and moves it to the bottom of the stack.
    /// The full stack therefore reads like a physical queue as clips are pasted.
    func next() -> PasteStackEntry? {
        let pendingIndexes = entries.indices.filter { !entries[$0].isPasted }
        guard let index = Settings.shared.stackPasteInReverse
                ? pendingIndexes.last
                : pendingIndexes.first else {
            isCollecting = false
            return nil
        }
        return takeEntry(at: index)
    }

    func next(itemID: UUID) -> PasteStackEntry? {
        guard let index = entries.firstIndex(where: { $0.item.id == itemID && !$0.isPasted }) else {
            return nil
        }
        return takeEntry(at: index)
    }

    func next(entryID: UUID) -> PasteStackEntry? {
        guard let index = entries.firstIndex(where: { $0.id == entryID && !$0.isPasted }) else {
            return nil
        }
        return takeEntry(at: index)
    }

    func isPasted(_ item: ClipItem) -> Bool {
        entries.first(where: { $0.item.id == item.id })?.isPasted ?? false
    }

    private func takeEntry(at index: Int) -> PasteStackEntry {
        var result = entries.remove(at: index)
        result.isPasted = true
        entries.append(result)
        isCollecting = false
        if pendingCount == 0, !Settings.shared.keepPastedStackItems {
            entries.removeAll()
            selectedEntryID = nil
        } else {
            selectNextPendingEntry()
        }
        return result
    }

    func reAdd(_ entry: PasteStackEntry) {
        entries.append(PasteStackEntry(item: entry.item, imagePreview: entry.imagePreview))
        selectFirst()
    }

    func remove(_ entry: PasteStackEntry) {
        entries.removeAll { $0.id == entry.id }
        if selectedEntryID == entry.id { selectFirst() }
    }

    func resetProgress() {
        for index in entries.indices {
            entries[index].isPasted = false
        }
        isCollecting = false
        selectFirst()
    }

    func finishCollecting() {
        isCollecting = false
    }

    func cancel() {
        entries.removeAll()
        isCollecting = false
        selectedEntryID = nil
    }
}
