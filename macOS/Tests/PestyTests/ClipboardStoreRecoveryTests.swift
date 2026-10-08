import AppKit
import XCTest
@testable import Pesty

@MainActor
final class ClipboardStoreRecoveryTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        PasteSequence.shared.restoreSavedStacks([])
    }

    override func tearDown() {
        PasteSequence.shared.restoreSavedStacks([])
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        super.tearDown()
    }

    func testHistoryDeleteAndUndoLeaveUnreadableStackFileUntouched() throws {
        let clip = ClipItem(type: .text, text: "Keep recoverable")
        try writeStore(history: [clip])
        let stackURL = try writeStackData(Data("broken JSON".utf8))
        let store = ClipboardStore(testingBaseDirectory: directory, loadExisting: true)

        XCTAssertTrue(store.delete([clip]))
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertEqual(try Data(contentsOf: stackURL), Data("broken JSON".utf8))

        XCTAssertTrue(store.undoLastDelete())
        XCTAssertEqual(store.history.map(\.id), [clip.id])
        XCTAssertEqual(try Data(contentsOf: stackURL), Data("broken JSON".utf8))
    }

    func testDeleteAllStacksCanResetUnreadableStackFile() throws {
        try writeStore(history: [])
        let stackURL = try writeStackData(Data("broken JSON".utf8))
        let store = ClipboardStore(testingBaseDirectory: directory, loadExisting: true)

        XCTAssertTrue(store.deleteAllPasteStacks())
        let saved = try JSONDecoder().decode(StackFile.self, from: Data(contentsOf: stackURL))
        XCTAssertTrue(saved.stacks.isEmpty)
    }

    func testUnreadableMainStoreIsNeverOverwrittenByEmptyMemory() throws {
        let url = directory.appendingPathComponent("store.json")
        let damaged = Data("broken library".utf8)
        try damaged.write(to: url)
        let store = ClipboardStore(testingBaseDirectory: directory, loadExisting: true)

        XCTAssertTrue(store.storeLoadFailed)
        XCTAssertFalse(store.saveNow())
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

    func testFailedLegacyStackMigrationKeepsLegacyDataDuringHistoryDelete() throws {
        let historyClip = ClipItem(type: .text, text: "Delete this")
        let missingImage = ClipItem(type: .image, imageFileName: "missing.png")
        let legacyStack = SavedPasteStack(entries: [PasteStackEntry(item: missingImage)])
        try writeStore(history: [historyClip], stacks: [legacyStack])
        let store = ClipboardStore(testingBaseDirectory: directory, loadExisting: true)

        XCTAssertTrue(store.delete([historyClip]))
        let saved = try JSONDecoder().decode(
            ClipboardStore.Snapshot.self,
            from: Data(contentsOf: directory.appendingPathComponent("store.json"))
        )
        XCTAssertEqual(saved.pasteStacks?.first?.entries.first?.item.id, missingImage.id)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Paste Stacks/stacks.json").path
        ))
    }

    func testHistoryTombstoneDoesNotDeleteLegacyPinboardCopySharingItsID() throws {
        let clip = ClipItem(type: .text, text: "Same legacy ID")
        let board = Pinboard(name: "Saved", items: [clip], pinnedItemIDs: [clip.id])
        var ledger = ClipDeletionLedger()
        ledger.recordDeletion(
            id: clip.id,
            payload: ClipDeletionPayload(
                history: [HistoryClipPlacement(index: 0, item: clip)],
                pinboards: [], pasteStackEntries: []
            ),
            at: .now
        )
        try writeStore(history: [], pinboards: [board], ledger: ledger)

        let store = ClipboardStore(testingBaseDirectory: directory, loadExisting: true)
        let survivor = try XCTUnwrap(store.pinboards.first?.items.first)
        XCTAssertNotEqual(survivor.id, clip.id)
        XCTAssertEqual(survivor.text, clip.text)
        XCTAssertEqual(store.pinboards.first?.pinnedItemIDs, [survivor.id])
    }

    func testFinalizedHistoryTombstonePreservesLegacyPinboardCopy() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let clip = ClipItem(type: .text, text: "Still saved", createdAt: date)
        var ledger = ClipDeletionLedger()
        ledger.recordDeletion(
            id: clip.id,
            payload: ClipDeletionPayload(
                history: [HistoryClipPlacement(index: 0, item: clip)],
                pinboards: [], pasteStackEntries: []
            ),
            at: date
        )
        _ = ledger.finalizeExpired(
            at: date.addingTimeInterval(ClipDeletionLedger.undoWindow)
        )
        try writeStore(history: [], pinboards: [Pinboard(name: "Saved", items: [clip])], ledger: ledger)

        let store = ClipboardStore(testingBaseDirectory: directory, loadExisting: true)

        XCTAssertEqual(store.pinboards.first?.items.first?.text, clip.text)
        XCTAssertNotEqual(store.pinboards.first?.items.first?.id, clip.id)
    }

    func testPinboardCopyPromotedToHistoryGetsIndependentIdentity() {
        let clip = ClipItem(type: .text, text: "Pinned")
        let store = ClipboardStore(
            testingBaseDirectory: directory,
            pinboards: [Pinboard(name: "Saved", items: [clip])]
        )

        let promoted = store.promoteCopiedItem(clip)

        XCTAssertNotEqual(promoted.id, clip.id)
        XCTAssertEqual(store.pinboards.first?.items.first?.id, clip.id)
        XCTAssertEqual(store.history.first?.id, promoted.id)
    }

    func testNewerRemotePresenceDiscardsPendingLocalStackRestoration() throws {
        let deletedAt = Date(timeIntervalSince1970: 1_000)
        let clip = ClipItem(type: .text, text: "Before", createdAt: deletedAt)
        var ledger = ClipDeletionLedger()
        ledger.recordDeletion(
            id: clip.id,
            payload: ClipDeletionPayload(
                history: [HistoryClipPlacement(index: 0, item: clip)],
                pinboards: [], pasteStackEntries: []
            ),
            at: deletedAt
        )
        try writeStore(history: [], ledger: ledger)
        let stackEntry = PasteStackEntry(item: clip.copiedWithFreshID(), originHistoryID: clip.id)
        let placement = PasteStackEntryPlacement(
            stackID: UUID(), stackCreatedAt: deletedAt, stackUpdatedAt: deletedAt,
            index: 0, entry: stackEntry
        )
        let original = StackFile(
            version: 1, stacks: [], pendingRestorations: [clip.id: [placement]]
        )
        let stackURL = try writeStackData(JSONEncoder().encode(original))
        let store = ClipboardStore(testingBaseDirectory: directory, loadExisting: true)
        let remote = ClipItem(
            id: clip.id, type: .text, text: "Remote edit",
            createdAt: deletedAt, updatedAt: deletedAt.addingTimeInterval(20)
        )

        store.applyRemote(
            clips: [.init(item: remote, container: CKSchema.historyContainerValue, imageAssetURL: nil)],
            boards: [], deletedIDs: [], at: deletedAt.addingTimeInterval(20)
        )

        let saved = try JSONDecoder().decode(StackFile.self, from: Data(contentsOf: stackURL))
        XCTAssertTrue(saved.pendingRestorations.isEmpty)
        XCTAssertEqual(store.history.first?.text, "Remote edit")
    }

    func testOlderRemoteClipDoesNotReplaceNewerLocalEdit() {
        let id = UUID()
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = older.addingTimeInterval(10)
        let local = ClipItem(
            id: id, type: .text, text: "Newer local edit",
            createdAt: older, updatedAt: newer
        )
        let remote = ClipItem(
            id: id, type: .text, text: "Stale remote edit",
            createdAt: older, updatedAt: older
        )
        let store = ClipboardStore(testingBaseDirectory: directory, history: [local])

        store.applyRemote(
            clips: [.init(item: remote, container: CKSchema.historyContainerValue, imageAssetURL: nil)],
            boards: [], deletedIDs: [], at: newer
        )

        XCTAssertEqual(store.history, [local])
    }

    func testReloadedStackImageIsOwnedBeforeItsFileDisappears() throws {
        let pixels = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        pixels.setColor(.red, atX: 0, y: 0)
        let data = try XCTUnwrap(pixels.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent("stack-test.png")
        try data.write(to: url)
        let entry = PasteStackEntry(
            item: ClipItem(type: .image, imageFileName: url.lastPathComponent)
        )

        let materialized = try XCTUnwrap(
            PasteSequence.materializedForPaste(entry, imageURL: url)
        )
        try FileManager.default.removeItem(at: url)

        XCTAssertNotNil(materialized.imagePreview?.tiffRepresentation)
    }

    private func writeStore(
        history: [ClipItem], pinboards: [Pinboard] = [],
        ledger: ClipDeletionLedger? = nil,
        stacks: [SavedPasteStack]? = nil
    ) throws {
        let snapshot = ClipboardStore.Snapshot(
            history: history, pinboards: pinboards, pasteStacks: stacks,
            deletionLedger: ledger, pendingPinboardDeletions: nil
        )
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("store.json"))
    }

    @discardableResult
    private func writeStackData(_ data: Data) throws -> URL {
        let base = directory.appendingPathComponent("Paste Stacks", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("stacks.json")
        try data.write(to: url)
        return url
    }

    private struct StackFile: Codable {
        var version: Int
        var stacks: [SavedPasteStack]
        var pendingRestorations: [UUID: [PasteStackEntryPlacement]] = [:]
    }
}
