import Foundation

struct PestyLibrary: Codable, Sendable {
    static let currentSchemaVersion = 1
    static let deletionUndoInterval: TimeInterval = 5 * 60

    var schemaVersion: Int
    var clips: [PestyClip]
    var boards: [PestyBoard]
    var updatedAt: Date

    init(
        schemaVersion: Int = PestyLibrary.currentSchemaVersion,
        clips: [PestyClip] = [],
        boards: [PestyBoard] = [],
        updatedAt: Date = .now
    ) {
        self.schemaVersion = schemaVersion
        self.clips = clips
        self.boards = boards
        self.updatedAt = updatedAt
    }

    var activeClips: [PestyClip] {
        clips
            .filter { !$0.isDeleted }
            .sorted { lhs, rhs in
                let lhsDate = lhs.lastUsedAt ?? lhs.capturedAt
                let rhsDate = rhs.lastUsedAt ?? rhs.capturedAt
                return lhsDate > rhsDate
            }
    }

    var activeBoards: [PestyBoard] {
        boards
            .filter { !$0.isDeleted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func clip(id: UUID) -> PestyClip? {
        clips.first(where: { $0.id == id && !$0.isDeleted })
    }

    func board(id: UUID) -> PestyBoard? {
        boards.first(where: { $0.id == id && !$0.isDeleted })
    }

    func clips(in board: PestyBoard) -> [PestyClip] {
        let items = Dictionary(uniqueKeysWithValues: activeClips.map { ($0.id, $0) })
        return board.clipIDs.compactMap { items[$0] }
    }

    func undoableDeletedClip(
        at date: Date = .now,
        within undoInterval: TimeInterval = PestyLibrary.deletionUndoInterval
    ) -> PestyClip? {
        clips
            .filter { clip in
                guard let deletedAt = clip.deletedAt else { return false }
                return deletedAt.addingTimeInterval(undoInterval) > date
            }
            .max { ($0.deletedAt ?? .distantPast) < ($1.deletedAt ?? .distantPast) }
    }

    func undoableDeletedBoard(
        at date: Date = .now,
        within undoInterval: TimeInterval = PestyLibrary.deletionUndoInterval
    ) -> PestyBoard? {
        boards
            .filter { board in
                guard let deletedAt = board.deletedAt else { return false }
                return deletedAt.addingTimeInterval(undoInterval) > date
            }
            .max { ($0.deletedAt ?? .distantPast) < ($1.deletedAt ?? .distantPast) }
    }

    mutating func upsert(_ clip: PestyClip) {
        if let index = clips.firstIndex(where: { $0.id == clip.id }) {
            clips[index] = clip
        } else {
            clips.append(clip)
        }
        updatedAt = .now
    }

    mutating func upsert(_ board: PestyBoard) {
        if let index = boards.firstIndex(where: { $0.id == board.id }) {
            boards[index] = board
        } else {
            boards.append(board)
        }
        updatedAt = .now
    }

    mutating func deleteClip(id: UUID, at date: Date = .now) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let deletionDate = Self.timestampStrictlyAfter(clips[index].updatedAt, preferred: date)
        clips[index].deletedAt = deletionDate
        clips[index].updatedAt = deletionDate
        // Membership IDs remain in place while the tombstone hides the clip.
        // This makes an undo lossless and avoids unrelated board sync writes.
        updatedAt = max(updatedAt, deletionDate)
    }

    mutating func deleteBoard(id: UUID, at date: Date = .now) {
        guard let index = boards.firstIndex(where: { $0.id == id }) else { return }
        let deletionDate = Self.timestampStrictlyAfter(boards[index].updatedAt, preferred: date)
        boards[index].deletedAt = deletionDate
        boards[index].updatedAt = deletionDate
        updatedAt = max(updatedAt, deletionDate)
    }

    @discardableResult
    mutating func undoMostRecentClipDeletion(
        at date: Date = .now,
        within undoInterval: TimeInterval = PestyLibrary.deletionUndoInterval
    ) -> Bool {
        guard let deleted = undoableDeletedClip(at: date, within: undoInterval),
              let index = clips.firstIndex(where: { $0.id == deleted.id }) else { return false }
        let undoDate = Self.timestampStrictlyAfter(clips[index].updatedAt, preferred: date)
        clips[index].deletedAt = nil
        clips[index].updatedAt = undoDate
        updatedAt = max(updatedAt, undoDate)
        return true
    }

    @discardableResult
    mutating func undoMostRecentBoardDeletion(
        at date: Date = .now,
        within undoInterval: TimeInterval = PestyLibrary.deletionUndoInterval
    ) -> Bool {
        guard let deleted = undoableDeletedBoard(at: date, within: undoInterval),
              let index = boards.firstIndex(where: { $0.id == deleted.id }) else { return false }
        let undoDate = Self.timestampStrictlyAfter(boards[index].updatedAt, preferred: date)
        boards[index].deletedAt = nil
        boards[index].updatedAt = undoDate
        updatedAt = max(updatedAt, undoDate)
        return true
    }

    mutating func add(clipID: UUID, to boardID: UUID, at date: Date = .now) {
        guard let index = boards.firstIndex(where: { $0.id == boardID && !$0.isDeleted }),
              !boards[index].clipIDs.contains(clipID) else { return }
        boards[index].clipIDs.insert(clipID, at: 0)
        boards[index].updatedAt = date
        updatedAt = date
    }

    mutating func remove(clipID: UUID, from boardID: UUID, at date: Date = .now) {
        guard let index = boards.firstIndex(where: { $0.id == boardID && !$0.isDeleted }) else { return }
        boards[index].clipIDs.removeAll { $0 == clipID }
        boards[index].updatedAt = date
        updatedAt = date
    }

    /// Last-writer-wins per entity, while preserving tombstones so a deletion
    /// made offline cannot be resurrected by the next device sync.
    func merged(with remote: PestyLibrary) -> PestyLibrary {
        var mergedClips = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        for candidate in remote.clips {
            if let current = mergedClips[candidate.id] {
                if candidate.updatedAt > current.updatedAt { mergedClips[candidate.id] = candidate }
            } else {
                mergedClips[candidate.id] = candidate
            }
        }

        var mergedBoards = Dictionary(uniqueKeysWithValues: boards.map { ($0.id, $0) })
        for candidate in remote.boards {
            if let current = mergedBoards[candidate.id] {
                if candidate.updatedAt > current.updatedAt { mergedBoards[candidate.id] = candidate }
            } else {
                mergedBoards[candidate.id] = candidate
            }
        }

        return PestyLibrary(
            schemaVersion: max(schemaVersion, remote.schemaVersion),
            clips: Array(mergedClips.values),
            boards: Array(mergedBoards.values),
            updatedAt: max(updatedAt, remote.updatedAt)
        )
    }

    private static func timestampStrictlyAfter(_ current: Date, preferred: Date) -> Date {
        // The JSON persistence format uses whole-second ISO-8601 dates, so one
        // full second guarantees the restored version remains newer on reload.
        max(preferred, current.addingTimeInterval(1))
    }
}
