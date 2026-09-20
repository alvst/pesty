import Foundation

enum LocalLibraryPersistence {
    static let appGroupIdentifier = "group.com.alvst.pesty"
    private static let directoryName = "Pesty"
    private static let fileName = "library.json"
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

    static func load() -> PestyLibrary {
        // Metadata upgrades are retryable if an older fully protected file
        // was unavailable during an earlier background launch.
        try? LocalFileProtection.prepareExistingFiles(in: supportDirectory)
        guard let data = try? Data(contentsOf: libraryURL()),
              let library = try? JSONDecoder.pesty.decode(PestyLibrary.self, from: data) else {
            return PestyLibrary()
        }
        return library
    }

    static func save(_ library: PestyLibrary) throws {
        try prepareDirectory()
        try save(library, to: libraryURL())
    }

    /// Read and merge inside coordination so a share extension or a recovered
    /// protected file cannot be overwritten by an older in-memory snapshot.
    static func save(_ library: PestyLibrary, to url: URL) throws {
        try LocalFileProtection.prepareDirectory(at: url.deletingLastPathComponent())
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

    static func removeAll() throws {
        let url = libraryURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func libraryURL() -> URL {
        supportDirectory
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private static func prepareDirectory() throws {
        try LocalFileProtection.prepareDirectory(at: supportDirectory)
        try LocalFileProtection.prepareExistingFiles(in: supportDirectory)
    }

    private static func readLibrary(from url: URL) throws -> PestyLibrary {
        if isDefinitelyMissing(url) { return PestyLibrary() }
        return try JSONDecoder.pesty.decode(PestyLibrary.self, from: Data(contentsOf: url))
    }

    private static func write(_ library: PestyLibrary, to url: URL) throws {
        let data = try JSONEncoder.pesty.encode(library)
        try data.write(to: url, options: LocalFileProtection.writingOptions)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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

extension JSONEncoder {
    static var pesty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var pesty: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
