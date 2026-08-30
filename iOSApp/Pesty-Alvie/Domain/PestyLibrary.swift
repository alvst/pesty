import Foundation

/// The newest deletion Undo would reverse: a clip (from the library or a
/// pinboard) or a whole pinboard with its copies.
enum PendingLibraryDeletion: Equatable, Sendable {
    case clip(PestyClip)
    case board(PestyBoard)

    var deletedAt: Date? {
        switch self {
        case .clip(let clip): clip.deletedAt
        case .board(let board): board.deletedAt
        }
    }
}

struct PestyLibrary: Codable, Sendable {
    static let currentSchemaVersion = 2
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
            .filter { !$0.isDeleted && $0.containerID == nil }
            .sorted { lhs, rhs in
                let lhsDate = lhs.lastUsedAt ?? lhs.capturedAt
                let rhsDate = rhs.lastUsedAt ?? rhs.capturedAt
                return lhsDate > rhsDate
            }
    }

    var allActiveClips: [PestyClip] {
        clips.filter { !$0.isDeleted }
    }

    var activeBoards: [PestyBoard] {
        boards
            .filter { !$0.isDeleted }
            .sorted {
                if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    func clip(id: UUID) -> PestyClip? {
        clips.first(where: { $0.id == id && !$0.isDeleted })
    }

    func board(id: UUID) -> PestyBoard? {
        boards.first(where: { $0.id == id && !$0.isDeleted })
    }

    func clips(in board: PestyBoard) -> [PestyClip] {
        let items = Dictionary(uniqueKeysWithValues: allActiveClips.map { ($0.id, $0) })
        return board.clipIDs.compactMap { items[$0] }
    }

    func containsEquivalent(_ clip: PestyClip, in board: PestyBoard) -> Bool {
        clips(in: board).contains { $0.hasSameContent(as: clip) }
    }

    /// The most recent deletion still inside its Undo window. A copy that
    /// belongs to a deleted pinboard is never offered on its own — undoing
    /// the pinboard brings its copies back with it.
    func undoableDeletion(
        at date: Date = .now,
        within undoInterval: TimeInterval = PestyLibrary.deletionUndoInterval
    ) -> PendingLibraryDeletion? {
        let deletedBoardIDs = Set(boards.filter(\.isDeleted).map(\.id))
        let clip = clips
            .filter { clip in
                guard let deletedAt = clip.deletedAt else { return false }
                if let containerID = clip.containerID, deletedBoardIDs.contains(containerID) { return false }
                return clip.deletionFinalizedAt == nil
                    && deletedAt.addingTimeInterval(undoInterval) > date
            }
            .max { ($0.deletedAt ?? .distantPast) < ($1.deletedAt ?? .distantPast) }
        let board = boards
            .filter { board in
                guard let deletedAt = board.deletedAt else { return false }
                return board.deletionFinalizedAt == nil
                    && deletedAt.addingTimeInterval(undoInterval) > date
            }
            .max { ($0.deletedAt ?? .distantPast) < ($1.deletedAt ?? .distantPast) }
        switch (clip, board) {
        case (nil, nil): return nil
        case (let clip?, nil): return .clip(clip)
        case (nil, let board?): return .board(board)
        case (let clip?, let board?):
            // A board's copies share its timestamp; at a tie the board is
            // what the user deleted.
            return (clip.deletedAt ?? .distantPast) > (board.deletedAt ?? .distantPast)
                ? .clip(clip) : .board(board)
        }
    }

    func undoableDeletedClip(
        at date: Date = .now,
        within undoInterval: TimeInterval = PestyLibrary.deletionUndoInterval
    ) -> PestyClip? {
        if case .clip(let clip)? = undoableDeletion(at: date, within: undoInterval) { return clip }
        return nil
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
        guard let index = clips.firstIndex(where: { $0.id == id && !$0.isDeleted }) else { return }
        clips[index].preDeletionUpdatedAt = clips[index].updatedAt
        let deletionDate = Self.timestampStrictlyAfter(clips[index].updatedAt, preferred: date)
        clips[index].deletedAt = deletionDate
        clips[index].deletionFinalizedAt = nil
        clips[index].updatedAt = deletionDate
        // Membership IDs remain in place while the tombstone hides the clip.
        // This makes an undo lossless and avoids unrelated board sync writes.
        updatedAt = max(updatedAt, deletionDate)
    }

    /// Soft-deletes a pinboard and its copies for the Undo window. Copies are
    /// stamped no earlier than the board, which is how undo later tells
    /// "deleted with the board" from "removed before that".
    mutating func deleteBoard(id: UUID, at date: Date = .now) {
        guard let index = boards.firstIndex(where: { $0.id == id && !$0.isDeleted }) else { return }
        let deletionDate = Self.timestampStrictlyAfter(boards[index].updatedAt, preferred: date)
        boards[index].preDeletionUpdatedAt = boards[index].updatedAt
        boards[index].deletedAt = deletionDate
        boards[index].deletionFinalizedAt = nil
        boards[index].updatedAt = deletionDate
        for clipIndex in clips.indices where clips[clipIndex].containerID == id && !clips[clipIndex].isDeleted {
            let clipDeletionDate = Self.timestampStrictlyAfter(clips[clipIndex].updatedAt, preferred: deletionDate)
            clips[clipIndex].preDeletionUpdatedAt = clips[clipIndex].updatedAt
            clips[clipIndex].deletedAt = clipDeletionDate
            clips[clipIndex].deletionFinalizedAt = nil
            clips[clipIndex].updatedAt = clipDeletionDate
        }
        updatedAt = max(updatedAt, deletionDate)
    }

    @discardableResult
    mutating func undoMostRecentDeletion(
        at date: Date = .now,
        within undoInterval: TimeInterval = PestyLibrary.deletionUndoInterval
    ) -> Bool {
        switch undoableDeletion(at: date, within: undoInterval) {
        case nil:
            return false
        case .clip(let deleted)?:
            guard let index = clips.firstIndex(where: { $0.id == deleted.id }) else { return false }
            restoreClip(at: index, on: date)
            return true
        case .board(let deleted)?:
            guard let index = boards.firstIndex(where: { $0.id == deleted.id }),
                  let deletedAt = boards[index].deletedAt else { return false }
            let undoDate = Self.timestampStrictlyAfter(boards[index].updatedAt, preferred: date)
            boards[index].deletedAt = nil
            boards[index].preDeletionUpdatedAt = nil
            boards[index].deletionFinalizedAt = nil
            boards[index].updatedAt = undoDate
            // Only the copies that went down with the board come back; a copy
            // removed before that stays removed (and stays undoable itself).
            for clipIndex in clips.indices
            where clips[clipIndex].containerID == deleted.id
                && (clips[clipIndex].deletedAt ?? .distantPast) >= deletedAt
                && clips[clipIndex].deletionFinalizedAt == nil {
                restoreClip(at: clipIndex, on: date)
            }
            updatedAt = max(updatedAt, undoDate)
            return true
        }
    }

    @discardableResult
    mutating func undoMostRecentClipDeletion(
        at date: Date = .now,
        within undoInterval: TimeInterval = PestyLibrary.deletionUndoInterval
    ) -> Bool {
        undoMostRecentDeletion(at: date, within: undoInterval)
    }

    private mutating func restoreClip(at index: Int, on date: Date) {
        let undoDate = Self.timestampStrictlyAfter(clips[index].updatedAt, preferred: date)
        clips[index].deletedAt = nil
        clips[index].preDeletionUpdatedAt = nil
        clips[index].deletionFinalizedAt = nil
        clips[index].updatedAt = undoDate
        updatedAt = max(updatedAt, undoDate)
    }

    @discardableResult
    mutating func add(clipID: UUID, to boardID: UUID, at date: Date = .now) -> UUID? {
        guard let boardIndex = boards.firstIndex(where: { $0.id == boardID && !$0.isDeleted }),
              let source = clip(id: clipID),
              !clips(in: boards[boardIndex]).contains(where: { $0.hasSameContent(as: source) }) else {
            return nil
        }
        // Re-pinning something removed moments ago revives that copy rather
        // than creating a twin that an Undo of the removal would duplicate.
        if let pendingIndex = clips.indices.first(where: {
            clips[$0].containerID == boardID
                && clips[$0].isDeleted
                && clips[$0].deletionFinalizedAt == nil
                && clips[$0].hasSameContent(as: source)
        }) {
            restoreClip(at: pendingIndex, on: date)
            let copyID = clips[pendingIndex].id
            if !boards[boardIndex].clipIDs.contains(copyID) {
                boards[boardIndex].clipIDs.insert(copyID, at: 0)
            }
            boards[boardIndex].updatedAt = date
            updatedAt = date
            return copyID
        }
        let copy = source.copied(to: boardID, at: date)
        clips.append(copy)
        boards[boardIndex].clipIDs.insert(copy.id, at: 0)
        boards[boardIndex].updatedAt = date
        updatedAt = date
        return copy.id
    }

    /// Removing a copy from a pinboard is a soft delete like any other: the
    /// membership stays in place under the tombstone so Undo is lossless.
    mutating func remove(clipID: UUID, from boardID: UUID, at date: Date = .now) {
        guard boards.contains(where: { $0.id == boardID && !$0.isDeleted }) else { return }
        guard let clipIndex = clips.firstIndex(where: { $0.id == clipID && $0.containerID == boardID }) else {
            return
        }
        clips[clipIndex].preDeletionUpdatedAt = clips[clipIndex].updatedAt
        let deletionDate = Self.timestampStrictlyAfter(clips[clipIndex].updatedAt, preferred: date)
        clips[clipIndex].deletedAt = deletionDate
        clips[clipIndex].deletionFinalizedAt = nil
        clips[clipIndex].updatedAt = deletionDate
        updatedAt = max(updatedAt, deletionDate)
    }

    mutating func applyRemoteDeletion(id: UUID, at date: Date = .now) {
        if let clipIndex = clips.firstIndex(where: { $0.id == id }) {
            let deletionDate = Self.timestampStrictlyAfter(clips[clipIndex].updatedAt, preferred: date)
            clips[clipIndex].deletedAt = deletionDate
            clips[clipIndex].updatedAt = deletionDate
            clips[clipIndex].preDeletionUpdatedAt = nil
            clips[clipIndex].deletionFinalizedAt = deletionDate
            for boardIndex in boards.indices {
                boards[boardIndex].clipIDs.removeAll { $0 == id }
                boards[boardIndex].pinnedClipIDs.removeAll { $0 == id }
            }
            updatedAt = max(updatedAt, deletionDate)
        }
        if let boardIndex = boards.firstIndex(where: { $0.id == id }) {
            let deletionDate = Self.timestampStrictlyAfter(boards[boardIndex].updatedAt, preferred: date)
            boards[boardIndex].deletedAt = deletionDate
            boards[boardIndex].updatedAt = deletionDate
            boards[boardIndex].deletionFinalizedAt = deletionDate
            for clipIndex in clips.indices where clips[clipIndex].containerID == id {
                let clipDeletionDate = Self.timestampStrictlyAfter(
                    clips[clipIndex].updatedAt,
                    preferred: deletionDate
                )
                clips[clipIndex].deletedAt = clipDeletionDate
                clips[clipIndex].updatedAt = clipDeletionDate
                clips[clipIndex].preDeletionUpdatedAt = nil
                clips[clipIndex].deletionFinalizedAt = clipDeletionDate
            }
            updatedAt = max(updatedAt, deletionDate)
        }
    }

    mutating func finalizeExpiredDeletions(at date: Date = .now) {
        for index in clips.indices {
            guard let deletedAt = clips[index].deletedAt,
                  clips[index].deletionFinalizedAt == nil,
                  deletedAt.addingTimeInterval(Self.deletionUndoInterval) <= date else { continue }
            clips[index].deletionFinalizedAt = date
            clips[index].preDeletionUpdatedAt = nil
        }
        for index in boards.indices {
            guard let deletedAt = boards[index].deletedAt,
                  boards[index].deletionFinalizedAt == nil,
                  deletedAt.addingTimeInterval(Self.deletionUndoInterval) <= date else { continue }
            boards[index].deletionFinalizedAt = date
            boards[index].preDeletionUpdatedAt = nil
        }
    }

    /// Last-writer-wins per entity, while preserving tombstones so a deletion
    /// made offline cannot be resurrected by the next device sync.
    func merged(with remote: PestyLibrary) -> PestyLibrary {
        var mergedClips = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        for candidate in remote.clips {
            if let current = mergedClips[candidate.id] {
                if Self.shouldReplace(current, with: candidate) {
                    mergedClips[candidate.id] = candidate
                }
            } else {
                mergedClips[candidate.id] = candidate
            }
        }

        var mergedBoards = Dictionary(uniqueKeysWithValues: boards.map { ($0.id, $0) })
        for candidate in remote.boards {
            if let current = mergedBoards[candidate.id] {
                if Self.shouldReplace(current, with: candidate) {
                    mergedBoards[candidate.id] = candidate
                }
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

    private static func shouldReplace(_ current: PestyClip, with candidate: PestyClip) -> Bool {
        if candidate.updatedAt != current.updatedAt { return candidate.updatedAt > current.updatedAt }
        if candidate.isDeleted != current.isDeleted { return candidate.isDeleted }
        if (candidate.deletionFinalizedAt != nil) != (current.deletionFinalizedAt != nil) {
            return candidate.deletionFinalizedAt != nil
        }
        return candidate.id.uuidString > current.id.uuidString
    }

    private static func shouldReplace(_ current: PestyBoard, with candidate: PestyBoard) -> Bool {
        if candidate.updatedAt != current.updatedAt { return candidate.updatedAt > current.updatedAt }
        if candidate.isDeleted != current.isDeleted { return candidate.isDeleted }
        if (candidate.deletionFinalizedAt != nil) != (current.deletionFinalizedAt != nil) {
            return candidate.deletionFinalizedAt != nil
        }
        return candidate.id.uuidString > current.id.uuidString
    }
}
