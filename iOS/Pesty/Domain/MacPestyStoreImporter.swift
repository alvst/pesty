import Foundation
import CryptoKit

/// Imports the existing Mac app's `store.json` without linking against its
/// AppKit-dependent model types. Ongoing Mac/iOS sync uses CloudKit.
enum MacPestyStoreImporter {
    enum ImportError: LocalizedError {
        case invalidStore
        case missingImage(String)
        case missingPayload(String)
        case invalidPayload(String)

        var errorDescription: String? {
            switch self {
            case .invalidStore: "This file is not a readable Pesty store.json file."
            case .missingImage(let name):
                "The image “\(name)” could not be imported. Choose the Pesty folder that contains store.json and its images folder."
            case .missingPayload(let name):
                "The clip data “\(name)” could not be imported. Choose the Pesty folder that contains store.json and its payloads folder."
            case .invalidPayload(let name):
                "The clip data “\(name)” is damaged. Import was stopped to avoid losing clip content."
            }
        }
    }

    static func library(from selectedURL: URL) throws -> PestyLibrary {
        let isDirectory = try selectedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let base = isDirectory ? selectedURL : selectedURL.deletingLastPathComponent()
        let storeURL = isDirectory ? base.appendingPathComponent("store.json") : selectedURL
        return try library(from: coordinatedData(from: storeURL),
                           imageDirectory: base.appendingPathComponent("images", isDirectory: true))
    }

