import Foundation

enum LocalLibraryPersistence {
    private static let directoryName = "Pesty-Alvie"
    private static let fileName = "library.json"

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func load() -> PestyLibrary {
        guard let data = try? Data(contentsOf: libraryURL()),
              let library = try? JSONDecoder.pesty.decode(PestyLibrary.self, from: data) else {
            return PestyLibrary()
        }
        return library
    }

    static func save(_ library: PestyLibrary) throws {
        let url = libraryURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: supportDirectory.path
        )
        let data = try JSONEncoder.pesty.encode(library)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
