import AppKit
import Observation

struct PasteStackEntry: Identifiable {
    let id = UUID()
    let item: ClipItem
    /// Holds an in-memory image while a Stack is active, even if the image is
    /// later pruned from clipboard history.
    let imagePreview: NSImage?
    /// Pasted clips remain in the stack so its deck can show progress and be
    /// reset without asking the user to collect the same clips again.
    var isPasted = false

    init(item: ClipItem, imagePreview: NSImage? = nil) {
        self.item = item
        self.imagePreview = imagePreview
    }
}

@Observable
@MainActor
final class PasteSequence {
    static let shared = PasteSequence()

    private(set) var entries: [PasteStackEntry] = []
    private(set) var isCollecting = false
    private(set) var selectedEntryID: UUID?

    var hasEntries: Bool { !entries.isEmpty }
    var pendingCount: Int { entries.count(where: { !$0.isPasted }) }
    var pastedCount: Int { entries.count - pendingCount }
    /// Keep pending clips at the front and previously pasted clips at the end
    /// of the deck. The next clip is therefore always visually first.
    var displayEntries: [PasteStackEntry] {
        entries.filter { !$0.isPasted } + entries.filter(\.isPasted)
    }
    var selectedEntry: PasteStackEntry? {
        guard let selectedEntryID else { return nil }
        return entries.first(where: { $0.id == selectedEntryID })
    }

    private init() {}

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
        let imagePreview = item.type == .image ? ClipboardStore.shared.loadImage(for: item) : nil
        entries.append(PasteStackEntry(item: item, imagePreview: imagePreview))
        if selectedEntryID == nil { selectFirst() }
        return true
    }

    func selectFirst() {
        selectedEntryID = displayEntries.first?.id
    }

    func select(_ entry: PasteStackEntry) {
        selectedEntryID = entry.id
    }

    func moveSelection(by delta: Int) {
        let displayed = displayEntries
        guard !displayed.isEmpty else {
            selectedEntryID = nil
            return
        }
        guard let selectedEntryID,
              let index = displayed.firstIndex(where: { $0.id == selectedEntryID }) else {
            self.selectedEntryID = displayed.first?.id
            return
        }
        let next = max(0, min(displayed.count - 1, index + delta))
        self.selectedEntryID = displayed[next].id
    }

    func next() -> PasteStackEntry? {
        guard let index = entries.firstIndex(where: { !$0.isPasted }) else {
            isCollecting = false
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

    func cancel() {
        entries.removeAll()
        isCollecting = false
        selectedEntryID = nil
    }

    private func takeEntry(at index: Int) -> PasteStackEntry {
        var entry = entries.remove(at: index)
        entry.isPasted = true
        entries.append(entry)
        isCollecting = false
        selectFirst()
        return entry
    }
}