    /// File providers download remote content as part of a coordinated read.
    /// A plain Data(contentsOf:) can see a missing iCloud placeholder instead.
    private static func coordinatedData(from url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    static func library(from data: Data, imageDirectory: URL? = nil) throws -> PestyLibrary {
        let decoder = JSONDecoder()
        let snapshot: MacSnapshot
        do {
            snapshot = try decoder.decode(MacSnapshot.self, from: data)
        } catch {
            throw ImportError.invalidStore
        }

        let payloadDirectory = imageDirectory?.deletingLastPathComponent()
            .appendingPathComponent("payloads", isDirectory: true)
        var importedImages: [String: (name: String, hash: String)] = [:]
        var newlyCreatedAssets: [String] = []
        do {
            var library = PestyLibrary(clips: try snapshot.history.map {
                try convert($0, containerID: nil, imageDirectory: imageDirectory,
                            payloadDirectory: payloadDirectory,
                            importedImages: &importedImages, newlyCreatedAssets: &newlyCreatedAssets)
            })
            for (boardIndex, board) in snapshot.pinboards.enumerated() {
                let boardClips = try board.items.map { item -> PestyClip in
                    // Every Pinboard owns a distinct copy, even when an old
                    // store happened to reuse the source UUID. The derived ID
                    // makes repeated imports idempotent.
                    let importedID = deterministicCopyID(itemID: item.id, boardID: board.id)
                    return try convert(item, id: importedID, containerID: board.id,
                                       imageDirectory: imageDirectory,
                                       payloadDirectory: payloadDirectory,
                                       importedImages: &importedImages,
                                       newlyCreatedAssets: &newlyCreatedAssets)
                }
                for item in boardClips { library.upsert(item) }
                let clipIDs = boardClips.map(\.id)
                let convertedIDs = Dictionary(
                    zip(board.items.map(\.id), clipIDs),
                    uniquingKeysWith: { first, _ in first }
                )
                library.upsert(
                    PestyBoard(
                        id: board.id,
                        name: board.name,
                        colorHex: board.colorHex,
                        clipIDs: clipIDs,
                        pinnedClipIDs: (board.pinnedItemIDs ?? []).compactMap { convertedIDs[$0] },
                        createdAt: board.createdAt ?? .now,
                        updatedAt: board.updatedAt ?? board.createdAt ?? .now,
                        sortIndex: board.sortIndex ?? boardIndex
                    )
                )
            }
            return library
        } catch {
            newlyCreatedAssets.forEach(LocalAssetPersistence.removeAsset(named:))
            throw error
        }
    }

    private static func convert(
        _ item: MacClip,
        id: UUID? = nil,
        containerID: UUID?,
        imageDirectory: URL?,
        payloadDirectory: URL?,
        importedImages: inout [String: (name: String, hash: String)],
        newlyCreatedAssets: inout [String]
    ) throws -> PestyClip {
        let type = ClipKind(rawValue: item.type) ?? .text
        let fileNames = item.fileURLs.map { URL(string: $0)?.lastPathComponent ?? URL(fileURLWithPath: $0).lastPathComponent }
        var image: (name: String, hash: String)?
        if item.imageFileName == nil, type == .image || item.imageHash != nil {
            throw ImportError.missingImage(item.id.uuidString)
        }
        if let sourceName = item.imageFileName {
            guard !sourceName.isEmpty,
                  URL(fileURLWithPath: sourceName).lastPathComponent == sourceName,
                  let imageDirectory else { throw ImportError.missingImage(sourceName) }
            if let alreadyImported = importedImages[sourceName] {
                image = alreadyImported
            } else {
                let source = imageDirectory.appendingPathComponent(sourceName)
                guard let data = try? coordinatedData(from: source), !data.isEmpty else {
                    throw ImportError.missingImage(sourceName)
                }
                let hash = LocalAssetPersistence.hash(of: data)
                let preferredName = "\(hash).image"
                let existed = LocalAssetPersistence.url(for: preferredName) != nil
                image = try LocalAssetPersistence.storeImageData(data, preferredName: preferredName)
                if !existed { newlyCreatedAssets.append(preferredName) }
                importedImages[sourceName] = image
            }
        }
        let textData = try readSidecar(item.textSidecar, ext: "txt", in: payloadDirectory)
        let richTextData = try readSidecar(item.rtfSidecar, ext: "rtf", in: payloadDirectory)
        // The iOS model has no HTML field, but a compact Mac snapshot must be
        // complete before import can publish any of its clips to CloudKit.
        _ = try readSidecar(item.htmlSidecar, ext: "html", in: payloadDirectory)
        let text: String?
        if let textData {
            guard let decoded = String(data: textData, encoding: .utf8) else {
                throw ImportError.invalidPayload(item.textSidecar ?? "text")
            }
            text = decoded
        } else {
            text = item.text
        }
        return PestyClip(
            id: id ?? item.id,
            containerID: containerID,
            kind: type,
            text: text,
            richTextData: richTextData ?? item.rtfData,
            imageAssetID: image?.name,
            imageHash: image?.hash ?? item.imageHash,
            fileNames: fileNames,
            colorHex: item.colorHex,
            sourceBundleID: item.sourceBundleID,
            sourceAppName: item.sourceAppName,
            sourceDeviceName: item.sourceDeviceName ?? "Mac",
            sourceFileURLs: item.fileURLs.isEmpty ? nil : item.fileURLs,
            customTitle: item.customTitle,
            capturedAt: item.createdAt,
            updatedAt: item.updatedAt ?? item.createdAt,
            lastUsedAt: item.lastUsedAt
        )
    }

    private static func readSidecar(_ name: String?, ext: String, in directory: URL?) throws -> Data? {
        guard let name else { return nil }
        guard let directory else { throw ImportError.missingPayload(name) }
        let suffix = ".\(ext)"
        guard name.hasSuffix(suffix),
              name.count == 64 + suffix.count,
              name.dropLast(suffix.count).utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }),
              URL(fileURLWithPath: name).lastPathComponent == name else {
            throw ImportError.invalidPayload(name)
        }
        let url = directory.appendingPathComponent(name)
        guard let data = try? coordinatedData(from: url) else { throw ImportError.missingPayload(name) }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        guard digest == String(name.dropLast(suffix.count)) else {
            throw ImportError.invalidPayload(name)
        }
        return data
    }

    private static func deterministicCopyID(itemID: UUID, boardID: UUID) -> UUID {
        let digest = SHA256.hash(data: Data("\(boardID.uuidString):\(itemID.uuidString)".utf8))
        var bytes = Array(digest.prefix(16))
        // RFC 4122-compatible version/variant bits. This is an identity
        // derivation, not a security primitive.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

private struct MacSnapshot: Codable {
    var history: [MacClip]
    var pinboards: [MacPinboard]
}

private struct MacPinboard: Codable {
    var id: UUID
    var name: String
    var colorHex: String
    var items: [MacClip]
    var pinnedItemIDs: [UUID]?
    var createdAt: Date?
    var updatedAt: Date?
    var sortIndex: Int?
}

private struct MacClip: Codable {
    var id: UUID
    var type: String
    var text: String?
    var rtfData: Data?
    var textSidecar: String?
    var rtfSidecar: String?
    var htmlSidecar: String?
    var imageFileName: String?
    var imageHash: String?
    var fileURLs: [String]
    var colorHex: String?
    var sourceBundleID: String?
    var sourceAppName: String?
    var sourceDeviceName: String?
    var customTitle: String?
    var createdAt: Date
    var updatedAt: Date?
    var lastUsedAt: Date?
}
