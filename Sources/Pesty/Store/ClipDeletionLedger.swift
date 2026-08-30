import Foundation

/// The exact location of a clip before it was removed from clipboard history.
/// Keeping the index makes Undo restore the strip instead of moving the clip to
/// an arbitrary position.
struct HistoryClipPlacement: Codable {
    var index: Int
    var item: ClipItem
    var predecessorID: UUID? = nil
    var successorID: UUID? = nil
}

/// A pinboard can hold its own image-file copy of a clip, so the complete item
/// is retained rather than just its ID.
struct PinboardClipPlacement: Codable {
    var pinboardID: UUID
    var index: Int
    var item: ClipItem
    var predecessorID: UUID? = nil
    var successorID: UUID? = nil
}

/// Enough information to put a removed entry back into an existing stack, or
/// to recreate a stack that became empty when the entry was removed.
struct PasteStackEntryPlacement: Codable {
    var stackID: UUID
    var stackCreatedAt: Date
    var stackUpdatedAt: Date
    var index: Int
    var entry: PasteStackEntry
    var predecessorEntryID: UUID? = nil
    var successorEntryID: UUID? = nil
}

/// The comparatively large, short-lived part of a deletion record. It is
/// discarded when the Undo window closes; the small sync marker remains.
struct ClipDeletionPayload: Codable {
    var history: [HistoryClipPlacement]
    var pinboards: [PinboardClipPlacement]
    var pasteStackEntries: [PasteStackEntryPlacement]

    var allItems: [ClipItem] {
        history.map(\.item)
            + pinboards.map(\.item)
            + pasteStackEntries.map { $0.entry.item }
    }
}

struct ClipItemRestoration {
    var deletionPayload: ClipDeletionPayload?
}

/// A pinboard the user deleted, kept whole until its Undo window closes.
/// Unlike a clip, a pinboard has no durable tombstone of its own: while it is
/// pending it simply stays out of `pinboards`, and sync still publishes it so
/// other devices do not act on a deletion that may yet be undone.
struct PendingPinboardDeletion: Codable, Identifiable {
    var board: Pinboard
    var deletedAt: Date

    var id: UUID { board.id }
    var expiresAt: Date { deletedAt.addingTimeInterval(ClipDeletionLedger.undoWindow) }
    func isUndoable(at date: Date) -> Bool { date < expiresAt }
}

/// A durable last-writer-wins marker for one clip ID. Restored records remain
/// in the ledger so an older tombstone arriving from iCloud cannot delete the
/// item again. Finalized deletion records likewise prevent stale live items
/// from being resurrected after the Undo payload has been discarded.
struct ClipDeletionRecord: Identifiable, Codable {
    let id: UUID
    let operationID: UUID
    var deletedAt: Date
    var restoredAt: Date?
    var finalizedAt: Date?
    var removesFromPasteStacks: Bool
    var payload: ClipDeletionPayload?

    var isDeleted: Bool { restoredAt == nil }

    var presenceChangedAt: Date {
        restoredAt ?? deletedAt
    }
}

struct ClipDeletionLedger: Codable {
    static let undoWindow: TimeInterval = 5 * 60

    private(set) var records: [ClipDeletionRecord] = []

    var deletedIDs: Set<UUID> {
        Set(records.lazy.filter(\.isDeleted).map(\.id))
    }

    var deletedPasteStackItemIDs: Set<UUID> {
        Set(records.lazy
            .filter { $0.isDeleted && $0.removesFromPasteStacks }
            .map(\.id))
    }

