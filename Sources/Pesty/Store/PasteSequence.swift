import AppKit
import Observation

struct PasteStackEntry: Identifiable {
    let id = UUID()
    let item: ClipItem
    /// Holds an in-memory image while a Stack is active, even if the image is
    /// later pruned from clipboard history.
    let imagePreview: NSImage?

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

    var hasEntries: Bool { !entries.isEmpty }
    var pendingCount: Int { entries.count }

    private init() {}

    func begin() {
        entries.removeAll()
        isCollecting = true
    }

    @discardableResult
    func addIfNeeded(_ item: ClipItem) -> Bool {
        guard isCollecting,
              !entries.contains(where: { $0.item.id == item.id }) else { return false }
        let imagePreview = item.type == .image ? ClipboardStore.shared.loadImage(for: item) : nil
        entries.append(PasteStackEntry(item: item, imagePreview: imagePreview))
        return true
    }

    func next() -> PasteStackEntry? {
        guard !entries.isEmpty else {
            isCollecting = false
            return nil
        }
        isCollecting = false
        return entries.removeFirst()
    }

    func cancel() {
        entries.removeAll()
        isCollecting = false
    }
}
