import Foundation
import CryptoKit

enum LocalLibraryPersistence {
    static let appGroupIdentifier = "group.com.alvst.pesty"
    private static let directoryName = "Pesty"
    private static let fileName = "library.json"
    private static let inboxDirectoryName = "inbox"
    private static let widgetSnapshotFileName = "widget-snapshot.json"
    private static let payloadDirectoryName = "payloads"
    private static let sidecarThreshold = 64 * 1024
    private static let ioLock = NSRecursiveLock()
    static let migratedLegacyFileName = "library.migrated-to-shared.json"

    // Library, assets, and sync state must keep using the same root throughout
    // this process, including when an attempted migration cannot finish.
    static let supportDirectory: URL = resolveSupportDirectory(
        sharedDirectory: FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )?.appendingPathComponent(directoryName, isDirectory: true),
        legacyDirectory: legacySupportDirectory
    )

    private static var legacySupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The main app must distinguish an absent library from one it cannot
    /// read. Treating a decode or file-protection failure as an empty library
    /// would make the sync engine delete every record in its shadow.
    static func loadThrowing() throws -> PestyLibrary {
        try loadThrowing(from: libraryURL())
    }

    static func loadThrowing(from url: URL) throws -> PestyLibrary {
        ioLock.lock()
        defer { ioLock.unlock() }
        // Metadata upgrades are retryable if an older fully protected file
        // was unavailable during an earlier background launch.
        try LocalFileProtection.prepareExistingFiles(in: url.deletingLastPathComponent())
        return try readLibrary(from: url)
    }

    static func save(_ library: PestyLibrary) throws {
        try save(library, to: libraryURL())
    }

    /// The background writer checks cancellation after taking the same lock
    /// as a local reset. A canceled, queued save cannot recreate a library
    /// that the user has just cleared.
    static func saveDeferred(_ library: PestyLibrary) throws {
        try saveDeferred(library, to: libraryURL())
    }

    static func saveDeferred(_ library: PestyLibrary, to url: URL) throws {
        try save(library, to: url, checkingCancellation: true)
    }

    /// Read and merge inside coordination so a share extension or a recovered
    /// protected file cannot be overwritten by an older in-memory snapshot.
    static func save(_ library: PestyLibrary, to url: URL) throws {
        try save(library, to: url, checkingCancellation: false)
    }

    private static func save(_ library: PestyLibrary, to url: URL,
                             checkingCancellation: Bool) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        if checkingCancellation { try Task<Never, Never>.checkCancellation() }
        try LocalFileProtection.prepareDirectory(at: url.deletingLastPathComponent())
        try LocalFileProtection.prepareExistingFiles(in: url.deletingLastPathComponent())
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                let diskLibrary = try readLibrary(from: coordinatedURL)
                try write(library.merged(with: diskLibrary), to: coordinatedURL)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    /// Performs an inter-process-safe read/modify/write for app extensions.
    /// The main app still merges the shared file whenever it becomes active,
    /// so a share completed while the app is suspended cannot be lost.
    @discardableResult
    static func update(_ transform: (inout PestyLibrary) throws -> Void) throws -> PestyLibrary {
        try prepareDirectory()
        return try update(at: libraryURL(), transform)
    }

    @discardableResult
    static func update(at url: URL, _ transform: (inout PestyLibrary) throws -> Void) throws -> PestyLibrary {
        ioLock.lock()
        defer { ioLock.unlock() }
        try LocalFileProtection.prepareDirectory(at: url.deletingLastPathComponent())
        var coordinationError: NSError?
        var updateError: Error?
        var result = PestyLibrary()
        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                var library = try readLibrary(from: coordinatedURL)
                try transform(&library)
                try write(library, to: coordinatedURL)
                result = library
            } catch {
                updateError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let updateError { throw updateError }
        return result
    }

    static func removeAll(in directory: URL = supportDirectory,
                          fileManager: FileManager = .default) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard !isDefinitelyMissing(directory) else { return }
        // Move both sources of library content out of their live paths before
        // deleting either. If the second move fails, restore the first one so
        // a failed reset cannot lose pending shares or expose an empty library.
        let staging = directory.appendingPathComponent(".reset-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        var moved: [(source: URL, staged: URL)] = []
        do {
            for source in [inboxURL(in: directory), payloadDirectory(in: directory),
                           directory.appendingPathComponent(fileName)]
            where !isDefinitelyMissing(source) {
                let staged = staging.appendingPathComponent(source.lastPathComponent)
                try fileManager.moveItem(at: source, to: staged)
                moved.append((source, staged))
            }
        } catch {
            for item in moved.reversed() {
                try? fileManager.moveItem(at: item.staged, to: item.source)
            }
            try? fileManager.removeItem(at: staging)
            throw error
        }
        // The live paths are gone. A failed physical cleanup must not make
        // clearLocalLibrary keep its old in-memory state over an empty disk.
        try? fileManager.removeItem(at: staging)
        let snapshot = directory.appendingPathComponent(widgetSnapshotFileName)
        try? fileManager.removeItem(at: snapshot)
    }

    static func libraryURL() -> URL {
        supportDirectory
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// Keeps a multi-step local operation ordered with saves and resets.
    @discardableResult
    static func withExclusiveAccess<Value>(_ operation: () throws -> Value) rethrows -> Value {
        ioLock.lock()
        defer { ioLock.unlock() }
        return try operation()
    }

    struct SharedInboxItem: Sendable {
        let clip: PestyClip
        let url: URL
    }

    /// A share extension publishes one small file per clip. It never needs to
    /// decode the library, and a failed item cannot discard earlier shares.
    static func enqueueSharedClip(_ clip: PestyClip, in directory: URL = supportDirectory) throws {
        let inbox = inboxURL(in: directory)
        try LocalFileProtection.prepareDirectory(at: directory)
        try LocalFileProtection.prepareDirectory(at: inbox)
        let url = inbox.appendingPathComponent("\(clip.id.uuidString).json")
        let data = try PestyJSON.encode(clip)
        try data.write(to: url, options: LocalFileProtection.writingOptions)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        updateWidgetSnapshot(with: clip, in: directory)
    }

    static func loadSharedInbox(in directory: URL = supportDirectory) throws -> [SharedInboxItem] {
        let inbox = inboxURL(in: directory)
        if isDefinitelyMissing(inbox) { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { url in
            let clip = try PestyJSON.decode(PestyClip.self, from: Data(contentsOf: url))
            guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) == clip.id else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return SharedInboxItem(clip: clip, url: url)
        }
    }

    /// Call only after the merged library has been saved. A failed removal is
    /// harmless: the clip UUID makes the next import idempotent.
    static func acknowledgeSharedInbox(_ items: [SharedInboxItem]) throws {
        for item in items {
            try FileManager.default.removeItem(at: item.url)
        }
    }

    private static func inboxURL(in directory: URL) -> URL {
        directory.appendingPathComponent(inboxDirectoryName, isDirectory: true)
    }

    private static func payloadDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent(payloadDirectoryName, isDirectory: true)
    }

    static func loadWidgetSnapshot() -> [PestyClip]? {
        loadWidgetSnapshot(in: supportDirectory)
    }

    private static func loadWidgetSnapshot(in directory: URL) -> [PestyClip]? {
        let url = directory.appendingPathComponent(widgetSnapshotFileName)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? PestyJSON.decode(WidgetSnapshot.self, from: data) else {
            return nil
        }
        return snapshot.clips
    }

    static func ensureWidgetSnapshot(for library: PestyLibrary) {
        guard loadWidgetSnapshot() == nil else { return }
        writeWidgetSnapshot(library, beside: libraryURL())
    }

    private static func prepareDirectory() throws {
        try LocalFileProtection.prepareDirectory(at: supportDirectory)
        try LocalFileProtection.prepareExistingFiles(in: supportDirectory)
    }

    private static func readLibrary(from url: URL) throws -> PestyLibrary {
        if isDefinitelyMissing(url) { return PestyLibrary() }
        let stored = try PestyJSON.decode(StoredLibrary.self, from: Data(contentsOf: url))
        var library = stored.library
        for index in library.clips.indices {
            let clip = library.clips[index]
            guard let fileName = stored.payloadFiles?[clip.id.uuidString] else { continue }
            guard clip.text == nil, clip.richTextData == nil,
                  fileName.hasPrefix("\(clip.id.uuidString)-"),
                  fileName.hasSuffix(".json"),
                  URL(fileURLWithPath: fileName).lastPathComponent == fileName else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let sidecarURL = payloadDirectory(in: url.deletingLastPathComponent())
                .appendingPathComponent(fileName)
            let payload = try PestyJSON.decode(StoredPayload.self, from: Data(contentsOf: sidecarURL))
            guard payload.id == clip.id, payload.fileName == fileName else {
                throw CocoaError(.fileReadCorruptFile)
            }
            library.clips[index].text = payload.text
            library.clips[index].richTextData = payload.richTextData
        }
        return library
    }

    private static func write(_ library: PestyLibrary, to url: URL) throws {
        var compact = library
        var payloadFiles: [String: String] = [:]
        let sidecarDirectory = payloadDirectory(in: url.deletingLastPathComponent())
        for index in compact.clips.indices {
            let clip = compact.clips[index]
            guard (clip.text?.utf8.count ?? 0) > sidecarThreshold || clip.richTextData != nil else { continue }
            let payload = StoredPayload(id: clip.id, text: clip.text, richTextData: clip.richTextData)
            let fileName = payload.fileName
            let sidecarURL = sidecarDirectory.appendingPathComponent(fileName)
            let existingIsValid: Bool
            if isDefinitelyMissing(sidecarURL) {
                existingIsValid = false
            } else {
                let existing = try? PestyJSON.decode(
                    StoredPayload.self, from: Data(contentsOf: sidecarURL)
                )
                existingIsValid = existing?.id == clip.id && existing?.fileName == fileName
            }
            if !existingIsValid {
                try LocalFileProtection.prepareDirectory(at: sidecarDirectory)
                try PestyJSON.encode(payload).write(to: sidecarURL, options: LocalFileProtection.writingOptions)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecarURL.path)
            }
            payloadFiles[clip.id.uuidString] = fileName
            compact.clips[index].text = nil
            compact.clips[index].richTextData = nil
        }
        let data = try PestyJSON.encode(StoredLibrary(library: compact, payloadFiles: payloadFiles))
        try data.write(to: url, options: LocalFileProtection.writingOptions)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        writeWidgetSnapshot(library, beside: url)
        // Sidecars are published before the atomic metadata replacement. Only
        // the now-durable snapshot decides what may be removed; a crash during
        // cleanup leaves extra bytes, never a broken reference.
        pruneUnreferencedPayloads(in: sidecarDirectory, keeping: Set(payloadFiles.values))
    }

    private static func pruneUnreferencedPayloads(in directory: URL, keeping files: Set<String>) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls where isManagedPayloadName(url.lastPathComponent)
                && !files.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func isManagedPayloadName(_ name: String) -> Bool {
        guard name.count == 36 + 1 + 64 + 5, name.hasSuffix(".json") else { return false }
        let id = String(name.prefix(36))
        guard UUID(uuidString: id)?.uuidString == id, name.dropFirst(36).first == "-" else { return false }
        let digest = name.dropFirst(37).prefix(64)
        return digest.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private struct StoredLibrary: Codable {
        var schemaVersion: Int
        var clips: [PestyClip]
        var boards: [PestyBoard]
        var updatedAt: Date
        var payloadFiles: [String: String]?

        init(library: PestyLibrary, payloadFiles: [String: String]) {
            schemaVersion = library.schemaVersion
            clips = library.clips
            boards = library.boards
            updatedAt = library.updatedAt
            self.payloadFiles = payloadFiles.isEmpty ? nil : payloadFiles
        }

        var library: PestyLibrary {
            PestyLibrary(schemaVersion: schemaVersion, clips: clips, boards: boards, updatedAt: updatedAt)
        }
    }

    private struct StoredPayload: Codable {
        var id: UUID
        var text: String?
        var richTextData: Data?

        var fileName: String {
            var hash = SHA256()
            hash.update(data: Data(id.uuidString.utf8))
            hash.update(data: Data([text == nil ? 0 : 1]))
            if let text {
                updateLength(text.utf8.count, in: &hash)
                hash.update(data: Data(text.utf8))
            }
            hash.update(data: Data([richTextData == nil ? 0 : 1]))
            if let richTextData {
                updateLength(richTextData.count, in: &hash)
                hash.update(data: richTextData)
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            return "\(id.uuidString)-\(digest).json"
        }

        private func updateLength(_ length: Int, in hash: inout SHA256) {
            var value = UInt64(length).bigEndian
            withUnsafeBytes(of: &value) { hash.update(data: Data($0)) }
        }
    }

    private static func writeWidgetSnapshot(_ library: PestyLibrary, beside libraryURL: URL) {
        let clips = library.activeClips.prefix(6).map(boundedWidgetClip)
        let url = libraryURL.deletingLastPathComponent().appendingPathComponent(widgetSnapshotFileName)
        writeWidgetSnapshot(clips, to: url)
    }

    private static func updateWidgetSnapshot(with clip: PestyClip, in directory: URL) {
        let existing = loadWidgetSnapshot(in: directory) ?? []
        let clips = Array(([boundedWidgetClip(clip)] + existing.filter { $0.id != clip.id }).prefix(6))
        writeWidgetSnapshot(clips, to: directory.appendingPathComponent(widgetSnapshotFileName))
    }

    private static func boundedWidgetClip(_ original: PestyClip) -> PestyClip {
        var clip = original
        clip.text = original.text.map { String($0.prefix(512)) }
        clip.richTextData = nil
        clip.fileNames = Array(original.fileNames.prefix(4)).map { String($0.prefix(100)) }
        clip.sourceFileURLs = nil
        clip.customTitle = original.customTitle.map { String($0.prefix(100)) }
        clip.sourceAppName = original.sourceAppName.map { String($0.prefix(100)) }
        return clip
    }

    private static func writeWidgetSnapshot(_ clips: [PestyClip], to url: URL) {
        guard let data = try? PestyJSON.encode(WidgetSnapshot(clips: clips)) else { return }
        try? data.write(to: url, options: LocalFileProtection.writingOptions)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private struct WidgetSnapshot: Codable {
        var clips: [PestyClip]
    }

    /// Injectable paths keep migration tests out of the real app containers.
    /// A retained backup marks completed migration, preventing old records
    /// from being replayed after the shared library is subsequently cleared.
    static func resolveSupportDirectory(sharedDirectory: URL?, legacyDirectory: URL,
                                        fileManager: FileManager = .default) -> URL {
        guard let sharedDirectory,
              sharedDirectory.standardizedFileURL != legacyDirectory.standardizedFileURL else {
            return legacyDirectory
        }
        let sharedLibrary = sharedDirectory.appendingPathComponent(fileName)
        let legacyLibrary = legacyDirectory.appendingPathComponent(fileName)
        let legacyBackup = legacyDirectory.appendingPathComponent(migratedLegacyFileName)
        guard !fileManager.fileExists(atPath: legacyBackup.path), !isDefinitelyMissing(legacyLibrary) else {
            return sharedDirectory
        }
        let sharedWasPresent = !isDefinitelyMissing(sharedLibrary)

        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("PestyLibraryMigration-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        do {
            // Copy everything first without touching the legacy library. A
            // locked/unreadable asset must not publish a library missing files.
            try fileManager.copyItem(at: legacyDirectory, to: staging)
            try fileManager.createDirectory(at: sharedDirectory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            var coordinationError: NSError?
            var migrationError: Error?
            NSFileCoordinator().coordinate(writingItemAt: sharedLibrary, options: .forMerging,
                                            error: &coordinationError) { coordinatedURL in
                // Another process may have completed migration while we copied.
                guard !fileManager.fileExists(atPath: legacyBackup.path) else { return }
                do {
                    var legacy = try readLibrary(from: staging.appendingPathComponent(fileName))
                    let shared = try readLibrary(from: coordinatedURL)
                    let contents = try fileManager.contentsOfDirectory(at: staging,
                                                                       includingPropertiesForKeys: nil)
                    for source in contents where source.lastPathComponent != fileName {
                        let destination = sharedDirectory.appendingPathComponent(source.lastPathComponent)
                        if source.lastPathComponent == "assets" {
                            try mergeLegacyAssets(source, into: destination, library: &legacy,
                                                  fileManager: fileManager)
                            continue
                        }
                        // Keep an existing shared sync engine's current state.
                        // Assets, unlike caches, must all match the merged clips.
                        if source.lastPathComponent != "assets",
                           fileManager.fileExists(atPath: destination.path) { continue }
                        try mergeMigrationItem(source, into: destination, fileManager: fileManager)
                    }
                    // Publish the library last, once all its assets are present.
                    try write(shared.merged(with: legacy), to: coordinatedURL)
                    // Atomic rename retains the exact legacy bytes and records
                    // completion without replaying this snapshot on next launch.
                    try fileManager.moveItem(at: legacyLibrary, to: legacyBackup)
                } catch {
                    migrationError = error
                }
            }
            if let coordinationError { throw coordinationError }
            if let migrationError { throw migrationError }
            return sharedDirectory
        } catch {
            // Never replace the usable legacy library with an empty shared one.
            // If a racing process did publish a library, keep that shared root.
            return sharedWasPresent || fileManager.fileExists(atPath: sharedLibrary.path)
                ? sharedDirectory : legacyDirectory
        }
    }

    private static func mergeLegacyAssets(_ source: URL, into destination: URL,
                                          library: inout PestyLibrary, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        for asset in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            var target = destination.appendingPathComponent(asset.lastPathComponent)
            if fileManager.fileExists(atPath: target.path),
               !fileManager.contentsEqual(atPath: asset.path, andPath: target.path) {
                // The same clip may have newer shared pixels, or two stores
                // may have reused a filename. Keep both byte representations.
                let name = "\(UUID().uuidString).image"
                target = destination.appendingPathComponent(name)
                for index in library.clips.indices where library.clips[index].imageAssetID == asset.lastPathComponent {
                    library.clips[index].imageAssetID = name
                }
            }
            try mergeMigrationItem(asset, into: target, fileManager: fileManager)
        }
    }

    private static func mergeMigrationItem(_ source: URL, into destination: URL,
                                            fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: destination.path) else {
            try fileManager.moveItem(at: source, to: destination)
            return
        }
        let sourceIsDirectory = try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let destinationIsDirectory = try destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        if sourceIsDirectory && destinationIsDirectory {
            for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try mergeMigrationItem(child, into: destination.appendingPathComponent(child.lastPathComponent),
                                       fileManager: fileManager)
            }
        } else if !fileManager.contentsEqual(atPath: source.path, andPath: destination.path) {
            // Reusing an asset name with different bytes would corrupt the
            // migrated clip. Preserve both stores and continue using legacy.
            throw CocoaError(.fileWriteFileExists)
        }
    }

    private static func isDefinitelyMissing(_ url: URL) -> Bool {
        do {
            _ = try url.resourceValues(forKeys: [.isRegularFileKey])
            return false
        } catch {
            let error = error as NSError
            return error.domain == NSCocoaErrorDomain
                && [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(error.code)
        }
    }
}

/// Coders are expensive to configure and the full library is processed on
/// every save. Reuse one of each behind separate locks because app and widget
/// work can reach persistence from more than one thread.
private enum PestyJSON {
    private static let encoder = JSONEncoder.pesty
    private static let decoder = JSONDecoder.pesty
    private static let encodeLock = NSLock()
    private static let decodeLock = NSLock()

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        return try encoder.encode(value)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        decodeLock.lock()
        defer { decodeLock.unlock() }
        return try decoder.decode(type, from: data)
    }
}

extension JSONEncoder {
    static var pesty: JSONEncoder {
        let encoder = JSONEncoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var pesty: JSONDecoder {
        let decoder = JSONDecoder()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let legacy = ISO8601DateFormatter()
        legacy.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            let text = try value.decode(String.self)
            if let date = fractional.date(from: text)
                ?? legacy.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid ISO-8601 date")
        }
        return decoder
    }
}
