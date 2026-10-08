import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Pesty

@MainActor
final class CreatedTextItemTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        super.tearDown()
    }

    func testCreatedTextBecomesTheSelectedNewestHistoryItem() throws {
        let existing = ClipItem(type: .text, text: "Existing")
        let store = ClipboardStore(testingBaseDirectory: directory, history: [existing])

        let created = try XCTUnwrap(
            store.addCreatedTextItem("Authored text", richTextData: nil, title: "  Note  ")
        )

        XCTAssertEqual(store.history.map(\.id), [created.id, existing.id])
        XCTAssertEqual(created.customTitle, "Note")
        XCTAssertEqual(store.selectedID, created.id)
        XCTAssertEqual(store.source, .history)
    }

    func testCreatedURLUsesLinkTypeAndBlankTextIsRejected() throws {
        let store = ClipboardStore(testingBaseDirectory: directory)

        let created = try XCTUnwrap(
            store.addCreatedTextItem("https://example.com", richTextData: nil, title: nil)
        )

        XCTAssertEqual(created.type, .link)
        XCTAssertNil(store.addCreatedTextItem("  \n", richTextData: nil, title: nil))
    }

    func testRepeatedAuthoredTextCreatesDistinctItems() throws {
        let store = ClipboardStore(testingBaseDirectory: directory)
        let first = try XCTUnwrap(
            store.addCreatedTextItem("Repeat", richTextData: nil, title: nil)
        )
        let second = try XCTUnwrap(
            store.addCreatedTextItem("Repeat", richTextData: nil, title: nil)
        )

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(store.history.count, 2)
    }

    func testCreatedTextStaysInTheSelectedPinboard() throws {
        let pinboard = Pinboard(name: "Home Server")
        let store = ClipboardStore(testingBaseDirectory: directory, pinboards: [pinboard])
        store.selectPinboard(pinboard.id)

        let created = try XCTUnwrap(
            store.addCreatedTextItem("Project note", richTextData: nil, title: nil)
        )

        XCTAssertTrue(store.history.isEmpty)
        XCTAssertEqual(store.pinboards[0].items.map(\.id), [created.id])
        XCTAssertEqual(store.source, .pinboard(pinboard.id))
        XCTAssertEqual(store.selectedID, created.id)
    }

    func testConfigurableHotkeyUsesNativeMenuKeyEquivalent() {
        XCTAssertEqual(HotKeyCenter.menuKeyEquivalent(for: kVK_ANSI_V), "v")
        XCTAssertEqual(
            HotKeyCenter.menuModifierMask(for: controlKey | cmdKey),
            [.control, .command]
        )
    }
}
