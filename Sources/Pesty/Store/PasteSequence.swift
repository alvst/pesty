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
/// pending entry, pastes it into the last active app, and marks it done.
///
/// This is the core engine only - selection state and search/filtering for a
/// floating panel are intentionally not part of this type yet; a later PR
/// reintroduces them alongside the UI that needs them.
@Observable
@MainActor
final class PasteSequence {
    static let shared = PasteSequence()

    private(set) var entries: [PasteStackEntry] = []
    private(set) var isCollecting = false
    private(set) var savedStacks: [SavedPasteStack] = []
    private(set) var activeStackID: UUID?

    var pendingCount: Int { entries.count(where: { !$0.isPasted }) }
    var hasEntries: Bool { !entries.isEmpty }

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
        persistActiveStack()
        return true
    }

    // MARK: - Pasting

    /// Returns the oldest pending entry and moves it to the bottom of the stack.
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

    private func takeEntry(at index: Int) -> PasteStackEntry {
        var result = entries.remove(at: index)
        result.isPasted = true
        entries.append(result)
        isCollecting = false
        persistActiveStack()
        return result
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
    }

    private func activate(_ stack: SavedPasteStack) {
        activeStackID = stack.id
        entries = stack.entries
        isCollecting = false
    }

    // MARK: - Persistence

    /// Restores saved stacks from disk and reopens the newest non-empty one
    /// as the active stack, mirroring ClipboardStore's load-on-launch pattern.
    func restoreSavedStacks(_ stacks: [SavedPasteStack]) {
        savedStacks = stacks.sorted { $0.createdAt > $1.createdAt }
        guard let newest = savedStacks.first(where: \.hasEntries) else {
            entries = []
            activeStackID = nil
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
