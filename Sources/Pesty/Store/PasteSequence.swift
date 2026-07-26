import AppKit
import Observation

struct PasteStackEntry: Identifiable, Codable {
    let id: UUID
    let item: ClipItem
    /// This stays in memory only. The persisted clip image remains in
    /// ClipboardStore and is loaded again after relaunch.
    let imagePreview: NSImage?
    /// Pasted clips remain in the stack so its deck can show progress and be
    /// reset without asking the user to collect the same clips again.
    var isPasted: Bool

    init(id: UUID = UUID(), item: ClipItem, imagePreview: NSImage? = nil, isPasted: Bool = false) {
        self.id = id
        self.item = item
        self.imagePreview = imagePreview
        self.isPasted = isPasted
    }

    private enum CodingKeys: String, CodingKey { case id, item, isPasted }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        item = try container.decode(ClipItem.self, forKey: .item)
        isPasted = try container.decode(Bool.self, forKey: .isPasted)
        imagePreview = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(item, forKey: .item)
        try container.encode(isPasted, forKey: .isPasted)
    }
}

/// One persisted Paste Stack deck. Its entries remain ordered and pasteable,
/// but are represented by a single card in clipboard history.
struct SavedPasteStack: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var entries: [PasteStackEntry]

    init(id: UUID = UUID(), createdAt: Date = .now, entries: [PasteStackEntry] = []) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.entries = entries
    }

    var hasEntries: Bool { !entries.isEmpty }
    var pendingCount: Int { entries.count(where: { !$0.isPasted }) }
    var pastedCount: Int { entries.count - pendingCount }

    var displayEntries: [PasteStackEntry] {
        entries.filter { !$0.isPasted } + entries.filter(\.isPasted)
    }
}

@Observable
@MainActor
final class PasteSequence {
    static let shared = PasteSequence()

    /// The active stack is mirrored here for the existing collection and paste
    /// UI. Every mutation is written back to its SavedPasteStack.
    private(set) var entries: [PasteStackEntry] = []
    private(set) var isCollecting = false
    private(set) var selectedEntryID: UUID?
    private(set) var savedStacks: [SavedPasteStack] = []
    private(set) var activeStackID: UUID?

    var hasEntries: Bool { !entries.isEmpty }
    var hasSavedStacks: Bool { savedStacks.contains(where: \.hasEntries) }
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

    func containsHistoryItemID(_ id: UUID) -> Bool {
        savedStacks.contains { stack in stack.entries.contains { $0.item.id == id } }
    }

    init() {}

    func restoreSavedStacks(_ stacks: [SavedPasteStack]) {
        savedStacks = stacks.sorted { $0.createdAt > $1.createdAt }
        guard let newest = savedStacks.first(where: \.hasEntries) else {
            entries = []
            activeStackID = nil
            selectedEntryID = nil
            isCollecting = false
            return
        }
        activate(newest)
    }

    func selectStack(_ id: UUID) {
        guard let stack = savedStacks.first(where: { $0.id == id }) else { return }
        activate(stack)
    }

    /// Opens the selected stack for collection without discarding saved decks.
    func begin() {
        ensureActiveStack()
        isCollecting = true
        if selectedEntryID == nil { selectFirst() }
        persistActiveStack()
    }

    func pause() {
        isCollecting = false
        persistActiveStack()
    }

    /// Starts a distinct, empty saved stack. Previous stacks remain as decks.
    func newStack() {
        let stack = SavedPasteStack()
        savedStacks.insert(stack, at: 0)
        activeStackID = stack.id
        entries = []
        selectedEntryID = nil
        isCollecting = true
        persistActiveStack()
    }

    @discardableResult
    func addIfNeeded(_ item: ClipItem) -> Bool {
        ensureActiveStack()
        guard isCollecting,
              !entries.contains(where: { $0.item.id == item.id }) else { return false }
        let imagePreview = item.type == .image ? ClipboardStore.shared.loadImage(for: item) : nil
        entries.append(PasteStackEntry(item: item, imagePreview: imagePreview))
        if selectedEntryID == nil { selectFirst() }
        persistActiveStack()
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
            persistActiveStack()
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
        ensureActiveStack()
        entries.append(PasteStackEntry(item: entry.item, imagePreview: entry.imagePreview))
        selectFirst()
        persistActiveStack()
    }

    func remove(_ entry: PasteStackEntry) {
        entries.removeAll { $0.id == entry.id }
        if selectedEntryID == entry.id { selectFirst() }
        persistActiveStack()
    }

    func resetProgress() {
        for index in entries.indices { entries[index].isPasted = false }
        isCollecting = false
        selectFirst()
        persistActiveStack()
    }

    func finishCollecting() {
        isCollecting = false
        persistActiveStack()
    }

    /// Deletes only the active saved stack; all other deck cards remain.
    func cancel() {
        guard let activeStackID else { return }
        savedStacks.removeAll { $0.id == activeStackID }
        if let next = savedStacks.first(where: \.hasEntries) {
            activate(next)
        } else {
            entries = []
            self.activeStackID = nil
            selectedEntryID = nil
            isCollecting = false
        }
        ClipboardStore.shared.pasteStacksDidChange()
    }

    func deleteStack(_ id: UUID) {
        guard savedStacks.contains(where: { $0.id == id }) else { return }
        if activeStackID == id {
            cancel()
        } else {
            savedStacks.removeAll { $0.id == id }
            ClipboardStore.shared.pasteStacksDidChange()
        }
    }

    /// Used when the user elects to have saved stacks follow clipboard
    /// retention. Empty stacks are removed with their final history item.
    func removeHistoryItems(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for index in savedStacks.indices {
            savedStacks[index].entries.removeAll { ids.contains($0.item.id) }
        }
        savedStacks.removeAll { !$0.hasEntries }
        if let activeStackID,
           let active = savedStacks.first(where: { $0.id == activeStackID }) {
            entries = active.entries
            selectFirst()
        } else if let next = savedStacks.first(where: \.hasEntries) {
            activate(next)
        } else {
            entries = []
            activeStackID = nil
            selectedEntryID = nil
            isCollecting = false
        }
        ClipboardStore.shared.pasteStacksDidChange()
    }

    private func takeEntry(at index: Int) -> PasteStackEntry {
        var entry = entries.remove(at: index)
        entry.isPasted = true
        entries.append(entry)
        isCollecting = false
        selectFirst()
        persistActiveStack()
        return entry
    }

    private func ensureActiveStack() {
        if let activeStackID,
           savedStacks.contains(where: { $0.id == activeStackID }) { return }
        if let saved = savedStacks.first(where: \.hasEntries) {
            activate(saved)
            return
        }
        let stack = SavedPasteStack()
        savedStacks.insert(stack, at: 0)
        activeStackID = stack.id
        entries = []
        selectedEntryID = nil
    }

    private func activate(_ stack: SavedPasteStack) {
        activeStackID = stack.id
        entries = stack.entries
        isCollecting = false
        selectFirst()
    }

    private func persistActiveStack() {
        guard let activeStackID,
              let index = savedStacks.firstIndex(where: { $0.id == activeStackID }) else { return }
        savedStacks[index].entries = entries
        savedStacks[index].updatedAt = .now
        ClipboardStore.shared.pasteStacksDidChange()
    }
}
