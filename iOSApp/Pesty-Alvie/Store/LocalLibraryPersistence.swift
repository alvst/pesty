import Foundation

enum LocalLibraryPersistence {
    static let appGroupIdentifier = "group.com.alvst.pesty-alvie"
    private static let directoryName = "Pesty-Alvie"
    private static let fileName = "library.json"

    static var supportDirectory: URL {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            return container.appendingPathComponent(directoryName, isDirectory: true)
        }
        return legacySupportDirectory
    }

    private static var legacySupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func load() -> PestyLibrary {
        migrateLegacyLibraryIfNeeded()
        guard let data = try? Data(contentsOf: libraryURL()),
              let library = try? JSONDecoder.pesty.decode(PestyLibrary.self, from: data) else {
            return PestyLibrary()
        }
        return library
    }

    static func save(_ library: PestyLibrary) throws {
        migrateLegacyLibraryIfNeeded()
        let url = libraryURL()
        try prepareDirectory()
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try write(library, to: coordinatedURL)
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
        migrateLegacyLibraryIfNeeded()
        let url = libraryURL()
        try prepareDirectory()
        var coordinationError: NSError?
        var updateError: Error?
        var result = PestyLibrary()
        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                var library = loadUncoordinated(from: coordinatedURL)
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
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: supportDirectory.path
        )
    }

    private static func loadUncoordinated(from url: URL) -> PestyLibrary {
        guard let data = try? Data(contentsOf: url),
              let library = try? JSONDecoder.pesty.decode(PestyLibrary.self, from: data) else {
            return PestyLibrary()
        }
        return library
    }

    private static func write(_ library: PestyLibrary, to url: URL) throws {
        let data = try JSONEncoder.pesty.encode(library)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func migrateLegacyLibraryIfNeeded() {
        let destination = supportDirectory
        let source = legacySupportDirectory
        guard destination.standardizedFileURL != source.standardizedFileURL,
              !FileManager.default.fileExists(atPath: destination.path),
              FileManager.default.fileExists(atPath: source.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            // A second process may win this one-time race. A later load either
            // sees its copy or safely continues with the legacy fallback data.
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
