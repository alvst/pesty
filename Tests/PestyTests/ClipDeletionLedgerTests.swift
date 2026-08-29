import XCTest
@testable import Pesty

final class ClipDeletionLedgerTests: XCTestCase {
    private let deletedAt = Date(timeIntervalSince1970: 1_000)

    func testUndoIsAvailableUntilButNotIncludingFiveMinuteDeadline() {
        let item = ClipItem(type: .text, text: "Undo me", createdAt: deletedAt)
        var ledger = ClipDeletionLedger()
        ledger.recordDeletion(id: item.id, payload: payload(for: item), at: deletedAt)

        XCTAssertTrue(ledger.hasUndoableDeletion(
            at: deletedAt.addingTimeInterval(ClipDeletionLedger.undoWindow - 0.001)
        ))
        XCTAssertFalse(ledger.hasUndoableDeletion(
            at: deletedAt.addingTimeInterval(ClipDeletionLedger.undoWindow)
        ))
    }

    func testUndoReturnsPayloadAndWritesANewerActiveMarker() {
        let item = ClipItem(type: .text, text: "Undo me", createdAt: deletedAt)
        var ledger = ClipDeletionLedger()
        ledger.recordDeletion(id: item.id, payload: payload(for: item), at: deletedAt)
        let restoredAt = deletedAt.addingTimeInterval(299)

        let deletion = ledger.undoMostRecent(at: restoredAt)

        XCTAssertEqual(deletion?.id, item.id)
        XCTAssertEqual(deletion?.payload.history.first?.item, item)
        XCTAssertFalse(ledger.deletedIDs.contains(item.id))
        XCTAssertEqual(ledger.records.first?.restoredAt, restoredAt)
        XCTAssertNil(ledger.records.first?.payload)
    }

    func testExpiryDropsPayloadButRetainsSyncTombstone() {
        let item = ClipItem(type: .image, imageFileName: "retained.png", createdAt: deletedAt)
        var ledger = ClipDeletionLedger()
        ledger.recordDeletion(id: item.id, payload: payload(for: item), at: deletedAt)

        let finalized = ledger.finalizeExpired(
            at: deletedAt.addingTimeInterval(ClipDeletionLedger.undoWindow)
        )

        XCTAssertEqual(finalized.first?.allItems.first, item)
        XCTAssertTrue(ledger.deletedIDs.contains(item.id))
        XCTAssertNil(ledger.records.first?.payload)
        XCTAssertNotNil(ledger.records.first?.finalizedAt)
    }

    func testLateFinalizationOfOldDeleteCannotBeatNewerUndo() {
        let item = ClipItem(type: .text, text: "Keep restored", createdAt: deletedAt)
        var pendingDelete = ClipDeletionLedger()
        pendingDelete.recordDeletion(id: item.id, payload: payload(for: item), at: deletedAt)

        var restored = pendingDelete
        _ = restored.undoMostRecent(at: deletedAt.addingTimeInterval(299))

        var finalizedOnAnotherDevice = pendingDelete
        _ = finalizedOnAnotherDevice.finalizeExpired(at: deletedAt.addingTimeInterval(300))
        restored.merge(finalizedOnAnotherDevice)

        XCTAssertFalse(restored.deletedIDs.contains(item.id))
        XCTAssertNotNil(restored.records.first?.restoredAt)
    }

    func testNewerDeleteBeatsOlderRestoration() {
        let item = ClipItem(type: .text, text: "Delete again", createdAt: deletedAt)
        var restored = ClipDeletionLedger()
        restored.recordDeletion(id: item.id, payload: payload(for: item), at: deletedAt)
        _ = restored.undoMostRecent(at: deletedAt.addingTimeInterval(10))

        var newerDelete = ClipDeletionLedger()
        newerDelete.recordDeletion(
            id: item.id,
            payload: payload(for: item),
            at: deletedAt.addingTimeInterval(20)
        )
        restored.merge(newerDelete)

        XCTAssertTrue(restored.deletedIDs.contains(item.id))
    }

