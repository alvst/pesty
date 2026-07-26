import XCTest
@testable import Pesty

@MainActor
final class PasteSequenceTests: XCTestCase {
    func testDeletingActiveStackPromotesNextSavedStack() {
        let first = savedStack(createdAt: Date(timeIntervalSince1970: 1), text: "first")
        let active = savedStack(createdAt: Date(timeIntervalSince1970: 2), text: "active")
        let sequence = PasteSequence()

        sequence.restoreSavedStacks([first, active])
        XCTAssertEqual(sequence.activeStackID, active.id)

        sequence.deleteStack(active.id)

        XCTAssertEqual(sequence.activeStackID, first.id)
        XCTAssertEqual(sequence.entries.map(\.item.text), ["first"])
        XCTAssertEqual(sequence.savedStacks.map(\.id), [first.id])
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

    func testRemovingHistoryItemsDropsEmptyStacksAndPromotesRemainingStack() {
        let retained = savedStack(createdAt: Date(timeIntervalSince1970: 1), text: "retained")
        let removed = savedStack(createdAt: Date(timeIntervalSince1970: 2), text: "removed")
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

    private func savedStack(createdAt: Date, text: String) -> SavedPasteStack {
        SavedPasteStack(createdAt: createdAt, entries: [PasteStackEntry(item: clip(text))])
    }

    private func clip(_ text: String) -> ClipItem {
        ClipItem(type: .text, text: text)
    }
}
