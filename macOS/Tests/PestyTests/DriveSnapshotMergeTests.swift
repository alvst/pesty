import XCTest
@testable import Pesty

@MainActor
final class DriveSnapshotMergeTests: XCTestCase {
    private let older = Date(timeIntervalSince1970: 100)
    private let newer = Date(timeIntervalSince1970: 200)

    func testHistoryChoosesNewestEditRegardlessOfDeliveryOrder() {
        let id = UUID()
        let old = ClipItem(id: id, type: .text, text: "before", createdAt: older, updatedAt: older)
        let edited = ClipItem(id: id, type: .text, text: "after", createdAt: older, updatedAt: newer)

        XCTAssertEqual(ClipboardStore.mergeHistory([old], [edited]), [edited])
        XCTAssertEqual(ClipboardStore.mergeHistory([edited], [old]), [edited])
    }

    func testEqualTimestampConflictConverges() {
        let id = UUID()
        let first = ClipItem(id: id, type: .text, text: "alpha", createdAt: older, updatedAt: newer)
        let second = ClipItem(id: id, type: .text, text: "beta", createdAt: older, updatedAt: newer)

        XCTAssertEqual(
            ClipboardStore.mergeHistory([first], [second]),
            ClipboardStore.mergeHistory([second], [first])
        )
    }

    func testBoardUsesNewestMetadataAndNewestClipPayload() {
        let boardID = UUID()
        let clipID = UUID()
        let oldClip = ClipItem(id: clipID, type: .text, text: "before", createdAt: older, updatedAt: older)
        let newClip = ClipItem(id: clipID, type: .text, text: "after", createdAt: older, updatedAt: newer)
        let other = ClipItem(type: .text, text: "other", createdAt: older, updatedAt: older)
        let oldBoard = Pinboard(
            id: boardID, name: "Old", items: [oldClip, other],
            createdAt: older, updatedAt: older, sortIndex: 0
        )
        let newBoard = Pinboard(
            id: boardID, name: "New", colorHex: "#123456", items: [other, newClip],
            pinnedItemIDs: [clipID], createdAt: older, updatedAt: newer, sortIndex: 2
        )

        for merged in [ClipboardStore.mergePinboard(oldBoard, newBoard),
                       ClipboardStore.mergePinboard(newBoard, oldBoard)] {
            XCTAssertEqual(merged.name, "New")
            XCTAssertEqual(merged.colorHex, "#123456")
            XCTAssertEqual(merged.sortIndex, 2)
            XCTAssertEqual(merged.pinnedItemIDs, [clipID])
            XCTAssertEqual(merged.items.map(\.id), [other.id, clipID])
            XCTAssertEqual(merged.items.last?.text, "after")
        }
    }
}
