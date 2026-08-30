import XCTest
@testable import Pesty

final class PestyLibraryTests: XCTestCase {
    func testMergeUsesNewestClipVersion() {
        let id = UUID()
        let earlier = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)
        let local = PestyLibrary(clips: [
            PestyClip(id: id, kind: .text, text: "Older", capturedAt: earlier, updatedAt: earlier)
        ])
        let remote = PestyLibrary(clips: [
            PestyClip(id: id, kind: .text, text: "Newer", capturedAt: earlier, updatedAt: later)
        ])

        let merged = local.merged(with: remote)

        XCTAssertEqual(merged.clip(id: id)?.text, "Newer")
    }

    func testDeletingClipHidesItWithoutDiscardingPinboardMembership() throws {
        let createdAt = Date(timeIntervalSince1970: 100)
        let deletedAt = Date(timeIntervalSince1970: 200)
        let clip = PestyClip(
            kind: .text,
            text: "Remove me",
            capturedAt: createdAt,
            updatedAt: createdAt
        )
        let board = PestyBoard(
            name: "Work",
            clipIDs: [clip.id],
            createdAt: createdAt,
            updatedAt: createdAt
        )
        var library = PestyLibrary(clips: [clip], boards: [board], updatedAt: createdAt)

        library.deleteClip(id: clip.id, at: deletedAt)

        XCTAssertNil(library.clip(id: clip.id))
        XCTAssertEqual(library.clips.first(where: { $0.id == clip.id })?.deletedAt, deletedAt)
        let activeBoard = try XCTUnwrap(library.board(id: board.id))
        XCTAssertTrue(activeBoard.clipIDs.contains(clip.id))
        XCTAssertTrue(library.clips(in: activeBoard).isEmpty)
        XCTAssertEqual(activeBoard.updatedAt, createdAt)
    }

    func testUndoClipDeletionRestoresMembershipWithNewerVersion() throws {
        let deletedAt = Date(timeIntervalSince1970: 200)
        let clip = PestyClip(
            kind: .text,
            text: "Bring me back",
            capturedAt: .distantPast,
            updatedAt: .distantPast
        )
        let board = PestyBoard(name: "Work", clipIDs: [clip.id])
        var library = PestyLibrary(clips: [clip], boards: [board])
        library.deleteClip(id: clip.id, at: deletedAt)

        XCTAssertTrue(library.undoMostRecentClipDeletion(at: deletedAt))

        let restored = try XCTUnwrap(library.clip(id: clip.id))
        XCTAssertNil(restored.deletedAt)
        XCTAssertGreaterThan(restored.updatedAt, deletedAt)
        XCTAssertEqual(library.clips(in: board).map(\.id), [clip.id])
    }

    func testClipDeletionExpiresAtFiveMinuteBoundary() {
        let deletedAt = Date(timeIntervalSince1970: 200)
        let expiresAt = deletedAt.addingTimeInterval(PestyLibrary.deletionUndoInterval)
        let clip = PestyClip(
            kind: .text,
            text: "Too late",
            capturedAt: deletedAt.addingTimeInterval(-10),
            updatedAt: deletedAt.addingTimeInterval(-10)
        )
        var library = PestyLibrary(clips: [clip])
        library.deleteClip(id: clip.id, at: deletedAt)

        XCTAssertNotNil(library.undoableDeletedClip(at: expiresAt.addingTimeInterval(-1)))
        XCTAssertNil(library.undoableDeletedClip(at: expiresAt))
        XCTAssertFalse(library.undoMostRecentClipDeletion(at: expiresAt))
        XCTAssertNil(library.clip(id: clip.id))
    }

    func testBoardDeletionIsUndoableForFiveMinutesAndBringsItsCopiesBack() throws {
        let deletedAt = Date(timeIntervalSince1970: 300)
        let boardID = UUID()
        let clip = PestyClip(containerID: boardID, kind: .text, text: "Pinned",
                             capturedAt: deletedAt.addingTimeInterval(-10),
                             updatedAt: deletedAt.addingTimeInterval(-10))
        let board = PestyBoard(
            id: boardID,
            name: "Saved",
            clipIDs: [clip.id],
            createdAt: deletedAt.addingTimeInterval(-10),
            updatedAt: deletedAt.addingTimeInterval(-10)
        )
        var library = PestyLibrary(clips: [clip], boards: [board])
        library.deleteBoard(id: board.id, at: deletedAt)

        XCTAssertNil(library.board(id: board.id))
        XCTAssertNil(library.boards.first?.deletionFinalizedAt)
        XCTAssertNil(library.clips.first?.deletionFinalizedAt)
        // The copy is not offered on its own; the board is what Undo restores.
        XCTAssertEqual(library.undoableDeletion(at: deletedAt.addingTimeInterval(299)), .board(library.boards[0]))
        XCTAssertNil(library.undoableDeletion(at: deletedAt.addingTimeInterval(300)))

        XCTAssertTrue(library.undoMostRecentDeletion(at: deletedAt.addingTimeInterval(60)))
        XCTAssertNotNil(library.board(id: board.id))
        XCTAssertEqual(library.clips(in: library.board(id: board.id)!).map(\.id), [clip.id])
        XCTAssertNil(library.undoableDeletion(at: deletedAt.addingTimeInterval(61)))
    }

    func testBoardDeletionExpiryFinalizesBoardAndCopies() {
        let deletedAt = Date(timeIntervalSince1970: 300)
        let boardID = UUID()
        let clip = PestyClip(containerID: boardID, kind: .text, text: "Pinned",
                             capturedAt: deletedAt.addingTimeInterval(-10),
                             updatedAt: deletedAt.addingTimeInterval(-10))
        let board = PestyBoard(id: boardID, name: "Saved", clipIDs: [clip.id],
                               createdAt: deletedAt.addingTimeInterval(-10),
                               updatedAt: deletedAt.addingTimeInterval(-10))
        var library = PestyLibrary(clips: [clip], boards: [board])
        library.deleteBoard(id: board.id, at: deletedAt)
        library.finalizeExpiredDeletions(at: deletedAt.addingTimeInterval(300))

        XCTAssertNotNil(library.boards.first?.deletionFinalizedAt)
        XCTAssertNotNil(library.clips.first?.deletionFinalizedAt)
        XCTAssertFalse(library.undoMostRecentDeletion(at: deletedAt.addingTimeInterval(301)))
    }

    func testRemovingACopyFromAPinboardIsUndoable() {
        let removedAt = Date(timeIntervalSince1970: 300)
        let boardID = UUID()
        let clip = PestyClip(containerID: boardID, kind: .text, text: "Pinned",
                             capturedAt: removedAt.addingTimeInterval(-10),
                             updatedAt: removedAt.addingTimeInterval(-10))
        let board = PestyBoard(id: boardID, name: "Saved", clipIDs: [clip.id],
                               createdAt: removedAt.addingTimeInterval(-10),
                               updatedAt: removedAt.addingTimeInterval(-10))
        var library = PestyLibrary(clips: [clip], boards: [board])
        library.remove(clipID: clip.id, from: boardID, at: removedAt)

        XCTAssertTrue(library.clips(in: library.board(id: boardID)!).isEmpty)
        XCTAssertEqual(library.undoableDeletion(at: removedAt.addingTimeInterval(1)), .clip(library.clips[0]))
        XCTAssertTrue(library.undoMostRecentDeletion(at: removedAt.addingTimeInterval(1)))
        XCTAssertEqual(library.clips(in: library.board(id: boardID)!).map(\.id), [clip.id])
    }

    func testRePinningARemovedCopyRevivesItInsteadOfDuplicating() {
        let removedAt = Date(timeIntervalSince1970: 300)
        let boardID = UUID()
        let source = PestyClip(kind: .text, text: "Pinned",
                               capturedAt: removedAt.addingTimeInterval(-10),
                               updatedAt: removedAt.addingTimeInterval(-10))
        let copy = PestyClip(containerID: boardID, kind: .text, text: "Pinned",
                             capturedAt: removedAt.addingTimeInterval(-10),
                             updatedAt: removedAt.addingTimeInterval(-10))
        let board = PestyBoard(id: boardID, name: "Saved", clipIDs: [copy.id],
                               createdAt: removedAt.addingTimeInterval(-10),
                               updatedAt: removedAt.addingTimeInterval(-10))
        var library = PestyLibrary(clips: [source, copy], boards: [board])
        library.remove(clipID: copy.id, from: boardID, at: removedAt)

        XCTAssertEqual(library.add(clipID: source.id, to: boardID, at: removedAt.addingTimeInterval(5)), copy.id)
        XCTAssertEqual(library.clips(in: library.board(id: boardID)!).map(\.id), [copy.id])
        XCTAssertEqual(library.clips.count, 2)
        XCTAssertNil(library.undoableDeletion(at: removedAt.addingTimeInterval(6)))
    }

    func testUndoRestorationWinsLastWriterMergeAgainstTombstone() throws {
        let clipID = UUID()
        let createdAt = Date(timeIntervalSince1970: 100)
        let deletedAt = Date(timeIntervalSince1970: 200)
        let undoAt = Date(timeIntervalSince1970: 250)
        var deletedLibrary = PestyLibrary(clips: [
            PestyClip(
                id: clipID,
                kind: .text,
                text: "Synced",
                capturedAt: createdAt,
                updatedAt: createdAt
            )
        ], updatedAt: createdAt)
        deletedLibrary.deleteClip(id: clipID, at: deletedAt)
        var restoredLibrary = deletedLibrary
        XCTAssertTrue(restoredLibrary.undoMostRecentClipDeletion(at: undoAt))

        let merged = deletedLibrary.merged(with: restoredLibrary)

        let restoredClip = try XCTUnwrap(merged.clip(id: clipID))
        XCTAssertGreaterThan(restoredClip.updatedAt, deletedAt)
    }

    func testRepeatedUndoRestoresMostRecentClipFirst() {
        let firstDeletion = Date(timeIntervalSince1970: 500)
        let secondDeletion = Date(timeIntervalSince1970: 550)
        let undoAt = Date(timeIntervalSince1970: 600)
        let createdAt = firstDeletion.addingTimeInterval(-10)
        let first = PestyClip(
            kind: .text,
            text: "First",
            capturedAt: createdAt,
            updatedAt: createdAt
        )
        let second = PestyClip(
            kind: .text,
            text: "Second",
            capturedAt: createdAt,
            updatedAt: createdAt
        )
        var library = PestyLibrary(clips: [first, second])
        library.deleteClip(id: first.id, at: firstDeletion)
        library.deleteClip(id: second.id, at: secondDeletion)

        XCTAssertEqual(library.undoableDeletedClip(at: undoAt)?.id, second.id)
        XCTAssertTrue(library.undoMostRecentClipDeletion(at: undoAt))
        XCTAssertNotNil(library.clip(id: second.id))
        XCTAssertEqual(library.undoableDeletedClip(at: undoAt)?.id, first.id)
        XCTAssertTrue(library.undoMostRecentClipDeletion(at: undoAt))
        XCTAssertNotNil(library.clip(id: first.id))
    }

    func testUndoAvailabilitySurvivesPersistenceRoundTrip() throws {
        let deletedAt = Date(timeIntervalSince1970: 400)
        let clip = PestyClip(
            kind: .text,
            text: "Persisted",
            capturedAt: deletedAt.addingTimeInterval(-10),
            updatedAt: deletedAt.addingTimeInterval(-10)
        )
        var library = PestyLibrary(clips: [clip])
        library.deleteClip(id: clip.id, at: deletedAt)

        let data = try JSONEncoder.pesty.encode(library)
        let restored = try JSONDecoder.pesty.decode(PestyLibrary.self, from: data)

        XCTAssertEqual(
            restored.undoableDeletedClip(at: deletedAt.addingTimeInterval(299))?.id,
            clip.id
        )
        XCTAssertNil(restored.undoableDeletedClip(at: deletedAt.addingTimeInterval(300)))
    }

    @MainActor
    func testStoreDerivesUndoAvailabilityFromPersistedTombstoneAndInjectedDate() {
        let deletedAt = Date(timeIntervalSince1970: 700)
        let clip = PestyClip(
            kind: .text,
            text: "Persisted store state",
            capturedAt: deletedAt.addingTimeInterval(-10),
            updatedAt: deletedAt.addingTimeInterval(-10)
        )
        var library = PestyLibrary(clips: [clip])
        library.deleteClip(id: clip.id, at: deletedAt)

        let undoableStore = LibraryStore(
            library: library,
            currentDate: { deletedAt.addingTimeInterval(299) }
        )
        let expiredStore = LibraryStore(
            library: library,
            currentDate: { deletedAt.addingTimeInterval(300) }
        )

        XCTAssertEqual(undoableStore.undoableDeletedClip?.id, clip.id)
        XCTAssertNil(expiredStore.undoableDeletedClip)
    }

    func testDeletionTombstonesAdvancePastPriorVersionsAndWinMerge() {
        let versionDate = Date(timeIntervalSince1970: 800)
        let clip = PestyClip(
            kind: .text,
            text: "Conflict-safe clip",
            capturedAt: versionDate,
            updatedAt: versionDate
        )
        let board = PestyBoard(
            name: "Conflict-safe board",
            clipIDs: [clip.id],
            createdAt: versionDate,
            updatedAt: versionDate
        )
        let active = PestyLibrary(
            clips: [clip],
            boards: [board],
            updatedAt: versionDate
        )
        var deleted = active

        deleted.deleteClip(id: clip.id, at: versionDate)
        deleted.deleteBoard(id: board.id, at: versionDate)

        XCTAssertGreaterThan(deleted.clips[0].updatedAt, versionDate)
        XCTAssertEqual(deleted.clips[0].deletedAt, deleted.clips[0].updatedAt)
        XCTAssertGreaterThan(deleted.boards[0].updatedAt, versionDate)
        XCTAssertEqual(deleted.boards[0].deletedAt, deleted.boards[0].updatedAt)
        let merged = active.merged(with: deleted)
        XCTAssertNil(merged.clip(id: clip.id))
        XCTAssertNil(merged.board(id: board.id))
    }

    func testMacStoreImportRepairsSharedClipIdentityDeterministically() throws {
        let clipID = UUID()
        let boardID = UUID()
        let document: [String: Any] = [
            "history": [[
                "id": clipID.uuidString,
                "type": "link",
                "text": "https://example.com/article",
                "fileURLs": [],
                "sourceAppName": "Safari",
                "createdAt": 0
            ]],
            "pinboards": [[
                "id": boardID.uuidString,
                "name": "Read Later",
                "colorHex": "#5B8DEF",
                "items": [[
                    "id": clipID.uuidString,
                    "type": "link",
                    "text": "https://example.com/article",
                    "fileURLs": [],
                    "sourceAppName": "Safari",
                    "createdAt": 0
                ]]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: document)

        let library = try MacPestyStoreImporter.library(from: data)

        let importedAgain = try MacPestyStoreImporter.library(from: data)
        let boardClipID = try XCTUnwrap(library.board(id: boardID)?.clipIDs.first)

        XCTAssertEqual(library.clip(id: clipID)?.displayTitle, "example.com")
        XCTAssertNotEqual(boardClipID, clipID)
        XCTAssertEqual(importedAgain.board(id: boardID)?.clipIDs, [boardClipID])
        XCTAssertEqual(library.clips(in: library.board(id: boardID)!).count, 1)
        XCTAssertEqual(library.clip(id: boardClipID)?.containerID, boardID)
    }

    func testAddingToTwoPinboardsCreatesContainerOwnedCopies() throws {
        let clip = PestyClip(kind: .text, text: "Reusable")
        let firstBoard = PestyBoard(name: "One")
        let secondBoard = PestyBoard(name: "Two")
        var library = PestyLibrary(clips: [clip], boards: [firstBoard, secondBoard])

        let firstCopyID = try XCTUnwrap(library.add(clipID: clip.id, to: firstBoard.id))
        let secondCopyID = try XCTUnwrap(library.add(clipID: clip.id, to: secondBoard.id))

        XCTAssertNotEqual(firstCopyID, clip.id)
        XCTAssertNotEqual(secondCopyID, clip.id)
        XCTAssertNotEqual(firstCopyID, secondCopyID)
        XCTAssertEqual(library.clip(id: firstCopyID)?.containerID, firstBoard.id)
        XCTAssertEqual(library.clip(id: secondCopyID)?.containerID, secondBoard.id)
    }

    func testEqualTimestampDeletionWinsMerge() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 900)
        let active = PestyClip(id: id, kind: .text, text: "Conflict", capturedAt: date, updatedAt: date)
        let deleted = PestyClip(
            id: id,
            kind: .text,
            text: "Conflict",
            capturedAt: date,
            updatedAt: date,
            deletedAt: date,
            deletionFinalizedAt: date
        )

        let merged = PestyLibrary(clips: [active]).merged(with: PestyLibrary(clips: [deleted]))

        XCTAssertNil(merged.clip(id: id))
        XCTAssertNotNil(merged.clips.first?.deletionFinalizedAt)
    }

    func testPendingDeletionProjectsLastActiveCloudRecordUntilExpiry() throws {
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let deletedAt = Date(timeIntervalSince1970: 2_000)
        let clip = PestyClip(
            kind: .text,
            text: "Grace period",
            capturedAt: createdAt,
            updatedAt: createdAt
        )
        var library = PestyLibrary(clips: [clip])

        library.deleteClip(id: clip.id, at: deletedAt)
        let deleted = try XCTUnwrap(library.clips.first)
        let projected = CloudSyncProjection.clip(deleted)

        XCTAssertNil(projected.deletedAt)
        XCTAssertEqual(projected.updatedAt, createdAt)
        XCTAssertEqual(projected.text, clip.text)
        XCTAssertEqual(deleted.deletedAt, deletedAt)
    }

    func testPinboardsUseSyncedSortOrder() {
        let first = PestyBoard(name: "Zulu", sortIndex: 0)
        let second = PestyBoard(name: "Alpha", sortIndex: 1)

        let library = PestyLibrary(boards: [second, first])

        XCTAssertEqual(library.activeBoards.map(\.id), [first.id, second.id])
    }
}
