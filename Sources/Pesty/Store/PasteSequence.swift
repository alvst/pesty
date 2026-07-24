import AppKit
import Observation

struct PasteStackEntry: Identifiable, Codable {
    let id: UUID
    let item: ClipItem
    /// This is intentionally not persisted. The backing clip image remains in
    /// ClipboardStore and is used again after relaunch; the in-memory copy only
    /// protects an image during the active capture session.
    let imagePreview: NSImage?
    var isPasted: Bool

    init(item: ClipItem, imagePreview: NSImage? = nil) {
        self.id = UUID()
        self.item = item
        self.imagePreview = imagePreview
        self.isPasted = false
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

/// A saved queue is one Clipboard item in the main bar. Its clips stay ordered
/// and pasteable, but are never expanded back into ordinary clipboard cards.
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

    func displayEntries(pasteInReverse: Bool) -> [PasteStackEntry] {
        let pending = entries.filter { !$0.isPasted }
        let queued = pasteInReverse ? Array(pending.reversed()) : pending
        return queued + entries.filter(\.isPasted)
    }
}

@Observable
@MainActor
final class PasteSequence {
    static let shared = PasteSequence()

    private(set) var entries: [PasteStackEntry] = []
    private(set) var isCollecting = false
    private(set) var selectedEntryID: UUID?
    private(set) var savedStacks: [SavedPasteStack] = []
    private(set) var activeStackID: UUID?

    var count: Int { pendingCount }
    var pendingCount: Int { entries.count(where: { !$0.isPasted }) }
    var pastedCount: Int { entries.count - pendingCount }
    var hasEntries: Bool { !entries.isEmpty }
    var hasSavedStacks: Bool { savedStacks.contains(where: \.hasEntries) }
    var isRunning: Bool { !isCollecting && pendingCount > 0 }

    /// Every saved stack is collapsed into a single deck on Clipboard.
    func containsHistoryItemID(_ id: UUID) -> Bool {
        savedStacks.contains { stack in stack.entries.contains { $0.item.id == id } }
    }

    /// Pending clips come first; clips already pasted stay at the bottom of
    /// the selected stack so the next clip is always visually on top.
    var displayEntries: [PasteStackEntry] {
        let pending = entries.filter { !$0.isPasted }
        let queued = Settings.shared.stackPasteInReverse ? Array(pending.reversed()) : pending
        return queued + entries.filter(\.isPasted)
    }

    var selectedEntry: PasteStackEntry? {
        guard let selectedEntryID else { return nil }
        return entries.first(where: { $0.id == selectedEntryID })
    }

    // Kept as an alias while the main bar transitions from the old queue mode.
    var isBuilding: Bool { isCollecting }

    private init() {}

    func restoreSavedStacks(_ stacks: [SavedPasteStack]) {
        savedStacks = stacks.sorted { $0.createdAt > $1.createdAt }
        guard let newest = savedStacks.first(where: \.hasEntries) else {
            entries = []
            activeStackID = nil
            selectedEntryID = nil
            return
        }
        activate(newest)
    }

    func selectStack(_ id: UUID) {
        guard let stack = savedStacks.first(where: { $0.id == id }) else { return }
        activate(stack)
    }

    /// Opens the selected stack for collection without discarding saved stacks.
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
        entries.append(makeEntry(for: item))
        if selectedEntryID == nil { selectFirst() }
        persistActiveStack()
        return true
    }

    /// Adds a clip the user explicitly chose from Clipboard history. Unlike
    /// captured clips, this starts (or resumes) collection so the selected
    /// clip has an active stack to join.
    @discardableResult
    func addHistoryItem(_ item: ClipItem) -> Bool {
        ensureActiveStack()
        guard !entries.contains(where: { $0.item.id == item.id }) else { return false }

        isCollecting = true
        entries.append(makeEntry(for: item))
        if selectedEntryID == nil { selectFirst() }
        persistActiveStack()
        return true
    }

    func containsActiveHistoryItemID(_ id: UUID) -> Bool {
        entries.contains { $0.item.id == id }
    }

    func selectFirst() {
        selectedEntryID = displayEntries.first?.id
    }

    /// After one clip is pasted, selection advances to the next pending clip,
    /// intentionally skipping the pasted clip moved to the stack bottom.
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
    func next() -> PasteStackEntry? {
        let pendingIndexes = entries.indices.filter { !entries[$0].isPasted }
        guard let index = Settings.shared.stackPasteInReverse
                ? pendingIndexes.last
                : pendingIndexes.first else {
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
        persistActiveStack()
        return result
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

    /// Deletes only the selected saved stack; all other stack decks remain.
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

    /// Used only when the user chooses to have saved stacks follow clipboard
    /// retention. Empty stacks are removed after their final clip expires.
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

    /// Capture the rendered image while the history item is still available.
    /// The entry also retains its image file reference for persistence, while
    /// this in-memory preview keeps the current paste session visually stable.
    private func makeEntry(for item: ClipItem) -> PasteStackEntry {
        let preview = item.type == .image ? ClipboardStore.shared.loadImage(for: item) : nil
        return PasteStackEntry(item: item, imagePreview: preview)
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
