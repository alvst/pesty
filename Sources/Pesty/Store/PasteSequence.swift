import AppKit
import Observation

/// One clip queued into an active (or saved) paste stack.
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

/// A named, ordered collection of queued clips. Only one stack is "active"
/// (open for collecting or pasting) at a time; the rest sit on disk as decks
/// for a future PR's deck-switcher UI to surface.
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
}

/// Drives the "Paste Stacks" collect/paste workflow: while collecting is on,
/// copies made elsewhere are queued in order; "paste next" pops the oldest
/// (or newest, with `stackPasteInReverse`) pending entry, pastes it into the
/// last active app, and marks it done. Selection tracks which entry the
/// floating panel highlights and pastes on Enter/click.
@Observable
@MainActor
final class PasteSequence {
    static let shared = PasteSequence()

    private(set) var entries: [PasteStackEntry] = []
    private(set) var isCollecting = false
    private(set) var savedStacks: [SavedPasteStack] = []
    private(set) var activeStackID: UUID?
    private(set) var selectedEntryID: UUID?

    var pendingCount: Int { entries.count(where: { !$0.isPasted }) }
    var pastedCount: Int { entries.count - pendingCount }
    var hasEntries: Bool { !entries.isEmpty }

    var selectedEntry: PasteStackEntry? {
        guard let selectedEntryID else { return nil }
        return entries.first(where: { $0.id == selectedEntryID })
    }

    /// Pending clips come first (in `stackPasteInReverse` order so the panel
    /// always shows what "paste next" will pick up on top); clips already
    /// pasted stay at the bottom of the list.
    var displayEntries: [PasteStackEntry] {
        let pending = entries.filter { !$0.isPasted }
        let queued = Settings.shared.stackPasteInReverse ? Array(pending.reversed()) : pending
        return queued + entries.filter(\.isPasted)
    }

    @ObservationIgnored private var saveWorkItem: DispatchWorkItem?

    private static var baseDir: URL { ClipboardStore.localBase }
    private static var storeURL: URL { baseDir.appendingPathComponent("pasteStacks.json") }

    private init() {
        load()
    }

    // MARK: - Collecting

    /// Opens the active stack for collection without discarding saved stacks.
    func begin() {
        guard Settings.shared.pasteStacksEnabled else { return }
        ensureActiveStack()
        isCollecting = true
        if selectedEntryID == nil { selectFirst() }
        persistActiveStack()
    }

    func pause() {
        isCollecting = false
        persistActiveStack()
    }

    func finishCollecting() {
        isCollecting = false
        persistActiveStack()
    }

    /// Starts a distinct, empty saved stack. Previous stacks remain as decks.
    func newStack() {
        guard Settings.shared.pasteStacksEnabled else { return }
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
        let preview = item.type == .image ? ClipboardStore.shared.loadImage(for: item) : nil
        entries.append(PasteStackEntry(item: item, imagePreview: preview))
        if selectedEntryID == nil { selectFirst() }
        persistActiveStack()
        return true
    }

    /// Purges entries backed by the given clips from the active stack and
    /// every saved deck, so a clip deleted from history does not live on in
    /// the queue or in pasteStacks.json.
    func removeItems(withIDs ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let hadActiveMatches = entries.contains { ids.contains($0.item.id) }
        entries.removeAll { ids.contains($0.item.id) }
        var changed = hadActiveMatches
        for index in savedStacks.indices
        where savedStacks[index].entries.contains(where: { ids.contains($0.item.id) }) {
            savedStacks[index].entries.removeAll { ids.contains($0.item.id) }
            savedStacks[index].updatedAt = .now
            changed = true
        }
        guard changed else { return }
        persistActiveStack()
        scheduleSave()
    }

    // MARK: - Selection

    /// Selects the first entry in the panel's display order (pending items,
    /// respecting `stackPasteInReverse`, ahead of already-pasted ones).
    func selectFirst() {
        selectedEntryID = displayEntries.first?.id
    }

    func select(_ entry: PasteStackEntry) {
        selectedEntryID = entry.id
    }

    /// Moves the selection by `delta` positions through `displayEntries`,
    /// clamped to the ends of the list. Used for arrow-key navigation in the
    /// floating panel.
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

    /// After one clip is pasted, selection advances to the next pending clip,
    /// intentionally skipping the pasted clip moved to the stack bottom.
    private func selectNextPendingEntry() {
        let displayed = displayEntries
        selectedEntryID = displayed.first(where: { !$0.isPasted })?.id ?? displayed.first?.id
    }

    // MARK: - Pasting

    /// The entry `next()` would consume - oldest, or newest with
    /// `stackPasteInReverse` - without consuming it. Callers paste the clip
    /// first and only consume via `next(entryID:)` once the pasteboard write
    /// actually succeeded.
    func peekNext() -> PasteStackEntry? {
        nextPendingIndex().map { entries[$0] }
    }

    /// The pending entry with `id`, without consuming it, for the same
    /// paste-then-consume handshake `peekNext()` serves.
    func peekEntry(id: UUID) -> PasteStackEntry? {
        entries.first(where: { $0.id == id && !$0.isPasted })
    }

    /// Returns the oldest (or, with `stackPasteInReverse`, newest) pending
    /// entry and moves it to the bottom of the stack.
    func next() -> PasteStackEntry? {
        // Nothing pending is not a reason to stop collecting: an accidental
        // "paste next" while the stack is drained should leave the session on.
        guard let index = nextPendingIndex() else { return nil }
        return takeEntry(at: index)
    }

    private func nextPendingIndex() -> Int? {
        let pendingIndexes = entries.indices.filter { !entries[$0].isPasted }
        return Settings.shared.stackPasteInReverse ? pendingIndexes.last : pendingIndexes.first
    }

    /// Pastes a specific pending entry out of order - the panel's "paste
    /// this" click target and Enter-to-paste on the selected card.
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

    /// Removes an entry from the panel, e.g. its × button.
    func remove(_ entry: PasteStackEntry) {
        entries.removeAll { $0.id == entry.id }
        if selectedEntryID == entry.id { selectFirst() }
        persistActiveStack()
    }

    /// Deletes only the active saved stack; all other stack decks remain.
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
        scheduleSave()
    }

    // MARK: - Active stack bookkeeping

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

    // MARK: - Persistence

    /// Restores saved stacks from disk and reopens the newest non-empty one
    /// as the active stack, mirroring ClipboardStore's load-on-launch pattern.
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

    private func persistActiveStack() {
        guard let activeStackID,
              let index = savedStacks.firstIndex(where: { $0.id == activeStackID }) else { return }
        savedStacks[index].entries = entries
        savedStacks[index].updatedAt = .now
        scheduleSave()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let stacks = try? JSONDecoder().decode([SavedPasteStack].self, from: data) else { return }
        restoreSavedStacks(stacks)
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        guard let data = try? JSONEncoder().encode(savedStacks) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.baseDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? data.write(to: Self.storeURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.storeURL.path)
    }
}
