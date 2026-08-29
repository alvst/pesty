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
            fileURLs: ["file:///Users/alvie/report.pdf"],
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
}
