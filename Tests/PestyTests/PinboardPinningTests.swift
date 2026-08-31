import AppKit
import Carbon.HIToolbox
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

final class PinboardJumpTests: XCTestCase {
    private let topRowKeyCodes = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3,
        kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6,
        kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]

    private let keypadKeyCodes = [
        kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3,
        kVK_ANSI_Keypad4, kVK_ANSI_Keypad5, kVK_ANSI_Keypad6,
        kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9,
    ]

    func testTopRowDigitsMapToZeroBasedPinboardIndexes() {
        for (index, keyCode) in topRowKeyCodes.enumerated() {
            XCTAssertEqual(
                PinboardJump.index(
                    forKeyCode: keyCode,
                    modifiers: [.command, .option]
                ),
                index
            )
        }
    }

    func testKeypadDigitsCountAndIgnoreTheNumericPadFlag() {
        for (index, keyCode) in keypadKeyCodes.enumerated() {
            XCTAssertEqual(
                PinboardJump.index(
                    forKeyCode: keyCode,
                    modifiers: [.command, .option, .numericPad]
                ),
                index
            )
        }
    }

    func testWrongModifiersDoNotMatch() {
        let wrongModifiers: [NSEvent.ModifierFlags] = [
            [.command],
            [.command, .option, .shift],
            [.command, .option, .control],
        ]

        for modifiers in wrongModifiers {
            XCTAssertNil(
                PinboardJump.index(
                    forKeyCode: kVK_ANSI_1,
                    modifiers: modifiers
                )
            )
        }
    }

    func testNonDigitKeyCodesDoNotMatch() {
        XCTAssertNil(
            PinboardJump.index(
                forKeyCode: kVK_ANSI_A,
                modifiers: [.command, .option]
            )
        )
        XCTAssertNil(
            PinboardJump.index(
                forKeyCode: kVK_ANSI_0,
                modifiers: [.command, .option]
            )
        )
    }

    func testQuickPasteConfiguredAsCommandOptionMatchesFirst() {
        XCTAssertEqual(
            QuickPasteShortcut.match(
                forKeyCode: kVK_ANSI_1,
                modifiers: [.command, .option],
                quickPasteModifier: cmdKey | optionKey,
                plainTextModifier: shiftKey
            ),
            QuickPasteShortcut.Match(index: 0, usesPlainText: false)
        )
    }

    func testPlainTextQuickPasteCommandOptionAlsoMatchesFirst() {
        XCTAssertEqual(
            QuickPasteShortcut.match(
                forKeyCode: kVK_ANSI_1,
                modifiers: [.command, .option],
                quickPasteModifier: cmdKey,
                plainTextModifier: optionKey
            ),
            QuickPasteShortcut.Match(index: 0, usesPlainText: true)
        )
    }

    func testDefaultQuickPasteLeavesCommandOptionForPinboardJump() {
        XCTAssertNil(
            QuickPasteShortcut.match(
                forKeyCode: kVK_ANSI_1,
                modifiers: [.command, .option],
                quickPasteModifier: cmdKey,
                plainTextModifier: shiftKey
            )
        )
        XCTAssertEqual(
            PinboardJump.index(
                forKeyCode: kVK_ANSI_1,
                modifiers: [.command, .option]
            ),
            0
        )
    }
}

