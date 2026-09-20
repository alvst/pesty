import CloudKit
import Foundation

/// The shared Mac/iOS CloudKit wire contract. Keep this file byte-identical
/// in both targets. Platform model conversion belongs in CloudRecordCodec.
enum CKSchema {
    static let containerID = "iCloud.com.alvst.pesty"
    static let zoneName = "PestyZone"

    static let clipType = "Clip"
    static let pinboardType = "Pinboard"
    static let historyContainerValue = "history"

    /// Above this many UTF-8 bytes, text and rich text use CKAsset fields.
    static let inlineLimit = 200_000
    static let maximumAssetBytes = 50 * 1_024 * 1_024
    static let maximumTextBytes = 10 * 1_024 * 1_024
    static let maximumFileNameCount = 256
    static let maximumBoardClipCount = 10_000

    enum Field {
        static let type = "type"
        static let text = "text"
        static let textAsset = "textAsset"
        static let richText = "rtf"
        static let richTextAsset = "rtfAsset"
        static let image = "image"
        static let imageHash = "imageHash"
        static let fileURLs = "fileURLs"
        static let fileNames = "fileNames"
        static let colorHex = "colorHex"
        static let sourceBundleID = "sourceBundleID"
        static let sourceAppName = "sourceAppName"
        static let sourceDeviceName = "sourceDeviceName"
        static let customTitle = "customTitle"
        static let createdAt = "createdAt"
        static let updatedAt = "updatedAt"
        static let lastUsedAt = "lastUsedAt"
        static let container = "container"
        static let name = "name"
        static let sortIndex = "sortIndex"
        static let clipIDs = "clipIDs"
        static let pinnedItemIDs = "pinnedItemIDs"
    }

    static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    static func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }
}
