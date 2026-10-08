import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Pesty

@MainActor
final class ClipPreviewExportTests: XCTestCase {
    func testOriginalFileExportPreservesBytesAndSourceWhileReplacingDestination() throws {
        try withStore { store, directory in
            let source = directory.appendingPathComponent("Screenshot.png")
            let destination = directory.appendingPathComponent("Saved.png")
            let bytes = Data([0, 1, 2, 255, 128, 10])
            try bytes.write(to: source)
            try Data("old destination".utf8).write(to: destination)
            let item = ClipItem(type: .file, fileURLs: [source.absoluteString])

            let exports = try ClipPreviewExport.prepare(for: item, store: store)
            XCTAssertEqual(exports.count, 1)
            XCTAssertEqual(exports[0].suggestedFileName, "Screenshot.png")
            XCTAssertEqual(exports[0].contentType, .png)
            try exports[0].write(to: destination)

            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertTrue(store.history.isEmpty)
        }
    }

    func testSavingOriginalToItselfLeavesItIntact() throws {
        try withStore { store, directory in
            let source = directory.appendingPathComponent("original.txt")
            let bytes = Data("original".utf8)
            try bytes.write(to: source)
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            let export = try XCTUnwrap(ClipPreviewExport.prepare(
                for: ClipItem(type: .file, fileURLs: [source.absoluteString]), store: store).first)

            try export.write(to: source)

            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: source.path)[.systemFileNumber] as? NSNumber,
                           attributes[.systemFileNumber] as? NSNumber)
        }
    }

    func testMissingImageFileExportsCachedBytesUsingTheirActualFormat() throws {
        try withStore { store, directory in
            let bytes = try imageData(using: .jpeg)
            let cacheName = try XCTUnwrap(store.storeImageData(bytes))
            XCTAssertTrue(cacheName.hasSuffix(".png"))
            let source = directory.appendingPathComponent("Missing screenshot.png")
            let item = ClipItem(type: .file, imageFileName: cacheName,
                                fileURLs: [source.absoluteString])

            let export = try XCTUnwrap(ClipPreviewExport.prepare(for: item, store: store).first)
            XCTAssertEqual(export.contentType, .jpeg)
            XCTAssertEqual(export.suggestedFileName,
                           "Missing screenshot.\(try XCTUnwrap(UTType.jpeg.preferredFilenameExtension))")
            let destination = directory.appendingPathComponent(export.suggestedFileName)
            try export.write(to: destination)

            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.imageURL(for: item))), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testRawImageExportPreservesManagedBytesAndAvoidsDuplicateExtension() throws {
        try withStore { store, directory in
            let bytes = try imageData(using: .png)
            let item = ClipItem(type: .image,
                                imageFileName: try XCTUnwrap(store.storeImageData(bytes)),
                                customTitle: "Holiday.png")
            let export = try XCTUnwrap(ClipPreviewExport.prepare(for: item, store: store).first)
            XCTAssertEqual(export.suggestedFileName, "Holiday.png")
            XCTAssertEqual(export.contentType, .png)
            let destination = directory.appendingPathComponent("saved.png")

            try export.write(to: destination)

            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.imageURL(for: item))), bytes)
        }
    }

    func testRichTextExportsRichestAvailablePayload() throws {
        try withStore { store, directory in
            let rtf = Data("{\\rtf1 rich}".utf8)
            let html = Data("<b>rich</b>".utf8)
            let cases: [(ClipItem, UTType, Data)] = [
                (ClipItem(type: .richText, text: "plain", rtfData: rtf, htmlData: html), .rtf, rtf),
                (ClipItem(type: .richText, text: "plain", htmlData: html), .html, html),
                (ClipItem(type: .richText, text: "plain"), .plainText, Data("plain".utf8))
            ]
            for (index, entry) in cases.enumerated() {
                let export = try XCTUnwrap(ClipPreviewExport.prepare(for: entry.0, store: store).first)
                XCTAssertEqual(export.contentType, entry.1)
                let destination = directory.appendingPathComponent("rich-\(index)")
                try export.write(to: destination)
                XCTAssertEqual(try Data(contentsOf: destination), entry.2)
            }
        }
    }

    func testTextLinkAndColorExportExactUTF8AndSafeNames() throws {
        try withStore { store, directory in
            let title = "../Secret: title\n" + String(repeating: "🐈", count: 100)
            let items = [
                ClipItem(type: .text, text: "こんにちは\nline two\n", customTitle: title),
                ClipItem(type: .link, text: "https://example.com/a?q=one&b=two"),
                ClipItem(type: .color, colorHex: "#AABBCC")
            ]
            for item in items {
                let export = try XCTUnwrap(ClipPreviewExport.prepare(for: item, store: store).first)
                XCTAssertEqual(export.contentType, .plainText)
                XCTAssertTrue(export.suggestedFileName.hasSuffix(".txt"))
                XCTAssertFalse(export.suggestedFileName.contains("/"))
                XCTAssertFalse(export.suggestedFileName.contains(":"))
                XCTAssertFalse(export.suggestedFileName.contains("\n"))
                XCTAssertFalse(export.suggestedFileName.hasPrefix("."))
                XCTAssertLessThan(export.suggestedFileName.utf8.count, 255)
                let destination = directory.appendingPathComponent(export.suggestedFileName)
                try Data("old text".utf8).write(to: destination)
                try export.write(to: destination)
                XCTAssertEqual(try Data(contentsOf: destination), Data(try XCTUnwrap(item.plainText).utf8))
            }
        }
    }

    func testMultipleFilesKeepTheirNamesAndOrder() throws {
        try withStore { store, directory in
            let urls = [directory.appendingPathComponent("One.txt"), directory.appendingPathComponent("Two.txt")]
            for (index, url) in urls.enumerated() { try Data("\(index)".utf8).write(to: url) }
            let exports = try ClipPreviewExport.prepare(
                for: ClipItem(type: .file, fileURLs: urls.map(\.absoluteString)), store: store)

            XCTAssertEqual(exports.map(\.suggestedFileName), ["One.txt", "Two.txt"])
            for (index, export) in exports.enumerated() {
                let destination = directory.appendingPathComponent("copy-\(index).txt")
                try export.write(to: destination)
                XCTAssertEqual(try Data(contentsOf: destination), Data("\(index)".utf8))
            }
        }
    }

    func testFolderCopyPreservesOriginalAndRejectsOverlappingDestination() throws {
        try withStore { store, directory in
            let source = directory.appendingPathComponent("Source", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let file = source.appendingPathComponent("contents.txt")
            let bytes = Data("folder contents".utf8)
            try bytes.write(to: file)
            let export = try XCTUnwrap(ClipPreviewExport.prepare(
                for: ClipItem(type: .file, fileURLs: [source.absoluteString]), store: store).first)
            XCTAssertNil(export.contentType)
            let destination = directory.appendingPathComponent("Saved folder", isDirectory: true)

            try export.write(to: destination)

            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("contents.txt")), bytes)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertThrowsError(try export.write(to: source.appendingPathComponent("Nested copy")))
            XCTAssertThrowsError(try export.write(to: directory))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testMissingSourceAndInvalidPayloadsProduceUsefulErrors() throws {
        try withStore { store, directory in
            let missing = directory.appendingPathComponent("missing.pdf")
            let items = [
                ClipItem(type: .file, fileURLs: [missing.absoluteString]),
                ClipItem(type: .file, fileURLs: ["https://example.com/file"]),
                ClipItem(type: .file),
                ClipItem(type: .image, imageFileName: "missing.png"),
                ClipItem(type: .text)
            ]
            for item in items {
                XCTAssertThrowsError(try ClipPreviewExport.prepare(for: item, store: store)) { error in
                    XCTAssertFalse(error.localizedDescription.isEmpty)
                    XCTAssertFalse(error.localizedDescription.contains("couldn’t be completed"))
                }
            }
        }
    }

    func testSourceDisappearingAfterPrepareDoesNotDeleteExistingDestination() throws {
        try withStore { store, directory in
            let source = directory.appendingPathComponent("source.txt")
            let destination = directory.appendingPathComponent("destination.txt")
            try Data("source".utf8).write(to: source)
            let previous = Data("keep destination".utf8)
            try previous.write(to: destination)
            let export = try XCTUnwrap(ClipPreviewExport.prepare(
                for: ClipItem(type: .file, fileURLs: [source.absoluteString]), store: store).first)
            try FileManager.default.removeItem(at: source)

            XCTAssertThrowsError(try export.write(to: destination))

            XCTAssertEqual(try Data(contentsOf: destination), previous)
        }
    }

    private func withStore(_ body: (ClipboardStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PestyPreviewExportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(testingBaseDirectory: directory.appendingPathComponent("Library"))
        try body(store, directory)
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
