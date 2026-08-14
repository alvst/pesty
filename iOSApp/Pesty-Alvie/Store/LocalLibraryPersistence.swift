import Foundation

enum LocalLibraryPersistence {
    private static let directoryName = "Pesty-Alvie"
    private static let fileName = "library.json"

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
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.pesty.encode(library)
        try data.write(to: url, options: [.atomic])
    }

    static func removeAll() throws {
        let url = libraryURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func libraryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent(directoryName, isDirectory: true)
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
