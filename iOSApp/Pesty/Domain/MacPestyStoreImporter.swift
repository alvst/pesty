import Foundation
import CryptoKit

/// Imports the existing Mac app's `store.json` without linking against its
/// AppKit-dependent model types. This is a one-way bridge until the Mac app
/// adopts the shared CloudKit sync protocol.
enum MacPestyStoreImporter {
    enum ImportError: LocalizedError {
        case invalidStore

        var errorDescription: String? {
            switch self {
            case .invalidStore: "This file is not a readable Pesty store.json file."
            }
        }
    }

    static func library(from data: Data) throws -> PestyLibrary {
        let decoder = JSONDecoder()
        let snapshot: MacSnapshot
        do {
            snapshot = try decoder.decode(MacSnapshot.self, from: data)
        } catch {
            throw ImportError.invalidStore
        }

        var library = PestyLibrary(clips: snapshot.history.map { convert($0, containerID: nil) })
        for (boardIndex, board) in snapshot.pinboards.enumerated() {
            let boardClips = board.items.map { item -> PestyClip in
                // Every Pinboard owns a distinct copy, even when an old store
                // happened to use the same source UUID in only one place.
                // The derived ID makes repeated imports idempotent while also
                // repairing IDs shared by History or another Pinboard.
                let importedID = deterministicCopyID(itemID: item.id, boardID: board.id)
                return convert(item, id: importedID, containerID: board.id)
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
    }

    private static func convert(
        _ item: MacClip,
        id: UUID? = nil,
        containerID: UUID?
    ) -> PestyClip {
        let type = ClipKind(rawValue: item.type) ?? .text
        let fileNames = item.fileURLs.map { URL(string: $0)?.lastPathComponent ?? URL(fileURLWithPath: $0).lastPathComponent }
        return PestyClip(
            id: id ?? item.id,
            containerID: containerID,
            kind: type,
            text: item.text,
            richTextData: item.rtfData,
            imageHash: item.imageHash,
            fileNames: fileNames,
            colorHex: item.colorHex,
            sourceBundleID: item.sourceBundleID,
            sourceAppName: item.sourceAppName,
            sourceDeviceName: "Mac",
            sourceFileURLs: item.fileURLs.isEmpty ? nil : item.fileURLs,
            customTitle: item.customTitle,
            capturedAt: item.createdAt,
            updatedAt: item.createdAt
        )
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
    var imageFileName: String?
    var imageHash: String?
    var fileURLs: [String]
    var colorHex: String?
    var sourceBundleID: String?
    var sourceAppName: String?
    var customTitle: String?
    var createdAt: Date
}
