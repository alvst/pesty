import XCTest
@testable import Pesty

@MainActor
final class ClipPayloadSidecarTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func savedClipJSON(in directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("store.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let history = try XCTUnwrap(json["history"] as? [[String: Any]])
        return try XCTUnwrap(history.first)
    }

    func testLargePayloadsRoundTripWithoutEmbeddingBodiesInLocalJSON() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = ClipItem(
            type: .richText,
            text: String(repeating: "🙂", count: 20_000),
            rtfData: Data("{\\rtf1 Large}".utf8),
            htmlData: Data("<p>Large</p>".utf8)
        )
        let store = ClipboardStore(testingBaseDirectory: directory, history: [clip])

        XCTAssertTrue(store.saveNow())
        XCTAssertLessThan(
            try Data(contentsOf: directory.appendingPathComponent("store.json")).count,
            4_096
        )
        let json = try savedClipJSON(in: directory)
        XCTAssertNil(json["text"])
        XCTAssertNil(json["rtfData"])
        XCTAssertNil(json["htmlData"])
        for key in ["textSidecar", "rtfSidecar", "htmlSidecar"] {
            let name = try XCTUnwrap(json[key] as? String)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("payloads").appendingPathComponent(name).path
            ))
        }

        let restored = ClipboardStore(testingBaseDirectory: directory, loadExisting: true)
        XCTAssertFalse(restored.storeLoadFailed)
        XCTAssertEqual(restored.history.first, clip)
    }

    func testMissingSidecarFailsClosedWithoutReplacingStore() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = ClipItem(type: .text, text: String(repeating: "A", count: 70_000))
        let store = ClipboardStore(testingBaseDirectory: directory, history: [clip])
        XCTAssertTrue(store.saveNow())
        let json = try savedClipJSON(in: directory)
        let name = try XCTUnwrap(json["textSidecar"] as? String)
        let sidecar = directory.appendingPathComponent("payloads").appendingPathComponent(name)
        let storeURL = directory.appendingPathComponent("store.json")
        let committed = try Data(contentsOf: storeURL)
        try FileManager.default.removeItem(at: sidecar)

        let restored = ClipboardStore(testingBaseDirectory: directory, loadExisting: true)
        XCTAssertTrue(restored.storeLoadFailed)
        XCTAssertFalse(restored.saveNow())
        XCTAssertEqual(try Data(contentsOf: storeURL), committed)
    }

    func testDamagedSidecarIsRepairedBeforeAnotherSnapshotReferencesIt() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = ClipItem(type: .text, text: String(repeating: "F", count: 70_000))
        let store = ClipboardStore(testingBaseDirectory: directory, history: [clip])
        XCTAssertTrue(store.saveNow())
        let name = try XCTUnwrap(savedClipJSON(in: directory)["textSidecar"] as? String)
        let sidecar = directory.appendingPathComponent("payloads").appendingPathComponent(name)
        try Data(repeating: 0, count: 70_000).write(to: sidecar, options: .atomic)

        XCTAssertTrue(store.saveNow())
        XCTAssertEqual(try Data(contentsOf: sidecar), Data(clip.text!.utf8))
        let restored = ClipboardStore(testingBaseDirectory: directory, loadExisting: true)
        XCTAssertFalse(restored.storeLoadFailed)
        XCTAssertEqual(restored.history.first?.text, clip.text)
    }

    func testOldSidecarIsRemovedAfterReplacementCommits() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = ClipItem(type: .text, text: String(repeating: "B", count: 70_000))
        let store = ClipboardStore(testingBaseDirectory: directory, history: [clip])
        XCTAssertTrue(store.saveNow())
        let name = try XCTUnwrap(savedClipJSON(in: directory)["textSidecar"] as? String)
        let sidecar = directory.appendingPathComponent("payloads").appendingPathComponent(name)

        XCTAssertTrue(store.updateTextContent("Short replacement", for: clip))
        XCTAssertTrue(store.saveNow())
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        let restored = ClipboardStore(testingBaseDirectory: directory, loadExisting: true)
        XCTAssertEqual(restored.history.first?.text, "Short replacement")
    }

    func testCleanupSkipsUnrelatedFileInPayloadDirectory() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payloads = directory.appendingPathComponent("payloads", isDirectory: true)
        try FileManager.default.createDirectory(at: payloads, withIntermediateDirectories: true)
        let unrelated = payloads.appendingPathComponent(String(repeating: "z", count: 64) + ".txt")
        try Data("Leave this alone".utf8).write(to: unrelated)
        let store = ClipboardStore(
            testingBaseDirectory: directory,
            history: [ClipItem(type: .text, text: "Small")]
        )

        XCTAssertTrue(store.saveNow())
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("Leave this alone".utf8))
    }

    func testPendingUndoPayloadRetainsSidecar() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = ClipItem(type: .text, text: String(repeating: "E", count: 70_000))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var ledger = ClipDeletionLedger()
        ledger.recordDeletion(
            id: clip.id,
            payload: ClipDeletionPayload(
                history: [HistoryClipPlacement(index: 0, item: clip)],
                pinboards: [], pasteStackEntries: []
            ),
            at: .now
        )
        let snapshot = ClipboardStore.Snapshot(
            history: [], pinboards: [], pasteStacks: nil,
            deletionLedger: ledger, pendingPinboardDeletions: nil
        )
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("store.json"))
        let store = ClipboardStore(testingBaseDirectory: directory, loadExisting: true)
        XCTAssertTrue(store.saveNow())
        let data = try Data(contentsOf: directory.appendingPathComponent("store.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let savedLedger = try XCTUnwrap(json["deletionLedger"] as? [String: Any])
        let records = try XCTUnwrap(savedLedger["records"] as? [[String: Any]])
        let payload = try XCTUnwrap(records[0]["payload"] as? [String: Any])
        let placements = try XCTUnwrap(payload["history"] as? [[String: Any]])
        let item = try XCTUnwrap(placements[0]["item"] as? [String: Any])
        let name = try XCTUnwrap(item["textSidecar"] as? String)
        let sidecar = directory.appendingPathComponent("payloads").appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        let restored = ClipboardStore(testingBaseDirectory: directory, loadExisting: true)
        XCTAssertFalse(restored.storeLoadFailed)
    }

    func testFailedSidecarWriteLeavesPreviousSnapshotUntouched() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("store.json")
        let previous = ClipboardStore.Snapshot(
            history: [ClipItem(type: .text, text: "Safe original")],
            pinboards: [], pasteStacks: nil, deletionLedger: nil,
            pendingPinboardDeletions: nil
        )
        let previousData = try JSONEncoder().encode(previous)
        try previousData.write(to: storeURL)
        try Data("blocking payload directory".utf8).write(
            to: directory.appendingPathComponent("payloads")
        )
        let clip = ClipItem(type: .text, text: String(repeating: "C", count: 70_000))
        let store = ClipboardStore(testingBaseDirectory: directory, history: [clip])

        XCTAssertFalse(store.saveNow())
        XCTAssertEqual(try Data(contentsOf: storeURL), previousData)
    }

    func testDriveFormatKeepsLargePayloadsInline() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = ClipItem(
            type: .richText,
            text: String(repeating: "D", count: 70_000),
            rtfData: Data("{\\rtf1 Test}".utf8)
        )
        let store = ClipboardStore(
            testingBaseDirectory: directory, history: [clip], compactLocalStore: false
        )

        XCTAssertTrue(store.saveNow())
        let json = try savedClipJSON(in: directory)
        XCTAssertEqual(json["text"] as? String, clip.text)
        XCTAssertNotNil(json["rtfData"])
        XCTAssertNil(json["textSidecar"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("payloads").path
        ))
        let legacyDecoder = JSONDecoder()
        let snapshot = try legacyDecoder.decode(
            ClipboardStore.Snapshot.self,
            from: Data(contentsOf: directory.appendingPathComponent("store.json"))
        )
        XCTAssertEqual(snapshot.history.first, clip)
    }
}
