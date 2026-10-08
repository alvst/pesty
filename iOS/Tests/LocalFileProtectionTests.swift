import Foundation
import XCTest
@testable import Pesty

final class LocalFileProtectionTests: XCTestCase {
    func testAtomicWritingOptionsRetainProtectionUntilFirstAuthentication() {
        let expected: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        XCTAssertEqual(LocalFileProtection.writingOptions, expected)
    }

    func testNewDirectoryAndAtomicWritesUseBackgroundCompatibleProtection() throws {
        try withDirectory { directory in
            let support = directory.appendingPathComponent("Library", isDirectory: true)
            let file = support.appendingPathComponent("library.json")
            try LocalFileProtection.prepareDirectory(at: support)
            try assertAttributes(of: support, mode: 0o700)

            try Data("old library".utf8).write(to: file, options: [.atomic, .completeFileProtection])
            let bytes = Data("updated library".utf8)
            try bytes.write(to: file, options: LocalFileProtection.writingOptions)
            #if !targetEnvironment(simulator)
            // The simulator does not emulate protected-data metadata.
            let writtenAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual(writtenAttributes[.protectionKey] as? String,
                           FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
            #endif
            try LocalFileProtection.prepareFile(at: file)

            try assertAttributes(of: file, mode: 0o600)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testMigrationUpgradesExistingLibraryAssetsAndCacheWithoutChangingBytes() throws {
        try withDirectory { directory in
            let support = directory.appendingPathComponent("Library", isDirectory: true)
            let assets = support.appendingPathComponent("assets", isDirectory: true)
            let cache = support.appendingPathComponent("ck-system-fields", isDirectory: true)
            for folder in [support, assets, cache] {
                try FileManager.default.createDirectory(
                    at: folder,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o755, .protectionKey: FileProtectionType.complete]
                )
            }
            let files = [support.appendingPathComponent("library.json"),
                         assets.appendingPathComponent("image.image"),
                         cache.appendingPathComponent("record.data")]
            let bytes = Data([0, 1, 2, 128, 255])
            for file in files {
                try bytes.write(to: file, options: [.atomic, .completeFileProtection])
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            }

            try LocalFileProtection.prepareExistingFiles(in: support)
            try LocalFileProtection.prepareExistingFiles(in: support)

            for folder in [support, assets, cache] { try assertAttributes(of: folder, mode: 0o700) }
            for file in files {
                try assertAttributes(of: file, mode: 0o600)
                XCTAssertEqual(try Data(contentsOf: file), bytes)
            }
        }
    }

    func testFailedMigrationCanRetryAtTheSamePath() throws {
        try withDirectory { directory in
            let support = directory.appendingPathComponent("Library", isDirectory: true)
            try Data("not a directory".utf8).write(to: support)
            XCTAssertThrowsError(try LocalFileProtection.prepareExistingFiles(in: support))
            try FileManager.default.removeItem(at: support)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let file = support.appendingPathComponent("library.json")
            let bytes = Data("retained library".utf8)
            try bytes.write(to: file, options: [.atomic, .completeFileProtection])

            try LocalFileProtection.prepareExistingFiles(in: support)

            try assertAttributes(of: file, mode: 0o600)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testMigrationSkipsSymbolicLinksWithoutChangingTheirTargets() throws {
        try withDirectory { directory in
            let support = directory.appendingPathComponent("Library", isDirectory: true)
            let outside = directory.appendingPathComponent("Outside", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: outside,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755, .protectionKey: FileProtectionType.complete]
            )
            let target = outside.appendingPathComponent("keep.txt")
            let bytes = Data("outside the library".utf8)
            try bytes.write(to: target, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
            let fileLink = support.appendingPathComponent("linked-file")
            let directoryLink = support.appendingPathComponent("linked-directory", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: target)
            try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: outside)

            try LocalFileProtection.prepareExistingFiles(in: support)

            try assertAttributes(of: outside, mode: 0o755, protection: .complete)
            try assertAttributes(of: target, mode: 0o644, protection: .complete)
            XCTAssertEqual(try Data(contentsOf: target), bytes)
            XCTAssertThrowsError(try LocalFileProtection.prepareFile(at: fileLink))
            XCTAssertThrowsError(try LocalFileProtection.prepareDirectory(at: directoryLink))
            XCTAssertThrowsError(try LocalFileProtection.prepareExistingFiles(in: directoryLink))
            try assertAttributes(of: outside, mode: 0o755, protection: .complete)
            try assertAttributes(of: target, mode: 0o644, protection: .complete)
        }
    }

    private func assertAttributes(
        of url: URL,
        mode: Int,
        protection: FileProtectionType = .completeUntilFirstUserAuthentication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, mode, file: file, line: line)
        #if !targetEnvironment(simulator)
        // The simulator does not emulate protected-data metadata.
        XCTAssertEqual(attributes[.protectionKey] as? String, protection.rawValue, file: file, line: line)
        #endif
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PestyFileProtectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
