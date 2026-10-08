import Foundation
import XCTest
@testable import Pesty

final class LocalLibraryPersistenceTests: XCTestCase {
    func testMigrationIncludesAssetsWhenSharedDirectoryAlreadyExists() throws {
        try withDirectories { legacy, shared in
            let originalBytes = try writeLibrary(library("legacy"), in: legacy)
            let image = Data([0, 1, 2, 255])
            try write(image, to: legacy.appendingPathComponent("assets/photo.image"))
            try write(Data("sync state".utf8), to: legacy.appendingPathComponent("cksync-state.json"))
            try write(Data("keep".utf8), to: shared.appendingPathComponent("unrelated.txt"))

            XCTAssertEqual(resolve(legacy, shared), shared)

            XCTAssertEqual(try texts(in: shared), ["legacy"])
            XCTAssertEqual(try Data(contentsOf: shared.appendingPathComponent("assets/photo.image")), image)
            XCTAssertEqual(try Data(contentsOf: shared.appendingPathComponent("cksync-state.json")), Data("sync state".utf8))
            XCTAssertEqual(try Data(contentsOf: shared.appendingPathComponent("unrelated.txt")), Data("keep".utf8))
            XCTAssertEqual(try Data(contentsOf: backup(in: legacy)), originalBytes)
            XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("assets/photo.image")), image)
        }
    }

    func testSharedLibraryCreatedBeforeMainAppMigrationIsMerged() throws {
        try withDirectories { legacy, shared in
            try writeLibrary(library("legacy"), in: legacy)
            try writeLibrary(library("shared"), in: shared)
            let state = Data("current shared sync state".utf8)
            try write(state, to: shared.appendingPathComponent("cksync-state.json"))
            try write(Data("old state".utf8), to: legacy.appendingPathComponent("cksync-state.json"))

            XCTAssertEqual(resolve(legacy, shared), shared)
            XCTAssertEqual(try texts(in: shared), ["legacy", "shared"])
            XCTAssertEqual(try Data(contentsOf: shared.appendingPathComponent("cksync-state.json")), state)
        }
    }

    func testMigrationHydratesBothStoresSidecarsBeforePublishingMergedMetadata() throws {
        try withDirectories { legacy, shared in
            let legacyClip = PestyClip(kind: .text, text: String(repeating: "legacy", count: 15_000))
            let sharedClip = PestyClip(kind: .richText, text: "shared",
                                       richTextData: Data(repeating: 0x52, count: 80_000))
            try LocalLibraryPersistence.save(PestyLibrary(clips: [legacyClip]),
                                             to: legacy.appendingPathComponent("library.json"))
            try LocalLibraryPersistence.save(PestyLibrary(clips: [sharedClip]),
                                             to: shared.appendingPathComponent("library.json"))

            XCTAssertEqual(resolve(legacy, shared), shared)

            let merged = try LocalLibraryPersistence.loadThrowing(
                from: shared.appendingPathComponent("library.json")
            )
            XCTAssertEqual(merged.clip(id: legacyClip.id)?.text, legacyClip.text)
            XCTAssertEqual(merged.clip(id: sharedClip.id)?.richTextData, sharedClip.richTextData)
            XCTAssertTrue(FileManager.default.fileExists(atPath: backup(in: legacy).path))
        }
    }

    func testSharePublishingWhileMainAppStagesMigrationCannotHideLegacyRecords() throws {
        try withDirectories { legacy, shared in
            try writeLibrary(library("legacy"), in: legacy)
            let manager = RacingShareFileManager(destination: shared.appendingPathComponent("library.json"),
                                                 data: try JSONEncoder.pesty.encode(library("concurrent share")))

            XCTAssertEqual(LocalLibraryPersistence.resolveSupportDirectory(
                sharedDirectory: shared, legacyDirectory: legacy, fileManager: manager), shared)
            XCTAssertEqual(try texts(in: shared), ["legacy", "concurrent share"])
        }
    }

    func testCompletedMigrationDoesNotReplayBackupAfterSharedLibraryIsCleared() throws {
        try withDirectories { legacy, shared in
            let originalBytes = try writeLibrary(library("legacy"), in: legacy)
            XCTAssertEqual(resolve(legacy, shared), shared)
            try FileManager.default.removeItem(at: shared.appendingPathComponent("library.json"))

            XCTAssertEqual(resolve(legacy, shared), shared)
            XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("library.json").path))
            XCTAssertEqual(try Data(contentsOf: backup(in: legacy)), originalBytes)
            try writeLibrary(library("stale legacy writer"), in: legacy)
            XCTAssertEqual(resolve(legacy, shared), shared)
            XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("library.json").path))
        }
    }

    func testConflictingAssetIsRenamedWithoutChangingEitherStoresPixels() throws {
        try withDirectories { legacy, shared in
            var oldLibrary = library("legacy")
            oldLibrary.clips[0].imageAssetID = "photo.image"
            var newLibrary = library("shared")
            newLibrary.clips[0].imageAssetID = "photo.image"
            let originalBytes = try writeLibrary(oldLibrary, in: legacy)
            try writeLibrary(newLibrary, in: shared)
            let legacyPixels = Data("legacy pixels".utf8)
            let sharedPixels = Data("shared pixels".utf8)
            try write(legacyPixels, to: legacy.appendingPathComponent("assets/photo.image"))
            try write(sharedPixels, to: shared.appendingPathComponent("assets/photo.image"))

            XCTAssertEqual(resolve(legacy, shared), shared)
            let merged = try readLibrary(in: shared)
            let renamedAsset = try XCTUnwrap(merged.clips.first(where: { $0.text == "legacy" })?.imageAssetID)
            XCTAssertNotEqual(renamedAsset, "photo.image")
            XCTAssertEqual(try texts(in: shared), ["legacy", "shared"])
            XCTAssertEqual(try Data(contentsOf: shared.appendingPathComponent("assets/\(renamedAsset)")), legacyPixels)
            XCTAssertEqual(try Data(contentsOf: shared.appendingPathComponent("assets/photo.image")), sharedPixels)
            XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("assets/photo.image")), legacyPixels)
            XCTAssertEqual(try Data(contentsOf: backup(in: legacy)), originalBytes)
        }
    }

    func testFailedCopyKeepsLegacyWithoutPublishingEmptySharedLibrary() throws {
        try withDirectories { legacy, shared in
            let originalBytes = try writeLibrary(library("legacy"), in: legacy)
            XCTAssertEqual(LocalLibraryPersistence.resolveSupportDirectory(
                sharedDirectory: shared, legacyDirectory: legacy, fileManager: FailingCopyFileManager()), legacy)
            XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("library.json").path))
            XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("library.json")), originalBytes)
        }
    }

    func testIdenticalExistingAssetAllowsMigration() throws {
        try withDirectories { legacy, shared in
            try writeLibrary(library("legacy"), in: legacy)
            let bytes = Data("same image".utf8)
            for directory in [legacy, shared] {
                try write(bytes, to: directory.appendingPathComponent("assets/photo.image"))
            }
            XCTAssertEqual(resolve(legacy, shared), shared)
            XCTAssertEqual(try texts(in: shared), ["legacy"])
            XCTAssertEqual(try Data(contentsOf: shared.appendingPathComponent("assets/photo.image")), bytes)
        }
    }

    func testUnreadableSharedDirectoryRemainsAuthoritative() throws {
        try withDirectories { legacy, shared in
            try writeLibrary(library("legacy"), in: legacy)
            try writeLibrary(library("shared"), in: shared)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: shared.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shared.path) }
            XCTAssertEqual(resolve(legacy, shared), shared)
        }
    }

    func testMalformedSharedLibraryIsNotReplacedDuringMigration() throws {
        try withDirectories { legacy, shared in
            try writeLibrary(library("legacy"), in: legacy)
            let broken = Data("not valid JSON".utf8)
            try write(broken, to: shared.appendingPathComponent("library.json"))
            XCTAssertEqual(resolve(legacy, shared), shared)
            XCTAssertEqual(try Data(contentsOf: shared.appendingPathComponent("library.json")), broken)
            XCTAssertFalse(FileManager.default.fileExists(atPath: backup(in: legacy).path))
        }
    }

    func testSaveMergesDiskRecordsWithNewInMemoryClip() throws {
        try withDirectories { _, shared in
            try writeLibrary(library("existing disk record"), in: shared)
            let url = shared.appendingPathComponent("library.json")
            try LocalLibraryPersistence.save(library("new memory record"), to: url)
            XCTAssertEqual(try texts(in: shared), ["existing disk record", "new memory record"])
        }
    }

    func testLegacyLargeInlinePayloadMigratesToSidecarAndRoundTrips() throws {
        try withDirectories { _, shared in
            let text = String(repeating: "Long note 📝", count: 12_000)
            let rtf = Data(repeating: 0x7B, count: 90_000)
            let clip = PestyClip(kind: .richText, text: text, richTextData: rtf)
            let url = shared.appendingPathComponent("library.json")
            try writeLibrary(PestyLibrary(clips: [clip]), in: shared)

            let legacy = try LocalLibraryPersistence.loadThrowing(from: url)
            XCTAssertEqual(legacy.clip(id: clip.id)?.text, text)
            try LocalLibraryPersistence.save(legacy, to: url)

            let compact = try Data(contentsOf: url)
            XCTAssertLessThan(compact.count, 5_000)
            let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: compact) as? [String: Any])
            let reference = try XCTUnwrap((stored["payloadFiles"] as? [String: String])?[clip.id.uuidString])
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: shared.appendingPathComponent("payloads/\(reference)").path
            ))
            let reloaded = try LocalLibraryPersistence.loadThrowing(from: url)
            XCTAssertEqual(reloaded.clip(id: clip.id)?.text, text)
            XCTAssertEqual(reloaded.clip(id: clip.id)?.richTextData, rtf)
        }
    }

    func testMissingSidecarBlocksLoadAndSaveWithoutReplacingMetadata() throws {
        try withDirectories { _, shared in
            let clip = PestyClip(kind: .text, text: String(repeating: "X", count: 80_000))
            let url = shared.appendingPathComponent("library.json")
            try LocalLibraryPersistence.save(PestyLibrary(clips: [clip]), to: url)
            let metadata = try Data(contentsOf: url)
            let payloads = shared.appendingPathComponent("payloads")
            let sidecar = try XCTUnwrap(FileManager.default.contentsOfDirectory(
                at: payloads, includingPropertiesForKeys: nil
            ).first)
            try FileManager.default.removeItem(at: sidecar)

            XCTAssertThrowsError(try LocalLibraryPersistence.loadThrowing(from: url))
            XCTAssertThrowsError(try LocalLibraryPersistence.save(PestyLibrary(), to: url))
            XCTAssertEqual(try Data(contentsOf: url), metadata)
        }
    }

    func testCorruptOrphanSidecarIsRepairedBeforeItIsReferenced() throws {
        try withDirectories { _, shared in
            let clip = PestyClip(kind: .text, text: String(repeating: "Recover", count: 12_000))
            let library = PestyLibrary(clips: [clip])
            let url = shared.appendingPathComponent("library.json")
            try LocalLibraryPersistence.save(library, to: url)
            let sidecar = try XCTUnwrap(FileManager.default.contentsOfDirectory(
                at: shared.appendingPathComponent("payloads"), includingPropertiesForKeys: nil
            ).first)
            try FileManager.default.removeItem(at: url)
            try Data("corrupt".utf8).write(to: sidecar)

            try LocalLibraryPersistence.save(library, to: url)

            XCTAssertEqual(try LocalLibraryPersistence.loadThrowing(from: url).clip(id: clip.id)?.text,
                           clip.text)
        }
    }

    func testCorruptReferencedSidecarBlocksSaveWithoutReplacingMetadata() throws {
        try withDirectories { _, shared in
            let clip = PestyClip(kind: .text, text: String(repeating: "Protected", count: 12_000))
            let url = shared.appendingPathComponent("library.json")
            try LocalLibraryPersistence.save(PestyLibrary(clips: [clip]), to: url)
            let metadata = try Data(contentsOf: url)
            let sidecar = try XCTUnwrap(FileManager.default.contentsOfDirectory(
                at: shared.appendingPathComponent("payloads"), includingPropertiesForKeys: nil
            ).first)
            try Data("corrupt".utf8).write(to: sidecar)

            XCTAssertThrowsError(try LocalLibraryPersistence.loadThrowing(from: url))
            XCTAssertThrowsError(try LocalLibraryPersistence.save(PestyLibrary(), to: url))
            XCTAssertEqual(try Data(contentsOf: url), metadata)
        }
    }

    func testCancelledQueuedDeferredSaveCannotRecreateClearedLibrary() async throws {
        try await withDirectoriesAsync { _, shared in
            let url = shared.appendingPathComponent("library.json")
            let pending = PestyLibrary(clips: [PestyClip(kind: .text, text: "Pending")])
            let started = DispatchSemaphore(value: 0)
            let task: Task<Void, Error> = try LocalLibraryPersistence.withExclusiveAccess {
                let task = Task.detached {
                    started.signal()
                    try LocalLibraryPersistence.saveDeferred(pending, to: url)
                }
                XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
                task.cancel()
                try LocalLibraryPersistence.removeAll(in: shared)
                return task
            }
            do {
                try await task.value
                XCTFail("The canceled save must stop after reset.")
            } catch is CancellationError {
                // The canceled writer saw reset before publishing metadata.
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testFinalizedDeletionRemovesItsSidecarAfterMetadataCommit() throws {
        try withDirectories { _, shared in
            let clip = PestyClip(kind: .text, text: String(repeating: "Private", count: 15_000))
            let url = shared.appendingPathComponent("library.json")
            try LocalLibraryPersistence.save(PestyLibrary(clips: [clip]), to: url)
            let payloads = shared.appendingPathComponent("payloads")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: payloads.path).count, 1)
            let unrelated = payloads.appendingPathComponent("other.json")
            try Data("unrelated".utf8).write(to: unrelated)

            try LocalLibraryPersistence.update(at: url) { library in
                library.clips[0].deletionFinalizedAt = .now
                library.clips[0].redactFinalizedPayload()
            }

            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: payloads.path), ["other.json"])
            XCTAssertNil(try LocalLibraryPersistence.loadThrowing(from: url).clips[0].text)
        }
    }

    func testSaveAndUpdateRefuseMalformedExistingLibrary() throws {
        try withDirectories { _, shared in
            let broken = Data("not valid JSON".utf8)
            let url = shared.appendingPathComponent("library.json")
            try write(broken, to: url)
            XCTAssertThrowsError(try LocalLibraryPersistence.loadThrowing(from: url))
            XCTAssertThrowsError(try LocalLibraryPersistence.save(library("new"), to: url))
            var transformed = false
            XCTAssertThrowsError(try LocalLibraryPersistence.update(at: url) { _ in transformed = true })
            XCTAssertFalse(transformed)
            XCTAssertEqual(try Data(contentsOf: url), broken)
        }
    }

    func testFractionalDatesSurvivePersistenceAndLegacyDatesStillDecode() throws {
        let captured = Date(timeIntervalSince1970: 1_700_000_000.321)
        let updated = Date(timeIntervalSince1970: 1_700_000_000.654)
        let clip = PestyClip(kind: .text, text: "Precise", capturedAt: captured, updatedAt: updated)
        let original = PestyLibrary(clips: [clip], updatedAt: updated)
        let encoded = try JSONEncoder.pesty.encode(original)
        let decoded = try JSONDecoder.pesty.decode(PestyLibrary.self, from: encoded)
        XCTAssertEqual(try XCTUnwrap(decoded.clip(id: clip.id)).updatedAt.timeIntervalSince1970,
                       updated.timeIntervalSince1970, accuracy: 0.001)

        let legacy = String(decoding: encoded, as: UTF8.self)
            .replacingOccurrences(of: "2023-11-14T22:13:20.321Z", with: "2023-11-14T22:13:20Z")
        XCTAssertNoThrow(try JSONDecoder.pesty.decode(PestyLibrary.self, from: Data(legacy.utf8)))
    }

    func testWidgetSnapshotIsBoundedForLargeClipPayloads() throws {
        try withDirectories { _, shared in
            let clip = PestyClip(kind: .richText, text: String(repeating: "A", count: 200_000),
                                 richTextData: Data(repeating: 0x42, count: 500_000))
            try LocalLibraryPersistence.save(PestyLibrary(clips: [clip]),
                                             to: shared.appendingPathComponent("library.json"))
            let snapshot = try Data(contentsOf: shared.appendingPathComponent("widget-snapshot.json"))
            XCTAssertLessThan(snapshot.count, 5_000)
            let json = String(decoding: snapshot, as: UTF8.self)
            XCTAssertFalse(json.contains("richTextData"))
            XCTAssertFalse(json.contains(String(repeating: "A", count: 513)))
        }
    }

    func testShareInboxDoesNotReadOrRewriteTheLibrary() throws {
        try withDirectories { _, shared in
            let libraryURL = shared.appendingPathComponent("library.json")
            let unreadableLibrary = Data("not valid JSON".utf8)
            try write(unreadableLibrary, to: libraryURL)
            let clip = PestyClip(kind: .image, imageAssetID: "shared.image", imageHash: "hash")

            try LocalLibraryPersistence.enqueueSharedClip(clip, in: shared)

            let items = try LocalLibraryPersistence.loadSharedInbox(in: shared)
            XCTAssertEqual(items.map(\.clip.id), [clip.id])
            XCTAssertEqual(items.first?.clip.imageAssetID, clip.imageAssetID)
            XCTAssertEqual(try Data(contentsOf: libraryURL), unreadableLibrary)
            try LocalLibraryPersistence.acknowledgeSharedInbox(items)
            XCTAssertTrue(try LocalLibraryPersistence.loadSharedInbox(in: shared).isEmpty)
        }
    }

    func testMalformedInboxEntryCannotHideAValidShare() throws {
        try withDirectories { _, shared in
            let clip = PestyClip(kind: .text, text: "Keep me")
            try LocalLibraryPersistence.enqueueSharedClip(clip, in: shared)
            try write(Data("broken".utf8), to: shared.appendingPathComponent("inbox/broken.json"))

            XCTAssertThrowsError(try LocalLibraryPersistence.loadSharedInbox(in: shared))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: shared.appendingPathComponent("inbox/\(clip.id.uuidString).json").path
            ))
        }
    }

    func testExplicitLocalResetClearsInbox() throws {
        try withDirectories { _, shared in
            try LocalLibraryPersistence.save(
                PestyLibrary(clips: [PestyClip(kind: .text, text: String(repeating: "E", count: 80_000))]),
                to: shared.appendingPathComponent("library.json")
            )
            try LocalLibraryPersistence.enqueueSharedClip(PestyClip(kind: .text, text: "pending"), in: shared)

            try LocalLibraryPersistence.removeAll(in: shared)

            XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("library.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("payloads").path))
            XCTAssertTrue(try LocalLibraryPersistence.loadSharedInbox(in: shared).isEmpty)
        }
    }

    func testFailedLocalResetRestoresPendingInbox() throws {
        try withDirectories { _, shared in
            try writeLibrary(library("existing"), in: shared)
            let pending = PestyClip(kind: .text, text: "pending")
            try LocalLibraryPersistence.enqueueSharedClip(pending, in: shared)

            XCTAssertThrowsError(try LocalLibraryPersistence.removeAll(
                in: shared, fileManager: FailingLibraryMoveFileManager()
            ))

            XCTAssertEqual(try texts(in: shared), ["existing"])
            XCTAssertEqual(try LocalLibraryPersistence.loadSharedInbox(in: shared).map(\.clip.id), [pending.id])
        }
    }

    func testShareInboxKeepsWidgetSnapshotSmall() throws {
        try withDirectories { _, shared in
            let clip = PestyClip(kind: .richText, text: String(repeating: "A", count: 200_000),
                                 richTextData: Data(repeating: 0x42, count: 500_000))

            try LocalLibraryPersistence.enqueueSharedClip(clip, in: shared)

            let snapshot = try Data(contentsOf: shared.appendingPathComponent("widget-snapshot.json"))
            XCTAssertLessThan(snapshot.count, 5_000)
            let json = String(decoding: snapshot, as: UTF8.self)
            XCTAssertTrue(json.contains(clip.id.uuidString))
            XCTAssertFalse(json.contains("richTextData"))
        }
    }

    func testSaveAndUpdateRefuseUnreadableLibraryItem() throws {
        try withDirectories { _, shared in
            // A directory in place of JSON produces a read error even under
            // privileged test runners that bypass Unix permission bits.
            let url = shared.appendingPathComponent("library.json", isDirectory: true)
            let retained = url.appendingPathComponent("keep.txt")
            let bytes = Data("keep existing data".utf8)
            try write(bytes, to: retained)
            XCTAssertThrowsError(try LocalLibraryPersistence.save(library("new"), to: url))
            XCTAssertThrowsError(try LocalLibraryPersistence.update(at: url) { $0 = self.library("new") })
            XCTAssertEqual(try Data(contentsOf: retained), bytes)
        }
    }

    func testNoGroupUsesLegacyAndNoLegacyLibrarySelectsShared() throws {
        try withDirectories { legacy, shared in
            XCTAssertEqual(LocalLibraryPersistence.resolveSupportDirectory(
                sharedDirectory: nil, legacyDirectory: legacy), legacy)
            XCTAssertEqual(resolve(legacy, shared), shared)
            XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("library.json").path))
        }
    }

    private func library(_ text: String) -> PestyLibrary {
        let date = Date(timeIntervalSince1970: 1_000)
        return PestyLibrary(clips: [PestyClip(kind: .text, text: text, capturedAt: date, updatedAt: date)],
                            updatedAt: date)
    }

    @discardableResult
    private func writeLibrary(_ library: PestyLibrary, in directory: URL) throws -> Data {
        let data = try JSONEncoder.pesty.encode(library)
        try write(data, to: directory.appendingPathComponent("library.json"))
        return data
    }

    private func readLibrary(in directory: URL) throws -> PestyLibrary {
        try JSONDecoder.pesty.decode(PestyLibrary.self,
                                      from: Data(contentsOf: directory.appendingPathComponent("library.json")))
    }

    private func texts(in directory: URL) throws -> Set<String> {
        Set(try readLibrary(in: directory).activeClips.compactMap(\.text))
    }

    private func backup(in legacy: URL) -> URL {
        legacy.appendingPathComponent(LocalLibraryPersistence.migratedLegacyFileName)
    }

    private func resolve(_ legacy: URL, _ shared: URL) -> URL {
        LocalLibraryPersistence.resolveSupportDirectory(sharedDirectory: shared, legacyDirectory: legacy)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func withDirectories(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PestyLibraryPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        for directory in [legacy, shared] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try body(legacy, shared)
    }

    private func withDirectoriesAsync(_ body: (URL, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PestyLibraryPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        for directory in [legacy, shared] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try await body(legacy, shared)
    }
}

private final class FailingCopyFileManager: FileManager, @unchecked Sendable {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileReadNoPermission)
    }
}

private final class RacingShareFileManager: FileManager, @unchecked Sendable {
    let destination: URL
    let data: Data

    init(destination: URL, data: Data) {
        self.destination = destination
        self.data = data
        super.init()
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try super.copyItem(at: srcURL, to: dstURL)
        try data.write(to: destination, options: .atomic)
    }
}

private final class FailingLibraryMoveFileManager: FileManager, @unchecked Sendable {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.lastPathComponent == "library.json" {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
