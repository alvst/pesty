import AppKit
import XCTest
@testable import Pesty

@MainActor
final class ClipboardStoreAsyncSaveTests: XCTestCase {
    func testDebouncedCapturePersistsWithoutExplicitSave() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(testingBaseDirectory: directory)
        let clip = ClipItem(type: .text, text: "Captured")
        let saved = expectation(description: "background save completed")
        let observer = NotificationCenter.default.addObserver(
            forName: .pestyStoreDidSave, object: store, queue: .main
        ) { _ in saved.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.addCaptured(clip)
        await fulfillment(of: [saved], timeout: 3)

        let data = try Data(contentsOf: directory.appendingPathComponent("store.json"))
        let snapshot = try JSONDecoder().decode(ClipboardStore.Snapshot.self, from: data)
        XCTAssertEqual(snapshot.history.map(\.id), [clip.id])
    }

    func testCaptureReusesIdenticalImageBeforeWritingAnotherFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(testingBaseDirectory: directory)
        let bytes = Data([1, 2, 3, 4])
        let hash = ClipboardMonitor.sha256Hex(bytes)
        let firstName = try XCTUnwrap(store.storeImageData(bytes, imageHash: hash))
        let clip = ClipItem(type: .image, imageFileName: firstName, imageHash: hash)
        store.addCaptured(clip)

        XCTAssertEqual(store.storeImageData(bytes, imageHash: hash), firstName)
        let images = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("images"), includingPropertiesForKeys: nil
        )
        XCTAssertEqual(images.count, 1)
    }
}
