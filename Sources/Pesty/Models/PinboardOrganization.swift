import Foundation

enum PinboardName {
    static func normalized(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

struct PinboardRenameSession: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case commit(String)
        case cancel(restoring: String)
        case keepEditing(refocus: Bool)
    }

    let boardID: UUID
    private(set) var baseline: String
    private(set) var draft: String

    var isDirty: Bool { draft != baseline }

    init(boardID: UUID, name: String) {
        self.boardID = boardID
        baseline = name
        draft = name
    }

    mutating func updateDraft(_ value: String) {
        draft = value
    }

    /// A clean field follows remote metadata. Once the user has typed, their
    /// draft wins while Escape/click-away cancellation follows the newest name.
    @discardableResult
    mutating func receiveRemoteName(_ name: String, for boardID: UUID) -> Bool {
        guard self.boardID == boardID else { return false }
        let wasDirty = isDirty
        baseline = name
        if !wasDirty { draft = name }
        return true
    }

    func returnPressed() -> Outcome {
        guard let name = PinboardName.normalized(draft) else {
            return .keepEditing(refocus: true)
        }
        return .commit(name)
    }

    func escapePressed() -> Outcome {
        .cancel(restoring: baseline)
    }

    func focusLost() -> Outcome {
        guard let name = PinboardName.normalized(draft) else {
            return .cancel(restoring: baseline)
        }
        return .commit(name)
    }
}