    func testRepeatedUndoRestoresNewestDeletionFirst() {
        let first = ClipItem(type: .text, text: "First", createdAt: deletedAt)
        let second = ClipItem(type: .text, text: "Second", createdAt: deletedAt)
        var ledger = ClipDeletionLedger()
        ledger.recordDeletion(id: first.id, payload: payload(for: first), at: deletedAt)
        ledger.recordDeletion(
            id: second.id,
            payload: payload(for: second),
            at: deletedAt.addingTimeInterval(20)
        )

        let undoDate = deletedAt.addingTimeInterval(30)
        XCTAssertEqual(ledger.undoMostRecent(at: undoDate)?.id, second.id)
        XCTAssertEqual(ledger.undoMostRecent(at: undoDate)?.id, first.id)
        XCTAssertFalse(ledger.hasUndoableDeletion(at: undoDate))
    }

    func testRecapturingSameIDFromRetainedStackPublishesActiveMarker() {
        let item = ClipItem(type: .text, text: "Retained in stack", createdAt: deletedAt)
        var ledger = ClipDeletionLedger()
        ledger.recordDeletion(
            id: item.id,
            payload: payload(for: item),
            removesFromPasteStacks: false,
            at: deletedAt
        )

        XCTAssertNotNil(ledger.restoreItemIfNeeded(item.id, at: deletedAt.addingTimeInterval(20)))
        XCTAssertFalse(ledger.deletedIDs.contains(item.id))
    }

    func testPendingDeletionSurvivesCodableRoundTrip() throws {
        let item = ClipItem(type: .link, text: "https://example.com", createdAt: deletedAt)
        var original = ClipDeletionLedger()
        original.recordDeletion(id: item.id, payload: payload(for: item), at: deletedAt)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClipDeletionLedger.self, from: data)

        XCTAssertTrue(decoded.hasUndoableDeletion(at: deletedAt.addingTimeInterval(120)))
        XCTAssertEqual(decoded.records.first?.payload?.history.first?.item, item)
    }

    func testRemoteDeletionIsFinalAndNeverUndoable() {
        let item = ClipItem(type: .text, text: "Remote delete", createdAt: deletedAt)
        var ledger = ClipDeletionLedger()

        ledger.recordRemoteDeletion(id: item.id, removesFromPasteStacks: true, at: deletedAt)

        XCTAssertTrue(ledger.deletedIDs.contains(item.id))
        XCTAssertFalse(ledger.hasUndoableDeletion(at: deletedAt))
        XCTAssertNil(ledger.records.first?.payload)
        XCTAssertNotNil(ledger.records.first?.finalizedAt)
    }

    func testNewerRemotePresenceSupersedesOlderFinalTombstone() {
        let item = ClipItem(type: .text, text: "Remote restore", createdAt: deletedAt)
        var ledger = ClipDeletionLedger()
        ledger.recordRemoteDeletion(id: item.id, removesFromPasteStacks: false, at: deletedAt)
        let restoredAt = deletedAt.addingTimeInterval(10)

        XCTAssertTrue(ledger.permitsRemotePresence(id: item.id, updatedAt: restoredAt))
        ledger.acceptRemotePresence(id: item.id, at: restoredAt)

        XCTAssertFalse(ledger.deletedIDs.contains(item.id))
    }

    func testImmediateHistoryMaintenanceFinalizesPendingUndo() {
        let item = ClipItem(type: .text, text: "Clear me", createdAt: deletedAt)
        var ledger = ClipDeletionLedger()
        ledger.recordDeletion(id: item.id, payload: payload(for: item), at: deletedAt)

        let finalized = ledger.finalizePendingHistoryDeletions(
            at: deletedAt.addingTimeInterval(10)
        )

        XCTAssertEqual(finalized.first?.history.first?.item.id, item.id)
        XCTAssertFalse(ledger.hasUndoableDeletion(at: deletedAt.addingTimeInterval(10)))
        XCTAssertNotNil(ledger.records.first?.finalizedAt)
    }

    private func payload(for item: ClipItem) -> ClipDeletionPayload {
        ClipDeletionPayload(
            history: [HistoryClipPlacement(index: 0, item: item)],
            pinboards: [],
            pasteStackEntries: []
        )
    }
}
