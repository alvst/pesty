import Observation

@Observable
@MainActor
final class PasteSequence {
    static let shared = PasteSequence()

    private(set) var queuedItems: [ClipItem] = []
    private(set) var isBuilding = false
    private(set) var isRunning = false

    var count: Int { queuedItems.count }

    private init() {}

    func begin() {
        queuedItems.removeAll()
        isRunning = false
        isBuilding = true
    }

    func toggle(_ item: ClipItem) {
        guard isBuilding else { return }
        if let index = queuedItems.firstIndex(where: { $0.id == item.id }) {
            queuedItems.remove(at: index)
        } else {
            queuedItems.append(item)
        }
    }

    func position(of item: ClipItem) -> Int? {
        queuedItems.firstIndex(where: { $0.id == item.id }).map { $0 + 1 }
    }

    func start() -> ClipItem? {
        guard isBuilding, !queuedItems.isEmpty else { return nil }
        isBuilding = false
        isRunning = true
        return takeNext()
    }

    func next() -> ClipItem? {
        guard isRunning else { return nil }
        return takeNext()
    }

    func cancel() {
        queuedItems.removeAll()
        isBuilding = false
        isRunning = false
    }

    private func takeNext() -> ClipItem? {
        guard !queuedItems.isEmpty else {
            isRunning = false
            return nil
        }
        let item = queuedItems.removeFirst()
        if queuedItems.isEmpty { isRunning = false }
        return item
    }
}
