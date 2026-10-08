import CloudKit
import XCTest
@testable import Pesty

final class CloudRecordCodecTests: XCTestCase {
    func testClipRoundTripPreservesContainerAndMetadata() throws {
        let boardID = UUID()
        let date = Date(timeIntervalSince1970: 1_234)
        let clip = PestyClip(
            containerID: boardID,
            kind: .richText,
            text: "Hello",
            richTextData: Data("rtf".utf8),
            imageHash: "abc123",
            fileNames: ["report.pdf"],
            colorHex: "#AABBCC",
            sourceAppName: "Notes",
            sourceDeviceName: "the fork maintainer's Mac",
            customTitle: "Greeting",
            capturedAt: date,
            updatedAt: date.addingTimeInterval(10),
            lastUsedAt: date.addingTimeInterval(20)
        )
        let record = CKRecord(
            recordType: CKSchema.clipType,
            recordID: CKSchema.recordID(clip.id.uuidString)
        )

        CloudRecordCodec.populate(record, from: clip, imageFileURL: nil)
        let decoded = try XCTUnwrap(CloudRecordCodec.decodeClip(record)?.clip)

        XCTAssertEqual(decoded, clip)
    }

    func testBoardRoundTripPreservesMembershipOrder() throws {
        let ids = [UUID(), UUID(), UUID()]
        let date = Date(timeIntervalSince1970: 4_321)
        let board = PestyBoard(
            name: "Ordered",
            colorHex: "#123456",
            clipIDs: ids,
            createdAt: date,
            updatedAt: date.addingTimeInterval(1),
            sortIndex: 3
        )
        let record = CKRecord(
            recordType: CKSchema.pinboardType,
            recordID: CKSchema.recordID(board.id.uuidString)
        )

        CloudRecordCodec.populate(record, from: board)
        let decoded = try XCTUnwrap(CloudRecordCodec.decodeBoard(record))

        XCTAssertEqual(decoded, board)
    }

    func testEmptyStringListsAreOmittedFromNewCloudKitRecords() {
        let clip = PestyClip(kind: .text, text: "No files")
        let clipRecord = CKRecord(
            recordType: CKSchema.clipType,
            recordID: CKSchema.recordID(clip.id.uuidString)
        )
        CloudRecordCodec.populate(clipRecord, from: clip, imageFileURL: nil)

        XCTAssertNil(clipRecord[CKSchema.Field.fileURLs])
        XCTAssertNil(clipRecord[CKSchema.Field.fileNames])

        let board = PestyBoard(name: "Empty")
        let boardRecord = CKRecord(
            recordType: CKSchema.pinboardType,
            recordID: CKSchema.recordID(board.id.uuidString)
        )
        CloudRecordCodec.populate(boardRecord, from: board)

        XCTAssertNil(boardRecord[CKSchema.Field.clipIDs])
        XCTAssertNil(boardRecord[CKSchema.Field.pinnedItemIDs])
    }

    func testLegacyHistoryContainerDecodesAsHistory() throws {
        let id = UUID()
        let record = CKRecord(
            recordType: CKSchema.clipType,
            recordID: CKSchema.recordID(id.uuidString)
        )
        record[CKSchema.Field.type] = ClipKind.text.rawValue
        record[CKSchema.Field.text] = "Legacy"
        record[CKSchema.Field.container] = CKSchema.historyContainerValue

        let decoded = try XCTUnwrap(CloudRecordCodec.decodeClip(record)?.clip)

        XCTAssertNil(decoded.containerID)
        XCTAssertEqual(decoded.text, "Legacy")
    }
}
