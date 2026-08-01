import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Pesty

@MainActor
final class ClipDragProviderTests: XCTestCase {
    func testTextLinkAndColorProvidePlainText() {
        let clips = [
            ClipItem(type: .text, text: "plain text"),
            ClipItem(type: .link, text: "https://example.com"),
            ClipItem(type: .color, colorHex: "#5B8DEF")
        ]

        for clip in clips {
            let provider = ClipDragProvider.make(for: clip)
            XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier))
        }
    }

    func testRichTextProvidesRTFAndPlainText() {
        let clip = ClipItem(
            type: .richText,
            text: "Styled text",
            rtfData: Data("{\\rtf1\\ansi Styled text}".utf8)
        )

        let provider = ClipDragProvider.make(for: clip)

        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier))
    }

    func testImageProvidesTIFFAndPNGWhenItsBitmapCanBeEncoded() {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.addRepresentation(bitmap)

        let provider = ClipDragProvider.make(for: ClipItem(type: .image), image: image)

        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.tiff.identifier))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.png.identifier))
    }

    func testExistingLocalFileIsProvidedAsAFileURL() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pesty-drag-provider-\(UUID().uuidString).txt")
        try Data("drag me".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let provider = ClipDragProvider.make(for: ClipItem(
            type: .file,
            text: url.lastPathComponent,
            fileURLs: [url.absoluteString]
        ))

        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
    }

    func testStaleOrInvalidFileDoesNotExposeAFileURL() {
        let stale = ClipItem(
            type: .file,
            text: "missing.txt",
            fileURLs: ["file:///private/tmp/pesty-does-not-exist.txt"]
        )
        let invalid = ClipItem(type: .file, text: "not a URL", fileURLs: ["not a URL"])

        for clip in [stale, invalid] {
            let provider = ClipDragProvider.make(for: clip)
            XCTAssertNil(ClipDragProvider.localFileURL(for: clip))
            XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
            XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier))
        }
    }
}
