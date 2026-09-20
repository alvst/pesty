import CryptoKit
import Foundation

enum LocalAssetPersistence {
    enum AssetError: LocalizedError {
        case empty
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .empty:
                "The selected image is empty."
            case .tooLarge:
                "The selected image is larger than the 50 MB sync limit."
            }
        }
    }

    static let maximumAssetBytes = 50 * 1_024 * 1_024

    static func storeImageData(_ data: Data, preferredName: String? = nil) throws -> (name: String, hash: String) {
        guard !data.isEmpty else { throw AssetError.empty }
        guard data.count <= maximumAssetBytes else { throw AssetError.tooLarge }
        try prepareDirectory()

        let hash = hash(of: data)
        let safePreferredName = preferredName.flatMap(sanitizedFileName)
        let name = safePreferredName ?? "\(UUID().uuidString).image"
        let url = assetsDirectory.appendingPathComponent(name, isDirectory: false)
        try data.write(to: url, options: LocalFileProtection.writingOptions)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return (name, hash)
    }

    static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func replaceAsset(from sourceURL: URL, preferredName: String) throws -> (name: String, hash: String) {
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, size > maximumAssetBytes { throw AssetError.tooLarge }
        return try storeImageData(Data(contentsOf: sourceURL), preferredName: preferredName)
    }

    static func url(for name: String?) -> URL? {
        guard let name = name.flatMap(sanitizedFileName) else { return nil }
        let url = assetsDirectory.appendingPathComponent(name, isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func removeAll() throws {
        let directory = assetsDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    static func removeUnreferencedAssets(in library: PestyLibrary, at date: Date = .now) {
        let retained = Set(library.clips.compactMap { clip -> String? in
            guard let name = clip.imageAssetID else { return nil }
            if clip.deletionFinalizedAt != nil { return nil }
            guard let deletedAt = clip.deletedAt else { return name }
            return deletedAt.addingTimeInterval(PestyLibrary.deletionUndoInterval) > date ? name : nil
        })
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: assetsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in contents where !retained.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static var assetsDirectory: URL {
        LocalLibraryPersistence.supportDirectory
            .appendingPathComponent("assets", isDirectory: true)
    }

    private static func prepareDirectory() throws {
        try LocalFileProtection.prepareDirectory(at: assetsDirectory)
    }

    private static func sanitizedFileName(_ value: String) -> String? {
        let name = URL(fileURLWithPath: value).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard name.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return String(name.prefix(180))
    }
}
