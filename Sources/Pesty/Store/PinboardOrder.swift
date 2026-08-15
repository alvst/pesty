import Foundation

/// Device-local presentation order for Pinboards.
///
/// This stays independent of the Pinboard model and sync schema so incoming
/// arrays can be reconciled without letting their arrival order overwrite the
/// order chosen on this Mac.
struct PinboardOrder: Equatable, Sendable {
    enum Move: Equatable, Sendable {
        case before(id: UUID, target: UUID)
        case after(id: UUID, target: UUID)
        case over(id: UUID, target: UUID)
        case by(id: UUID, offset: Int)
        case toEnd(id: UUID)
    }

    private(set) var ids: [UUID]

    init(ids: [UUID] = []) {
        self.ids = Self.uniqued(ids)
    }

    /// Preserves known relative order, removes missing IDs, and appends newly
    /// discovered Pinboards in an order independent of delivery timing.
    @discardableResult
    mutating func reconcile(existingIDs: [UUID]) -> Bool {
        let existing = Set(existingIDs)
        var seen = Set<UUID>()
        var reconciled = ids.filter {
            existing.contains($0) && seen.insert($0).inserted
        }
        reconciled += existing
            .subtracting(seen)
            .sorted { $0.uuidString < $1.uuidString }

        guard reconciled != ids else { return false }
        ids = reconciled
        return true
    }

    @discardableResult
    mutating func perform(_ proposal: Move) -> Bool {
        switch proposal {
        case let .before(id, target):
            return move(id, before: target)
        case let .after(id, target):
            return move(id, after: target)
        case let .over(id, target):
            return move(id, over: target)
        case let .by(id, offset):
            return move(id, by: offset)
        case let .toEnd(id):
            return moveToEnd(id)
        }
    }

    @discardableResult
    mutating func move(_ id: UUID, before target: UUID) -> Bool {
        move(id, relativeTo: target, placeAfterTarget: false)
    }

    @discardableResult
    mutating func move(_ id: UUID, after target: UUID) -> Bool {
        move(id, relativeTo: target, placeAfterTarget: true)
    }

    /// Moving right lands after the hovered tab; moving left lands before it.
    @discardableResult
    mutating func move(_ id: UUID, over target: UUID) -> Bool {
        guard let sourceIndex = ids.firstIndex(of: id),
              let targetIndex = ids.firstIndex(of: target),
              sourceIndex != targetIndex else { return false }
        return move(id, relativeTo: target, placeAfterTarget: sourceIndex < targetIndex)
    }

    @discardableResult
    mutating func move(_ id: UUID, by offset: Int) -> Bool {
        guard offset != 0,
              let sourceIndex = ids.firstIndex(of: id),
              !ids.isEmpty else { return false }
        let (unclamped, overflowed) = sourceIndex.addingReportingOverflow(offset)
        let destination: Int
        if overflowed {
            destination = offset < 0 ? 0 : ids.count - 1
        } else {
            destination = min(ids.count - 1, max(0, unclamped))
        }
        guard destination != sourceIndex else { return false }

        ids.remove(at: sourceIndex)
        ids.insert(id, at: min(destination, ids.endIndex))
        return true
    }

    @discardableResult
    mutating func moveToEnd(_ id: UUID) -> Bool {
        guard let index = ids.firstIndex(of: id),
              index != ids.index(before: ids.endIndex) else { return false }
        ids.remove(at: index)
        ids.append(id)
        return true
    }

    private mutating func move(
        _ id: UUID,
        relativeTo target: UUID,
        placeAfterTarget: Bool
    ) -> Bool {
        guard id != target, ids.contains(id), ids.contains(target) else { return false }

        var reordered = ids
        reordered.removeAll { $0 == id }
        guard let targetIndex = reordered.firstIndex(of: target) else { return false }
        let insertionIndex = placeAfterTarget ? reordered.index(after: targetIndex) : targetIndex
        reordered.insert(id, at: insertionIndex)
        guard reordered != ids else { return false }
        ids = reordered
        return true
    }

    private static func uniqued(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }
}

/// Stores only UUID strings in the app's device-local defaults store, kept
/// independent of the Pinboard model and sync schema.
@MainActor
final class PinboardOrderPreference {
    static let key = "pinboardOrder"

    private let defaults = UserDefaults.standard

    var hasStoredOrder: Bool {
        defaults.object(forKey: Self.key) != nil
    }

    func load() -> PinboardOrder {
        let strings = defaults.stringArray(forKey: Self.key) ?? []
        return PinboardOrder(ids: strings.compactMap(UUID.init(uuidString:)))
    }

    func save(_ order: PinboardOrder) {
        defaults.set(order.ids.map(\.uuidString), forKey: Self.key)
    }
}
