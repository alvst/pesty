import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Pesty

@MainActor
final class InlinePreviewExternalOpenerTests: XCTestCase {
    func testMissingScreenshotOpensCachedImageWithActualFormatWithoutExposingManagedFile() throws {
        try withStore { store, directory in
            let bytes = try imageData(using: .jpeg)
            let cacheName = try XCTUnwrap(store.storeImageData(bytes))
            XCTAssertTrue(cacheName.hasSuffix(".png"))
            let missingOriginal = directory.appendingPathComponent("Missing screenshot.png")
            let item = ClipItem(type: .file, imageFileName: cacheName,
                                fileURLs: [missingOriginal.absoluteString])
            let managedURL = try XCTUnwrap(store.imageURL(for: item))

            let exported = try XCTUnwrap(InlinePreviewExternalOpener.exportedURL(for: item, store: store))
            defer { removeExportDirectory(containing: exported) }

            XCTAssertTrue(exported.isFileURL)
            XCTAssertNotEqual(exported.standardizedFileURL, managedURL.standardizedFileURL)
            XCTAssertNotEqual(exported.standardizedFileURL, missingOriginal.standardizedFileURL)
            XCTAssertEqual(UTType(filenameExtension: exported.pathExtension), .jpeg)
            let exportedBytes = try Data(contentsOf: exported)
            XCTAssertEqual(exportedBytes, bytes)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(exportedBytes as CFData, nil))
            let identifier = try XCTUnwrap(CGImageSourceGetType(source))
            XCTAssertEqual(UTType(identifier as String), .jpeg)

            try Data("external app edits".utf8).write(to: exported)

            XCTAssertEqual(try Data(contentsOf: managedURL), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: missingOriginal.path))
            XCTAssertTrue(store.history.isEmpty)
        }
    }

    func testRichTextWithoutRTFFallsBackToPlainText() throws {
        try withStore { store, _ in
            let text = "こんにちは\nA plain-text fallback\n"
            let item = ClipItem(type: .richText, text: text)
            let exported = try XCTUnwrap(InlinePreviewExternalOpener.exportedURL(for: item, store: store))
            defer { removeExportDirectory(containing: exported) }

            XCTAssertEqual(UTType(filenameExtension: exported.pathExtension), .plainText)
            XCTAssertEqual(try Data(contentsOf: exported), Data(text.utf8))
        }
    }

    func testWebLinksReturnTheirDirectURL() throws {
        try withStore { store, _ in
            for address in ["https://example.com/path?q=one&b=two#section", "http://example.com/path"] {
                let item = ClipItem(type: .link, text: " \n\(address)\t")
                let exported = try XCTUnwrap(InlinePreviewExternalOpener.exportedURL(for: item, store: store))

                XCTAssertEqual(exported, URL(string: address))
                XCTAssertFalse(exported.isFileURL)
            }
            XCTAssertTrue(store.history.isEmpty)
        }
    }

    func testInvalidLinksAndMissingPayloadsDoNotProduceAnExport() throws {
        try withStore { store, directory in
            let items = [
                ClipItem(type: .link),
                ClipItem(type: .link, text: "not a URL"),
                ClipItem(type: .link, text: "ftp://example.com/image.png"),
                ClipItem(type: .link, text: "file:///tmp/image.png"),
                ClipItem(type: .image, imageFileName: "missing.png"),
                ClipItem(type: .file, fileURLs: [directory.appendingPathComponent("missing.png").absoluteString]),
                ClipItem(type: .text),
                ClipItem(type: .richText)
            ]
            for item in items {
                let exported = InlinePreviewExternalOpener.exportedURL(for: item, store: store)
                if let exported { removeExportDirectory(containing: exported) }
                XCTAssertNil(exported, "Unexpected export for \(item.type): \(item.text ?? "no text")")
            }
        }
    }

    func testColorsAndMultipleFilesRemainUnsupported() throws {
        try withStore { store, directory in
            let bytes = try imageData(using: .png)
            let first = directory.appendingPathComponent("first.png")
            let second = directory.appendingPathComponent("second.png")
            try bytes.write(to: first)
            try bytes.write(to: second)
            let items = [
                ClipItem(type: .color, colorHex: "#AABBCC"),
                ClipItem(type: .file, fileURLs: [first.absoluteString, second.absoluteString])
            ]
            for item in items {
                let exported = InlinePreviewExternalOpener.exportedURL(for: item, store: store)
                if let exported { removeExportDirectory(containing: exported) }
                XCTAssertNil(exported)
            }
            XCTAssertEqual(try Data(contentsOf: first), bytes)
            XCTAssertEqual(try Data(contentsOf: second), bytes)
        }
    }

    private func withStore(_ body: (ClipboardStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PestyExternalOpenerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(testingBaseDirectory: directory.appendingPathComponent("Library"))
        try body(store, directory)
    }

    private func removeExportDirectory(containing url: URL) {
        guard url.isFileURL else { return }
        let directory = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let exportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(AppIdentity.externalPreviewDirectoryName, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        // Never remove a link target, the managed image directory, or the
        // shared export root if a regression returns an unexpected URL.
        guard directory.deletingLastPathComponent().standardizedFileURL == exportRoot else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private func imageData(using format: NSBitmapImageRep.FileType) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                   pixelsWide: 2, pixelsHigh: 2,
                                                   bitsPerSample: 8, samplesPerPixel: 3,
                                                   hasAlpha: false, isPlanar: false,
                                                   colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<2 {
            for y in 0..<2 { bitmap.setColor(.red, atX: x, y: y) }
        }
        return try XCTUnwrap(bitmap.representation(using: format, properties: [:]))
    }
}
