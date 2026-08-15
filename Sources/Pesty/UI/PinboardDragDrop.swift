import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let pestyPinboard = UTType(
        exportedAs: "com.greycorelabs.pesty.pinboard",
        conformingTo: .data
    )
}

struct PinboardDragItem: Codable, Equatable, Sendable, Transferable {
    let pinboardID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pestyPinboard)
    }
}

enum PinboardDropDestination: Equatable, Sendable {
    case over(UUID)
    /// Insert the dragged Pinboard immediately before/after this tab — used
    /// when the drop lands on the leading/trailing half of a tab (or in the
    /// gap next to it), so reordering reads as "insert between", the way
    /// tab bars conventionally behave, rather than "swap onto".
    case before(UUID)
    case after(UUID)
    /// The Add Pinboard button is a trailing target, never a draggable source.
    case end
}

/// Validates a decoded drop without mutating order. The caller applies the
/// returned move only from an accepted drop callback, so hover and cancellation
/// have no side effects.
enum PinboardDropDecision {
    static func move(
        draggedIDs: [UUID],
        destination: PinboardDropDestination,
        orderedIDs: [UUID]
    ) -> PinboardOrder.Move? {
        guard draggedIDs.count == 1,
              let draggedID = draggedIDs.first,
              orderedIDs.contains(draggedID) else { return nil }

        switch destination {
        case .over(let targetID):
            guard draggedID != targetID, orderedIDs.contains(targetID) else { return nil }
            return .over(id: draggedID, target: targetID)
        case .before(let targetID):
            guard draggedID != targetID, orderedIDs.contains(targetID) else { return nil }
            return .before(id: draggedID, target: targetID)
        case .after(let targetID):
            guard draggedID != targetID, orderedIDs.contains(targetID) else { return nil }
            return .after(id: draggedID, target: targetID)
        case .end:
            guard orderedIDs.last != draggedID else { return nil }
            return .toEnd(id: draggedID)
        }
    }
}
