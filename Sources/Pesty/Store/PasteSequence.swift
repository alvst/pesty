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

    var count: Int { pendingCount }
    var pendingCount: Int { entries.count(where: { !$0.isPasted }) }
    var pastedCount: Int { entries.count - pendingCount }
    var hasEntries: Bool { !entries.isEmpty }
    var isRunning: Bool { !isCollecting && pendingCount > 0 }

    // Kept as an alias while the main bar transitions from the old queue mode.
    var isBuilding: Bool { isCollecting }

    private init() {}

    /// Opens the stack for collection without discarding its pasted history.
    func begin() {
        isCollecting = true
    }

    func newStack() {
        entries.removeAll()
        isCollecting = true
    }

    @discardableResult
    func addIfNeeded(_ item: ClipItem) -> Bool {
        guard isCollecting,
              !entries.contains(where: { $0.item.id == item.id }) else { return false }
        let preview = item.type == .image ? ClipboardStore.shared.loadImage(for: item) : nil
        entries.append(PasteStackEntry(item: item, imagePreview: preview))
        return true
    }

    func position(of item: ClipItem) -> Int? {
        let pending = pendingEntries
        return pending.firstIndex(where: { $0.item.id == item.id }).map { $0 + 1 }
    }

    /// Starts (if necessary) and returns the next pending entry without removing
    /// it from the stack, preserving a visible paste history in the floating tray.
    func next() -> PasteStackEntry? {
        let pendingIndexes = entries.indices.filter { !entries[$0].isPasted }
        guard let index = Settings.shared.stackPasteInReverse
                ? pendingIndexes.last
                : pendingIndexes.first else {
            isCollecting = false
            return nil
        }
        isCollecting = false
        entries[index].isPasted = true
        return entries[index]
    }

    func reAdd(_ entry: PasteStackEntry) {
        entries.append(PasteStackEntry(item: entry.item, imagePreview: entry.imagePreview))
    }

    func remove(_ entry: PasteStackEntry) {
        entries.removeAll { $0.id == entry.id }
    }

    func resetProgress() {
        for index in entries.indices {
            entries[index].isPasted = false
        }
        isCollecting = false
    }

    func finishCollecting() {
        isCollecting = false
    }

    func cancel() {
        entries.removeAll()
        isCollecting = false
    }

    private var pendingEntries: [PasteStackEntry] {
        let pending = entries.filter { !$0.isPasted }
        return Settings.shared.stackPasteInReverse ? Array(pending.reversed()) : pending
    }
}