    mutating func recordDeletion(id: UUID,
                                 payload: ClipDeletionPayload,
                                 removesFromPasteStacks: Bool = false,
                                 at date: Date) {
        let previousChange = records
            .filter { $0.id == id }
            .map(\.presenceChangedAt)
            .max()
        let deletionDate = max(date, previousChange?.addingTimeInterval(0.000_001) ?? date)
        let record = ClipDeletionRecord(
            id: id,
            operationID: UUID(),
            deletedAt: deletionDate,
            restoredAt: nil,
            finalizedAt: nil,
            removesFromPasteStacks: removesFromPasteStacks,
            payload: payload
        )
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    /// A downloaded live record may supersede an older local deletion marker.
    /// Keeping that newer active marker prevents an iCloud Drive snapshot or
    /// delayed CloudKit change from immediately deleting it again.
    mutating func acceptRemotePresence(id: UUID, at date: Date) {
        guard let index = records.firstIndex(where: { $0.id == id }),
              date > records[index].presenceChangedAt else { return }
        records[index].restoredAt = date
        records[index].finalizedAt = nil
        records[index].payload = nil
    }

    /// CloudKit hard deletions are final and never enter the local Undo UI.
    mutating func recordRemoteDeletion(id: UUID,
                                       removesFromPasteStacks: Bool,
                                       at date: Date) {
        let previousChange = records
            .filter { $0.id == id }
            .map(\.presenceChangedAt)
            .max()
        let deletionDate = max(date, previousChange?.addingTimeInterval(0.000_001) ?? date)
        let record = ClipDeletionRecord(
            id: id,
            operationID: UUID(),
            deletedAt: deletionDate,
            restoredAt: nil,
            finalizedAt: deletionDate,
            removesFromPasteStacks: removesFromPasteStacks,
            payload: nil
        )
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    mutating func finalizePendingHistoryDeletions(at date: Date) -> [ClipDeletionPayload] {
        finalizePending(at: date) { payload in !payload.history.isEmpty }
    }

    mutating func finalizePendingDeletions(inPinboard id: UUID,
                                           at date: Date) -> [ClipDeletionPayload] {
        finalizePending(at: date) { payload in
            payload.pinboards.contains(where: { $0.pinboardID == id })
        }
    }

    func permitsRemotePresence(id: UUID, updatedAt: Date) -> Bool {
        guard let record = records.first(where: { $0.id == id }) else { return true }
        if record.presenceChangedAt != updatedAt {
            return updatedAt > record.presenceChangedAt
        }
        return !record.isDeleted
    }

    private mutating func finalizePending(
        at date: Date,
        where matches: (ClipDeletionPayload) -> Bool
    ) -> [ClipDeletionPayload] {
        var finalized: [ClipDeletionPayload] = []
        for index in records.indices {
            guard records[index].isDeleted,
                  records[index].finalizedAt == nil,
                  let payload = records[index].payload,
                  matches(payload) else { continue }
            finalized.append(payload)
            records[index].payload = nil
            records[index].finalizedAt = max(date, records[index].deletedAt)
        }
        return finalized
    }

    /// A clip retained in a Paste Stack can be copied back into history after
    /// deletion. That explicit recapture publishes a newer active marker for
    /// the same entity instead of letting the tombstone remove it on relaunch.
    mutating func restoreItemIfNeeded(_ id: UUID, at date: Date) -> ClipItemRestoration? {
        guard let index = records.firstIndex(where: { $0.id == id && $0.isDeleted }) else { return nil }
        let payload = records[index].payload
        let activeDate = max(
            date,
            records[index].presenceChangedAt.addingTimeInterval(0.000_001)
        )
        records[index].restoredAt = activeDate
        records[index].finalizedAt = nil
        records[index].payload = nil
        return ClipItemRestoration(deletionPayload: payload)
    }

    func hasUndoableDeletion(at date: Date) -> Bool {
        latestUndoableIndex(at: date) != nil
    }

    /// When the newest still-undoable clip deletion happened, so the store
    /// can decide whether a pending pinboard deletion is more recent.
    func latestUndoableDeletionDate(at date: Date) -> Date? {
        latestUndoableIndex(at: date).map { records[$0].deletedAt }
    }

    func nextExpirationDate(after date: Date) -> Date? {
        records.lazy
            .filter { isUndoable($0, at: date) }
            .map { $0.deletedAt.addingTimeInterval(Self.undoWindow) }
            .min()
    }

    /// Restores the newest still-undoable deletion. Older independent deletes
    /// remain available, giving repeated presses conventional LIFO behavior.
    mutating func undoMostRecent(at date: Date) -> (id: UUID, payload: ClipDeletionPayload)? {
        guard let index = latestUndoableIndex(at: date),
              let payload = records[index].payload else { return nil }
        let id = records[index].id
        records[index].restoredAt = max(
            date,
            records[index].presenceChangedAt.addingTimeInterval(0.000_001)
        )
        records[index].finalizedAt = nil
        records[index].payload = nil
        return (id, payload)
    }

    /// Drops expired Undo payloads but intentionally retains their tombstones.
    /// The returned payloads identify image files that may now be unlinked.
    mutating func finalizeExpired(at date: Date) -> [ClipDeletionPayload] {
        var finalized: [ClipDeletionPayload] = []
        for index in records.indices {
            guard records[index].isDeleted,
                  records[index].finalizedAt == nil,
                  date >= records[index].deletedAt.addingTimeInterval(Self.undoWindow) else {
                continue
            }
            if let payload = records[index].payload { finalized.append(payload) }
            records[index].payload = nil
            records[index].finalizedAt = date
        }
        return finalized
    }

    /// Merges sync metadata independently of the live item arrays. At equal
    /// timestamps, deletion/finalization wins to avoid accidental resurrection.
    mutating func merge(_ other: ClipDeletionLedger) {
        for candidate in other.records {
            guard let index = records.firstIndex(where: { $0.id == candidate.id }) else {
                records.append(candidate)
                continue
            }
            if shouldReplace(records[index], with: candidate) {
                records[index] = candidate
            }
        }
    }

    func retainsImageFile(named name: String) -> Bool {
        records.contains { record in
            record.payload?.allItems.contains(where: { $0.imageFileName == name }) == true
        }
    }

    private func latestUndoableIndex(at date: Date) -> Int? {
        records.indices
            .filter { isUndoable(records[$0], at: date) }
            .max { records[$0].deletedAt < records[$1].deletedAt }
    }

    private func isUndoable(_ record: ClipDeletionRecord, at date: Date) -> Bool {
        record.isDeleted
            && record.finalizedAt == nil
            && record.payload != nil
            && date < record.deletedAt.addingTimeInterval(Self.undoWindow)
    }

    private func shouldReplace(_ current: ClipDeletionRecord,
                               with candidate: ClipDeletionRecord) -> Bool {
        if candidate.presenceChangedAt != current.presenceChangedAt {
            return candidate.presenceChangedAt > current.presenceChangedAt
        }
        if candidate.isDeleted != current.isDeleted {
            return candidate.isDeleted
        }
        if candidate.operationID != current.operationID {
            return candidate.operationID.uuidString > current.operationID.uuidString
        }
        if (candidate.finalizedAt != nil) != (current.finalizedAt != nil) {
            return candidate.finalizedAt != nil
        }
        if let candidateFinalizedAt = candidate.finalizedAt,
           let currentFinalizedAt = current.finalizedAt,
           candidateFinalizedAt != currentFinalizedAt {
            return candidateFinalizedAt > currentFinalizedAt
        }
        if (candidate.payload == nil) != (current.payload == nil) {
            return candidate.payload == nil
        }
        return false
    }

}
