import XCTest
@testable import Pesty

final class ClipSelectionTests: XCTestCase {
    private let order = (0..<5).map { _ in UUID() }

    private func selection(leadIndex: Int) -> ClipSelection {
        var s = ClipSelection()
        s.select(order[leadIndex])
        return s
    }

    // MARK: - Plain click

    func testSelectReplacesTheWholeSelection() {
        var s = selection(leadIndex: 0)
        s.extend(to: order[3], in: order)
        XCTAssertEqual(s.count, 4)

        s.select(order[2])
        XCTAssertEqual(s.ids, [order[2]])
        XCTAssertEqual(s.lead, order[2])
        XCTAssertEqual(s.anchor, order[2])
    }

    func testSelectingNilClearsEverything() {
        var s = selection(leadIndex: 0)
        s.select(nil)
        XCTAssertTrue(s.isEmpty)
        XCTAssertNil(s.lead)
    }

    // MARK: - Shift

    func testExtendSelectsTheRangeInEitherDirection() {
        var forward = selection(leadIndex: 1)
        forward.extend(to: order[3], in: order)
        XCTAssertEqual(forward.ids, Set(order[1...3]))

        var backward = selection(leadIndex: 3)
        backward.extend(to: order[1], in: order)
        XCTAssertEqual(backward.ids, Set(order[1...3]))
    }

    /// The point of pinning the anchor: shift-clicking closer must shrink the
    /// range, not leave the earlier one behind.
    func testExtendingAgainShrinksRatherThanRatchets() {
        var s = selection(leadIndex: 0)
        s.extend(to: order[4], in: order)
        XCTAssertEqual(s.count, 5)

        s.extend(to: order[1], in: order)
        XCTAssertEqual(s.ids, Set(order[0...1]))
        XCTAssertEqual(s.anchor, order[0], "the anchor must survive the range changing")
        XCTAssertEqual(s.lead, order[1])
    }

    func testExtendIgnoresAnIDThatIsNotOnScreen() {
        var s = selection(leadIndex: 0)
        s.extend(to: UUID(), in: order)
        XCTAssertEqual(s.ids, [order[0]])
    }

    // MARK: - Command

    func testToggleAddsAndRemovesWithoutDisturbingTheRest() {
        var s = selection(leadIndex: 0)
        s.toggle(order[2], in: order)
        s.toggle(order[4], in: order)
        XCTAssertEqual(s.ids, [order[0], order[2], order[4]])
        XCTAssertEqual(s.lead, order[4])

        s.toggle(order[2], in: order)
        XCTAssertEqual(s.ids, [order[0], order[4]])
    }

    func testTogglingTheLeadPromotesASurvivor() {
        var s = selection(leadIndex: 0)
        s.toggle(order[3], in: order)
        XCTAssertEqual(s.lead, order[3])

        s.toggle(order[3], in: order)
        XCTAssertEqual(s.ids, [order[0]])
        XCTAssertEqual(s.lead, order[0], "removing the lead must leave a usable one behind")
    }

    /// A focused list always has something selected; the last card must not
    /// toggle itself away and strand the keyboard with no lead.
    func testTheLastSelectedCardWillNotToggleOff() {
        var s = selection(leadIndex: 2)
        s.toggle(order[2], in: order)
        XCTAssertEqual(s.ids, [order[2]])
        XCTAssertEqual(s.lead, order[2])
    }

    // MARK: - Select all and pruning

    func testSelectAllKeepsAnExistingLead() {
        var s = selection(leadIndex: 3)
        s.selectAll(in: order)
        XCTAssertEqual(s.ids, Set(order))
        XCTAssertEqual(s.lead, order[3])
    }

    func testPruneDropsOffscreenCardsAndRepairsTheLead() {
        var s = selection(leadIndex: 0)
        s.extend(to: order[3], in: order)

        let remaining = Array(order[2...])
        s.prune(to: remaining)
        XCTAssertEqual(s.ids, Set(order[2...3]))
        XCTAssertEqual(s.lead, order[3], "the lead was still visible, so it stands")

        s.prune(to: [order[2]])
        XCTAssertEqual(s.ids, [order[2]])
        XCTAssertEqual(s.lead, order[2])
        XCTAssertEqual(s.anchor, order[2], "a pruned-away anchor must not linger")
    }

    func testPruneToNothingEmptiesTheSelection() {
        var s = selection(leadIndex: 0)
        s.selectAll(in: order)
        s.prune(to: [])
        XCTAssertTrue(s.isEmpty)
        XCTAssertNil(s.lead)
    }
}
