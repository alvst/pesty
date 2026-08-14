import Foundation

/// Imports the existing Mac app's `store.json` without linking against its
/// AppKit-dependent model types. This is a one-way bridge until the Mac app
/// adopts the shared CloudKit sync protocol.
enum MacPestyStoreImporter {
    enum ImportError: LocalizedError {
        case invalidStore

        var errorDescription: String? {
            switch self {
            case .invalidStore: "This file is not a readable Pesty-Alvie store.json file."
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

        var library = PestyLibrary(clips: snapshot.history.map(convert))
        for board in snapshot.pinboards {
            for item in board.items {
                library.upsert(convert(item))
            }
            let clipIDs = board.items.map(\.id)
            library.upsert(
                PestyBoard(
                    id: board.id,
                    name: board.name,
                    colorHex: board.colorHex,
                    clipIDs: clipIDs,
                    createdAt: board.createdAt ?? .now,
                    updatedAt: board.updatedAt ?? board.createdAt ?? .now
                )
            )
        }
        return library
    }

    private static func convert(_ item: MacClip) -> PestyClip {
        let type = ClipKind(rawValue: item.type) ?? .text
        let fileNames = item.fileURLs.map { URL(string: $0)?.lastPathComponent ?? URL(fileURLWithPath: $0).lastPathComponent }
        return PestyClip(
            id: item.id,
            kind: type,
            text: item.text,
            richTextData: item.rtfData,
            imageHash: item.imageHash,
            fileNames: fileNames,
            colorHex: item.colorHex,
            sourceAppName: item.sourceAppName,
            sourceDeviceName: "Mac",
            customTitle: item.customTitle,
            capturedAt: item.createdAt,
            updatedAt: item.createdAt
        )
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
    var createdAt: Date?
    var updatedAt: Date?
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
