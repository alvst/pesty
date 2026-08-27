import XCTest
@testable import Pesty

final class PinboardPinningTests: XCTestCase {
    private let a = ClipItem(type: .text, text: "alpha")
    private let b = ClipItem(type: .text, text: "bravo")
    private let c = ClipItem(type: .text, text: "charlie")

    private func board(pinned: [UUID] = []) -> Pinboard {
        Pinboard(name: "Board", items: [a, b, c], pinnedItemIDs: pinned)
    }

    func testWithoutPinsTheBoardsOwnOrderIsUsed() {
        XCTAssertEqual(board().orderedItems.map(\.id), [a.id, b.id, c.id])
    }

    func testPinnedItemsComeFirstInPromotionOrder() {
        let ordered = board(pinned: [c.id, a.id]).orderedItems.map(\.id)
        XCTAssertEqual(ordered, [c.id, a.id, b.id])
    }

    /// Unpinning has to restore a clip to where the user dragged it, which is
    /// why promotion is stored separately from `items` rather than reordering
    /// the array.
    func testUnpinningRestoresTheManualPosition() {
        var pinboard = board(pinned: [c.id])
        XCTAssertEqual(pinboard.orderedItems.map(\.id), [c.id, a.id, b.id])
        pinboard.pinnedItemIDs.removeAll { $0 == c.id }
        XCTAssertEqual(pinboard.orderedItems.map(\.id), [a.id, b.id, c.id])
    }

    func testAPinForADeletedClipIsSkippedRatherThanLeavingAGap() {
        var pinboard = board(pinned: [c.id, a.id])
        pinboard.items.removeAll { $0.id == c.id }
        XCTAssertEqual(pinboard.orderedItems.map(\.id), [a.id, b.id])
    }

    func testPrunePinsDropsPromotionsForClipsThatAreGone() {
        var pinboard = board(pinned: [c.id, a.id])
        pinboard.items.removeAll { $0.id == c.id }
        pinboard.prunePins()
        XCTAssertEqual(pinboard.pinnedItemIDs, [a.id])
    }

    func testIsPinnedReportsPromotion() {
        let pinboard = board(pinned: [b.id])
        XCTAssertTrue(pinboard.isPinned(b.id))
        XCTAssertFalse(pinboard.isPinned(a.id))
    }

    // MARK: - Persistence

    /// Boards written before pinning existed have no `pinnedItemIDs` key, and
    /// must still decode.
    func testDecodesABoardSavedBeforePinningExisted() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"Old","colorHex":"#5B8DEF","items":[]}
        """
        let decoded = try JSONDecoder().decode(Pinboard.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.name, "Old")
        XCTAssertTrue(decoded.pinnedItemIDs.isEmpty)
    }

    func testPinsSurviveARoundTrip() throws {
        let pinboard = board(pinned: [c.id])
        let data = try JSONEncoder().encode(pinboard)
        let decoded = try JSONDecoder().decode(Pinboard.self, from: data)
        XCTAssertEqual(decoded.pinnedItemIDs, [c.id])
        XCTAssertEqual(decoded.orderedItems.map(\.id), [c.id, a.id, b.id])
    }
}