@MainActor
final class ClipboardStoreDuplicateTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        super.tearDown()
    }

    func testHistoryDuplicateIsFreshSelectedAndImmediatelyBeforeOriginal() throws {
        let originalDate = Date(timeIntervalSince1970: 1_000)
        let duplicateDate = Date(timeIntervalSince1970: 2_000)
        let newer = ClipItem(type: .text, text: "newer")
        let original = ClipItem(
            type: .text,
            text: "payload",
            customTitle: "Named clip",
            createdAt: originalDate,
            updatedAt: originalDate
        )
        let older = ClipItem(type: .text, text: "older")
        let store = ClipboardStore(
            testingBaseDirectory: directory,
            history: [newer, original, older]
        )

        let copy = try XCTUnwrap(store.duplicate(original, at: duplicateDate))

        XCTAssertEqual(store.history.map(\.id), [newer.id, copy.id, original.id, older.id])
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertTrue(copy.sameContent(as: original))
        XCTAssertEqual(copy.customTitle, original.customTitle)
        XCTAssertEqual(copy.createdAt, original.createdAt)
        XCTAssertEqual(copy.updatedAt, duplicateDate)
        XCTAssertEqual(store.selectedID, copy.id)
    }

    func testPinboardDuplicateStaysInCurrentBoardAndPreservesDisplayedAdjacency() throws {
        let before = ClipItem(type: .text, text: "before")
        let original = ClipItem(type: .text, text: "payload")
        let after = ClipItem(type: .text, text: "after")
        let other = ClipItem(type: .text, text: "other board")
        let board = Pinboard(
            name: "Current",
            items: [before, original, after],
            pinnedItemIDs: [original.id]
        )
        let otherBoard = Pinboard(name: "Other", items: [other])
        let store = ClipboardStore(
            testingBaseDirectory: directory,
            pinboards: [board, otherBoard]
        )
        store.source = .pinboard(board.id)

        let copy = try XCTUnwrap(store.duplicate(original))
        let current = try XCTUnwrap(store.pinboards.first(where: { $0.id == board.id }))
        let untouched = try XCTUnwrap(store.pinboards.first(where: { $0.id == otherBoard.id }))

        XCTAssertEqual(current.items.map(\.id), [before.id, copy.id, original.id, after.id])
        XCTAssertEqual(Array(current.orderedItems.prefix(2)).map(\.id), [copy.id, original.id])
        XCTAssertEqual(untouched.items.map(\.id), [other.id])
        XCTAssertEqual(store.selectedID, copy.id)
    }

    func testImageDuplicateOwnsASeparateCopyOfTheBackingFile() throws {
        let payload = Data("image payload".utf8)
        let original = ClipItem(
            type: .image,
            imageFileName: "original.png",
            imageHash: "same pixels"
        )
        let store = ClipboardStore(
            testingBaseDirectory: directory,
            history: [original]
        )
        let originalURL = try XCTUnwrap(store.imageURL(for: original))
        try payload.write(to: originalURL)

        let copy = try XCTUnwrap(store.duplicate(original))
        let copyURL = try XCTUnwrap(store.imageURL(for: copy))

        XCTAssertNotEqual(copy.imageFileName, original.imageFileName)
        XCTAssertEqual(try Data(contentsOf: originalURL), payload)
        XCTAssertEqual(try Data(contentsOf: copyURL), payload)
        XCTAssertTrue(copy.sameContent(as: original))
    }
}

final class ClipCardHeaderLabelTests: XCTestCase {
    func testCustomTitleOutranksExtensionLabel() {
        XCTAssertEqual(
            ClipCardHeaderLabel.resolve(
                customTitle: "My title",
                extensionLabel: "JSON",
                type: .text,
                fileCount: 0
            ),
            "My title"
        )
    }

    func testExtensionLabelOutranksMultiFileAndTypeLabels() {
        XCTAssertEqual(
            ClipCardHeaderLabel.resolve(
                customTitle: nil,
                extensionLabel: "Bundle",
                type: .file,
                fileCount: 3
            ),
            "Bundle"
        )
    }

    func testMultiFileCountOutranksBuiltInTypeLabel() {
        XCTAssertEqual(
            ClipCardHeaderLabel.resolve(
                customTitle: "",
                extensionLabel: nil,
                type: .file,
                fileCount: 3
            ),
            "3 files"
        )
    }

    func testBuiltInTypeLabelIsTheFallback() {
        XCTAssertEqual(
            ClipCardHeaderLabel.resolve(
                customTitle: nil,
                extensionLabel: nil,
                type: .link,
                fileCount: 0
            ),
            ClipType.link.label
        )
    }
}
