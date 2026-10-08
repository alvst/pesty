import CloudKit
import XCTest
@testable import Pesty

final class CloudRecordCodecTests: XCTestCase {
    func testClipRecordRoundTripPreservesPortableMetadata() throws {
        let boardID = UUID()
        let date = Date(timeIntervalSince1970: 1_234)
        let item = ClipItem(
            type: .richText,
            text: "Hello",
            rtfData: Data("rtf".utf8),
            imageHash: "abc123",
            fileURLs: ["file://$HOME/report.pdf"],
            colorHex: "#AABBCC",
            sourceBundleID: "com.apple.Notes",
            sourceAppName: "Notes",
            sourceDeviceName: "Mac",
            customTitle: "Greeting",
            createdAt: date,
            updatedAt: date.addingTimeInterval(10),
            lastUsedAt: date.addingTimeInterval(20)
        )
        let record = CKRecord(
            recordType: CKSchema.clipType,
            recordID: CKSchema.recordID(item.id.uuidString)
        )

        CloudRecordCodec.populate(
            record,
            from: item,
            container: boardID.uuidString,
            imageFileURL: nil
        )
        let decoded = try XCTUnwrap(CloudRecordCodec.decodeClip(record))

        XCTAssertEqual(decoded.item, item)
        XCTAssertEqual(decoded.container, boardID.uuidString)
    }

    func testBoardRecordRoundTripPreservesMembershipAndPins() throws {
        let clips = [
            ClipItem(type: .text, text: "One"),
            ClipItem(type: .text, text: "Two")
        ]
        let board = Pinboard(
            name: "Board",
            colorHex: "#123456",
            items: clips,
            pinnedItemIDs: [clips[1].id],
            sortIndex: 4
        )
        let record = CKRecord(
            recordType: CKSchema.pinboardType,
            recordID: CKSchema.recordID(board.id.uuidString)
        )

        CloudRecordCodec.populate(record, from: board)
        let decoded = try XCTUnwrap(CloudRecordCodec.decodeBoard(record))

        XCTAssertEqual(decoded.board.name, board.name)
        XCTAssertEqual(decoded.board.colorHex, board.colorHex)
        XCTAssertEqual(decoded.board.pinnedItemIDs, board.pinnedItemIDs)
        XCTAssertEqual(decoded.board.sortIndex, board.sortIndex)
        XCTAssertEqual(decoded.clipIDs, clips.map(\.id))
    }

    func testEmptyStringListsAreOmittedFromNewCloudKitRecords() {
        let clip = ClipItem(type: .text, text: "No files")
        let clipRecord = CKRecord(
            recordType: CKSchema.clipType,
            recordID: CKSchema.recordID(clip.id.uuidString)
        )
        CloudRecordCodec.populate(
            clipRecord,
            from: clip,
            container: CKSchema.historyContainerValue,
            imageFileURL: nil
        )

        XCTAssertNil(clipRecord[CKSchema.Field.fileURLs])
        XCTAssertNil(clipRecord[CKSchema.Field.fileNames])

        let board = Pinboard(name: "Empty")
        let boardRecord = CKRecord(
            recordType: CKSchema.pinboardType,
            recordID: CKSchema.recordID(board.id.uuidString)
        )
        CloudRecordCodec.populate(boardRecord, from: board)

        XCTAssertNil(boardRecord[CKSchema.Field.clipIDs])
        XCTAssertNil(boardRecord[CKSchema.Field.pinnedItemIDs])
    }

    func testPinboardCopyHasFreshIdentityAndRetainsContent() {
        let original = ClipItem(type: .link, text: "https://example.com")

        let copy = original.copiedWithFreshID()

        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertTrue(copy.sameContent(as: original))
    }

    func testLegacyClipDefaultsUpdatedAtToCreatedAt() throws {
        let id = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 100)
        let legacy = ClipItem(id: id, type: .text, text: "Legacy", createdAt: date)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        object.removeValue(forKey: "updatedAt")
        object.removeValue(forKey: "lastUsedAt")

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ClipItem.self, from: data)

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.updatedAt, date)
    }

    @MainActor
    func testLegacyLibraryMergeKeepsCurrentItemsAndAddsUniqueLegacyItems() {
        let sharedClipID = UUID()
        let currentClip = ClipItem(id: sharedClipID, type: .text, text: "Current")
        let currentOnlyClip = ClipItem(type: .text, text: "Current only")
        let legacyDuplicate = ClipItem(id: sharedClipID, type: .text, text: "Legacy duplicate")
        let legacyOnlyClip = ClipItem(type: .text, text: "Legacy only")

        let sharedBoardID = UUID()
        let currentBoard = Pinboard(id: sharedBoardID, name: "Current board")
        let legacyDuplicateBoard = Pinboard(id: sharedBoardID, name: "Legacy duplicate board")
        let legacyOnlyBoard = Pinboard(name: "Legacy board")

        let sharedStackID = UUID()
        let currentStack = SavedPasteStack(
            id: sharedStackID,
            entries: [PasteStackEntry(item: currentClip)]
        )
        let legacyDuplicateStack = SavedPasteStack(
            id: sharedStackID,
            entries: [PasteStackEntry(item: legacyDuplicate)]
        )
        let legacyOnlyStack = SavedPasteStack(
            entries: [PasteStackEntry(item: legacyOnlyClip)]
        )

        var currentLedger = ClipDeletionLedger()
        let deletedID = UUID()
        currentLedger.recordDeletion(
            id: deletedID,
            payload: ClipDeletionPayload(history: [], pinboards: [], pasteStackEntries: []),
            at: Date(timeIntervalSinceReferenceDate: 10)
        )
        var legacyLedger = ClipDeletionLedger()
        legacyLedger.recordDeletion(
            id: UUID(),
            payload: ClipDeletionPayload(history: [], pinboards: [], pasteStackEntries: []),
            at: Date(timeIntervalSinceReferenceDate: 20)
        )

        let merged = ClipboardStore.mergingSnapshots(
            current: ClipboardStore.Snapshot(
                history: [currentClip, currentOnlyClip],
                pinboards: [currentBoard],
                pasteStacks: [currentStack],
                deletionLedger: currentLedger
            ),
            legacy: ClipboardStore.Snapshot(
                history: [legacyDuplicate, legacyOnlyClip],
                pinboards: [legacyDuplicateBoard, legacyOnlyBoard],
                pasteStacks: [legacyDuplicateStack, legacyOnlyStack],
                deletionLedger: legacyLedger
            )
        )

        XCTAssertEqual(merged.history.map(\.text), ["Current", "Current only", "Legacy only"])
        XCTAssertEqual(merged.pinboards.map(\.name), ["Current board", "Legacy board"])
        XCTAssertEqual(merged.pasteStacks?.map(\.id), [sharedStackID, legacyOnlyStack.id])
        XCTAssertEqual(merged.deletionLedger?.deletedIDs, [deletedID])
    }
}
