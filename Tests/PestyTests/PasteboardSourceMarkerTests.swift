import AppKit
import XCTest
@testable import Pesty

@MainActor
final class PasteboardSourceMarkerTests: XCTestCase {
    func testTextCopyWritesPestySourceMarker() {
        let pasteboard = uniquePasteboard()

        let result = PasteService.copy(ClipItem(type: .text, text: "Pesty copy"), to: pasteboard)

        XCTAssertTrue(result.didWriteContent)
        XCTAssertEqual(pasteboard.string(forType: .string), "Pesty copy")
        XCTAssertEqual(PasteboardSourceMarker.identifier(on: pasteboard), PasteboardSourceMarker.pestyBundleIdentifier)
        XCTAssertTrue(PasteboardSourceMarker.isPestyOrigin(PasteboardSourceMarker.identifier(on: pasteboard)))
    }

    func testLinkCopyWritesPestySourceMarker() {
        let pasteboard = uniquePasteboard()
        let link = "https://example.com/pesty"

        let result = PasteService.copy(ClipItem(type: .link, text: link), to: pasteboard)

        XCTAssertTrue(result.didWriteContent)
        XCTAssertEqual(pasteboard.string(forType: .string), link)
        XCTAssertEqual(PasteboardSourceMarker.identifier(on: pasteboard), PasteboardSourceMarker.pestyBundleIdentifier)
    }

    func testPlainTextCopyKeepsTheSourceMarker() {
        let pasteboard = uniquePasteboard()
        let rtf = Data("{\\rtf1\\ansi Rich}".utf8)
        let item = ClipItem(type: .richText, text: "Rich", rtfData: rtf)

        let result = PasteService.copy(item, to: pasteboard, asPlainText: true)

        XCTAssertTrue(result.didWriteContent)
        XCTAssertEqual(pasteboard.string(forType: .string), "Rich")
        XCTAssertNil(pasteboard.data(forType: .rtf))
        XCTAssertEqual(PasteboardSourceMarker.identifier(on: pasteboard), PasteboardSourceMarker.pestyBundleIdentifier)
    }

    func testEveryRichFileColorAndImagePathMarksThePasteboard() {
        let richTextBoard = uniquePasteboard()
        let richText = ClipItem(type: .richText,
                                text: "Rich",
                                rtfData: Data("{\\rtf1\\ansi Rich}".utf8))
        XCTAssertTrue(PasteService.copy(richText, to: richTextBoard).didWriteContent)
        XCTAssertEqual(PasteboardSourceMarker.identifier(on: richTextBoard), PasteboardSourceMarker.pestyBundleIdentifier)

        let fileBoard = uniquePasteboard()
        let file = ClipItem(type: .file,
                            text: "example.txt",
                            fileURLs: ["file:///tmp/pesty-marker-example.txt"])
        XCTAssertTrue(PasteService.copy(file, to: fileBoard).didWriteContent)
        XCTAssertEqual(PasteboardSourceMarker.identifier(on: fileBoard), PasteboardSourceMarker.pestyBundleIdentifier)

        let colorBoard = uniquePasteboard()
        let color = ClipItem(type: .color, colorHex: "#5B8DEF")
        XCTAssertTrue(PasteService.copy(color, to: colorBoard).didWriteContent)
        XCTAssertEqual(PasteboardSourceMarker.identifier(on: colorBoard), PasteboardSourceMarker.pestyBundleIdentifier)

        let imageBoard = uniquePasteboard()
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1, height: 1)).fill()
        image.unlockFocus()
        XCTAssertTrue(PasteService.copy(ClipItem(type: .image),
                                       to: imageBoard,
                                       imageOverride: image).didWriteContent)
        XCTAssertEqual(PasteboardSourceMarker.identifier(on: imageBoard), PasteboardSourceMarker.pestyBundleIdentifier)
    }

    func testFailedCopyLeavesExistingPasteboardContentsAndOriginAlone() {
        let pasteboard = uniquePasteboard()
        pasteboard.setString("existing", forType: .string)
        let originalChangeCount = pasteboard.changeCount

        let result = PasteService.copy(ClipItem(type: .text), to: pasteboard)

        XCTAssertFalse(result.didWriteContent)
        XCTAssertEqual(result.changeCount, originalChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "existing")
        XCTAssertNil(PasteboardSourceMarker.identifier(on: pasteboard))
    }

    func testWhitespaceOnlyMarkerIsIgnoredAndPestyMarkerIsRecognized() {
        let pasteboard = uniquePasteboard()
        pasteboard.setString("  \n", forType: PasteboardSourceMarker.pasteboardType)
        XCTAssertNil(PasteboardSourceMarker.identifier(on: pasteboard))

        PasteboardSourceMarker.markPestyAsSource(on: pasteboard)
        XCTAssertTrue(PasteboardSourceMarker.isPestyOrigin(PasteboardSourceMarker.identifier(on: pasteboard)))
    }

    private func uniquePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        return pasteboard
    }
}
