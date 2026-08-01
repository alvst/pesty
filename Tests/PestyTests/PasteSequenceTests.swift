import XCTest
@testable import Pesty

@MainActor
final class PasteSequenceTests: XCTestCase {
    func testDeletingActiveStackPromotesNextDeckInStripOrder() {
        let older = savedStack(createdAt: 1, text: "older")
        let active = savedStack(createdAt: 2, text: "active")
        let newer = savedStack(createdAt: 3, text: "newer")
        let sequence = PasteSequence()

        sequence.restoreSavedStacks([older, active, newer])
        sequence.selectStack(active.id)

        sequence.deleteStack(active.id)

        XCTAssertEqual(sequence.activeStackID, older.id)
        XCTAssertEqual(sequence.entries.map(\.item.text), ["older"])
        XCTAssertEqual(sequence.selectedEntryID, older.entries[0].id)
        XCTAssertEqual(sequence.savedStacks.map(\.id), [newer.id, older.id])
    }

    func testDeletingInactiveStackKeepsTheActiveSelection() {
        let active = savedStack(createdAt: 2, text: "active")
        let other = savedStack(createdAt: 1, text: "other")
        let sequence = PasteSequence()

        sequence.restoreSavedStacks([other, active])
        sequence.deleteStack(other.id)

        XCTAssertEqual(sequence.activeStackID, active.id)
        XCTAssertEqual(sequence.selectedEntryID, active.entries[0].id)
        XCTAssertEqual(sequence.entries.map(\.item.text), ["active"])
    }

    func testDeletingTheLastActiveStackClearsSelection() {
        let only = savedStack(createdAt: 1, text: "only")
        let sequence = PasteSequence()

        sequence.restoreSavedStacks([only])
        sequence.deleteStack(only.id)

        XCTAssertTrue(sequence.savedStacks.isEmpty)
        XCTAssertNil(sequence.activeStackID)
        XCTAssertNil(sequence.selectedEntryID)
        XCTAssertTrue(sequence.entries.isEmpty)
        XCTAssertFalse(sequence.isCollecting)
    }

    func testPastingMovesEntryBehindPendingEntries() {
        let first = PasteStackEntry(item: clip("first"))
        let second = PasteStackEntry(item: clip("second"))
        let stack = SavedPasteStack(entries: [first, second])
        let sequence = PasteSequence()
        sequence.restoreSavedStacks([stack])

        let pasted = sequence.next(entryID: first.id)

        XCTAssertEqual(pasted?.id, first.id)
        XCTAssertEqual(sequence.displayEntries.map(\.id), [second.id, first.id])
        XCTAssertEqual(sequence.selectedEntryID, second.id)
        XCTAssertEqual(sequence.pendingCount, 1)
        XCTAssertEqual(sequence.pastedCount, 1)
    }

    func testReorderingPendingEntriesLeavesPastedEntriesAtTheEnd() {
        let first = PasteStackEntry(item: clip("first"))
        let second = PasteStackEntry(item: clip("second"))
        let third = PasteStackEntry(item: clip("third"))
        let pasted = PasteStackEntry(item: clip("pasted"), isPasted: true)
        let stack = SavedPasteStack(entries: [first, pasted, second, third])
        let sequence = PasteSequence()
        sequence.restoreSavedStacks([stack])

        sequence.movePendingEntry(third.id, before: first.id)

        XCTAssertEqual(sequence.displayEntries.map(\.id), [third.id, first.id, second.id, pasted.id])
        XCTAssertEqual(sequence.selectedEntryID, third.id)
        XCTAssertEqual(sequence.pendingCount, 3)
        XCTAssertEqual(sequence.pastedCount, 1)
    }

    func testRemovingHistoryItemsDropsEmptyStacksAndPromotesRemainingStack() {
        let retained = savedStack(createdAt: 1, text: "retained")
        let removed = savedStack(createdAt: 2, text: "removed")
        let sequence = PasteSequence()
        sequence.restoreSavedStacks([retained, removed])

        sequence.removeHistoryItems([removed.entries[0].item.id])

        XCTAssertEqual(sequence.activeStackID, retained.id)
        XCTAssertEqual(sequence.savedStacks.map(\.id), [retained.id])
        XCTAssertEqual(sequence.entries.map(\.item.text), ["retained"])
    }

    func testSavedStackCodableRoundTripPreservesEntryState() throws {
        let entry = PasteStackEntry(item: clip("persisted"), isPasted: true)
        let original = SavedPasteStack(entries: [entry])

        let decoded = try JSONDecoder().decode(
            SavedPasteStack.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertEqual(decoded.entries[0].item.text, "persisted")
        XCTAssertTrue(decoded.entries[0].isPasted)
        XCTAssertNil(decoded.entries[0].imagePreview)
    }

    private func savedStack(createdAt seconds: TimeInterval, text: String) -> SavedPasteStack {
        SavedPasteStack(
            createdAt: Date(timeIntervalSince1970: seconds),
            entries: [PasteStackEntry(item: clip(text))]
        )
    }

    private func clip(_ text: String) -> ClipItem {
        ClipItem(type: .text, text: text)
    }
}
