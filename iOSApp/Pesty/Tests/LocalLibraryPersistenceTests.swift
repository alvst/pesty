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

    func testSaveAndUpdateRefuseMalformedExistingLibrary() throws {
        try withDirectories { _, shared in
            let broken = Data("not valid JSON".utf8)
            let url = shared.appendingPathComponent("library.json")
            try write(broken, to: url)
            XCTAssertThrowsError(try LocalLibraryPersistence.save(library("new"), to: url))
            var transformed = false
            XCTAssertThrowsError(try LocalLibraryPersistence.update(at: url) { _ in transformed = true })
            XCTAssertFalse(transformed)
            XCTAssertEqual(try Data(contentsOf: url), broken)
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
