import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Pesty

@MainActor
final class ClipboardImportTests: XCTestCase {
    private func pasteboard() -> UIPasteboard {
        let board = UIPasteboard.withUniqueName()
        addTeardownBlock { UIPasteboard.remove(withName: board.name) }
        return board
    }

    private func sampleImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    func testJPEGBytesAreImportedWithoutReencoding() throws {
        let board = pasteboard()
        let jpeg = try XCTUnwrap(sampleImage().jpegData(compressionQuality: 0.8))
        board.setData(jpeg, forPasteboardType: UTType.jpeg.identifier)

        guard case .image(let data) = try ClipboardReader.read(from: board) else {
            return XCTFail("Expected an image payload")
        }
        XCTAssertEqual(data, jpeg)
    }

    func testImageProvidedOnlyThroughItemProviderIsImported() throws {
        let board = pasteboard()
        let png = try XCTUnwrap(sampleImage().pngData())
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(png, nil)
            return nil
        }
        board.setItemProviders([provider], localOnly: true, expirationDate: nil)

        guard case .image(let data) = try ClipboardReader.read(from: board) else {
            return XCTFail("Expected an image payload")
        }
        XCTAssertEqual(data, png)
    }

    func testUnusualImageFormatIsStoredAsPNG() throws {
        let board = pasteboard()
        let image = sampleImage()
        let tiff = try XCTUnwrap(tiffData(for: image))
        board.setData(tiff, forPasteboardType: UTType.tiff.identifier)

        guard case .image(let data) = try ClipboardReader.read(from: board) else {
            return XCTFail("Expected an image payload")
        }
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "Expected a PNG signature")
    }

    func testImageWinsOverAccompanyingURL() throws {
        let board = pasteboard()
        let png = try XCTUnwrap(sampleImage().pngData())
        board.items = [[
            UTType.png.identifier: png,
            UTType.url.identifier: URL(string: "https://example.com/picture.png")!
        ]]

        guard case .image = try ClipboardReader.read(from: board) else {
            return XCTFail("Expected the picture, not its source link")
        }
    }

    func testForegroundImportAddsOnceAndSkipsDuplicates() throws {
        let board = pasteboard()
        board.string = "moving this to the mac"
        let store = LibraryStore(
            library: PestyLibrary(),
            syncService: NoCloudSyncService(),
            sharedLibraryLoader: { PestyLibrary() },
            librarySaver: { _ in }
        )
        store.addsClipboardOnOpen = true
        UserDefaults.standard.removeObject(forKey: "lastAutoImportedPasteboardChangeCount")

        XCTAssertTrue(store.addClipboardOnOpenIfNeeded(from: board))
        XCTAssertEqual(store.clips.map(\.text), ["moving this to the mac"])

        // Same pasteboard generation: nothing new to add.
        XCTAssertFalse(store.addClipboardOnOpenIfNeeded(from: board))

        // A fresh copy of identical content is still a duplicate.
        board.string = "moving this to the mac"
        XCTAssertFalse(store.addClipboardOnOpenIfNeeded(from: board))
        XCTAssertEqual(store.clips.count, 1)

        board.string = "something else"
        XCTAssertTrue(store.addClipboardOnOpenIfNeeded(from: board))
        XCTAssertEqual(store.clips.count, 2)
    }

    func testForegroundImportRespectsSetting() throws {
        let board = pasteboard()
        board.string = "ignored"
        let store = LibraryStore(
            library: PestyLibrary(),
            syncService: NoCloudSyncService(),
            sharedLibraryLoader: { PestyLibrary() },
            librarySaver: { _ in }
        )
        store.addsClipboardOnOpen = false
        UserDefaults.standard.removeObject(forKey: "lastAutoImportedPasteboardChangeCount")

        XCTAssertFalse(store.addClipboardOnOpenIfNeeded(from: board))
        XCTAssertTrue(store.clips.isEmpty)
        store.addsClipboardOnOpen = true
    }

    private func tiffData(for image: UIImage) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
