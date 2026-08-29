import CloudKit
import Foundation

/// Mac model conversion for the byte-identical CloudKit wire schema shared
/// with the iPhone/iPad target.
enum CloudRecordCodec {
    struct DecodedClip {
        var item: ClipItem
        var container: String
        var imageAssetURL: URL?
    }

    struct DecodedBoard {
        var board: Pinboard
        var clipIDs: [UUID]
    }

    static func populate(
        _ record: CKRecord,
        from item: ClipItem,
        container: String,
        imageFileURL: URL?
    ) {
        record[CKSchema.Field.type] = item.type.rawValue
        writePossiblyLargeText(item.text, to: record)
        writePossiblyLargeRichText(item.rtfData, to: record)
        record[CKSchema.Field.image] = imageFileURL.map(CKAsset.init(fileURL:))
        record[CKSchema.Field.imageHash] = bounded(item.imageHash, length: 128)
        record[CKSchema.Field.fileURLs] = bounded(item.fileURLs, count: CKSchema.maximumFileNameCount)
        record[CKSchema.Field.fileNames] = bounded(
            item.fileURLs.map(fileName),
            count: CKSchema.maximumFileNameCount
        )
        record[CKSchema.Field.colorHex] = bounded(item.colorHex, length: 9)
        record[CKSchema.Field.sourceBundleID] = bounded(item.sourceBundleID, length: 512)
        record[CKSchema.Field.sourceAppName] = bounded(item.sourceAppName, length: 256)
        record[CKSchema.Field.sourceDeviceName] = bounded(item.sourceDeviceName, length: 256)
        record[CKSchema.Field.customTitle] = bounded(item.customTitle, length: 512)
        record[CKSchema.Field.createdAt] = item.createdAt
        record[CKSchema.Field.updatedAt] = item.updatedAt
        record[CKSchema.Field.lastUsedAt] = item.lastUsedAt
        record[CKSchema.Field.container] = container
    }

    static func decodeClip(_ record: CKRecord) -> DecodedClip? {
        guard record.recordType == CKSchema.clipType,
              let id = UUID(uuidString: record.recordID.recordName),
              let rawType = record[CKSchema.Field.type] as? String,
              let type = ClipType(rawValue: rawType) else { return nil }

        let rawContainer = (record[CKSchema.Field.container] as? String)
            ?? CKSchema.historyContainerValue
        guard rawContainer == CKSchema.historyContainerValue
                || UUID(uuidString: rawContainer) != nil else { return nil }

        let imageURL = validatedAssetURL(record[CKSchema.Field.image] as? CKAsset)
        let createdAt = (record[CKSchema.Field.createdAt] as? Date)
            ?? record.creationDate
            ?? .now
        let updatedAt = (record[CKSchema.Field.updatedAt] as? Date)
            ?? record.modificationDate
            ?? createdAt
        let fileURLs = bounded(
            (record[CKSchema.Field.fileURLs] as? [String]) ?? [],
            count: CKSchema.maximumFileNameCount
        )
        let legacyNames = bounded(
            (record[CKSchema.Field.fileNames] as? [String]) ?? [],
            count: CKSchema.maximumFileNameCount
        )
        let normalizedURLs = fileURLs.isEmpty
            ? legacyNames.map { "pesty-file://unavailable/\($0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0)" }
            : fileURLs

        let item = ClipItem(
            id: id,
            type: type,
            text: readText(from: record),
            rtfData: readRichText(from: record),
            imageFileName: imageURL == nil ? nil : "\(id.uuidString).png",
            imageHash: bounded(record[CKSchema.Field.imageHash] as? String, length: 128),
            fileURLs: normalizedURLs,
            colorHex: bounded(record[CKSchema.Field.colorHex] as? String, length: 9),
            sourceBundleID: bounded(record[CKSchema.Field.sourceBundleID] as? String, length: 512),
            sourceAppName: bounded(record[CKSchema.Field.sourceAppName] as? String, length: 256),
            sourceDeviceName: bounded(record[CKSchema.Field.sourceDeviceName] as? String, length: 256),
            customTitle: bounded(record[CKSchema.Field.customTitle] as? String, length: 512),
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastUsedAt: record[CKSchema.Field.lastUsedAt] as? Date
        )
        return DecodedClip(item: item, container: rawContainer, imageAssetURL: imageURL)
    }

    static func populate(_ record: CKRecord, from board: Pinboard) {
        record[CKSchema.Field.name] = String(board.name.prefix(256))
        record[CKSchema.Field.colorHex] = bounded(board.colorHex, length: 9)
        record[CKSchema.Field.createdAt] = board.createdAt
        record[CKSchema.Field.updatedAt] = board.updatedAt
        record[CKSchema.Field.sortIndex] = NSNumber(value: board.sortIndex)
        record[CKSchema.Field.clipIDs] = board.items
            .prefix(CKSchema.maximumBoardClipCount)
            .map { $0.id.uuidString }
        record[CKSchema.Field.pinnedItemIDs] = board.pinnedItemIDs
            .prefix(CKSchema.maximumBoardClipCount)
            .map { $0.uuidString }
    }

    static func decodeBoard(_ record: CKRecord) -> DecodedBoard? {
        guard record.recordType == CKSchema.pinboardType,
              let id = UUID(uuidString: record.recordID.recordName),
              let name = bounded(record[CKSchema.Field.name] as? String, length: 256),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let createdAt = (record[CKSchema.Field.createdAt] as? Date)
            ?? record.creationDate
            ?? .now
        let updatedAt = (record[CKSchema.Field.updatedAt] as? Date)
            ?? record.modificationDate
            ?? createdAt
        let clipIDs = ((record[CKSchema.Field.clipIDs] as? [String]) ?? [])
            .prefix(CKSchema.maximumBoardClipCount)
            .compactMap(UUID.init(uuidString:))
        let pinnedIDs = ((record[CKSchema.Field.pinnedItemIDs] as? [String]) ?? [])
            .prefix(CKSchema.maximumBoardClipCount)
            .compactMap(UUID.init(uuidString:))
        return DecodedBoard(
            board: Pinboard(
                id: id,
                name: name,
                colorHex: bounded(record[CKSchema.Field.colorHex] as? String, length: 9)
                    ?? "#5B8DEF",
                items: [],
                pinnedItemIDs: pinnedIDs,
                createdAt: createdAt,
                updatedAt: updatedAt,
                sortIndex: (record[CKSchema.Field.sortIndex] as? NSNumber)?.intValue ?? 0
            ),
            clipIDs: clipIDs
        )
    }

    static func purgeTemporaryAssets() {
        try? FileManager.default.removeItem(at: temporaryAssetDirectory)
    }

    private static func writePossiblyLargeText(_ text: String?, to record: CKRecord) {
        guard let text else {
            record[CKSchema.Field.text] = nil
            record[CKSchema.Field.textAsset] = nil
            return
        }
        let data = Data(text.utf8)
        guard data.count <= CKSchema.maximumTextBytes else {
            record[CKSchema.Field.text] = nil
            record[CKSchema.Field.textAsset] = nil
            return
        }
        if data.count > CKSchema.inlineLimit {
            record[CKSchema.Field.text] = nil
            record[CKSchema.Field.textAsset] = writeTemporaryAsset(data, extension: "txt")
        } else {
            record[CKSchema.Field.text] = text
            record[CKSchema.Field.textAsset] = nil
        }
    }

    private static func writePossiblyLargeRichText(_ data: Data?, to record: CKRecord) {
        guard let data, data.count <= CKSchema.maximumTextBytes else {
            record[CKSchema.Field.richText] = nil
            record[CKSchema.Field.richTextAsset] = nil
            return
        }
        if data.count > CKSchema.inlineLimit {
            record[CKSchema.Field.richText] = nil
            record[CKSchema.Field.richTextAsset] = writeTemporaryAsset(data, extension: "rtf")
        } else {
            record[CKSchema.Field.richText] = data
            record[CKSchema.Field.richTextAsset] = nil
        }
    }

    private static func readText(from record: CKRecord) -> String? {
        if let inline = record[CKSchema.Field.text] as? String,
           inline.utf8.count <= CKSchema.maximumTextBytes {
            return inline
        }
        guard let url = validatedAssetURL(
            record[CKSchema.Field.textAsset] as? CKAsset,
            maximumBytes: CKSchema.maximumTextBytes
        ), let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func readRichText(from record: CKRecord) -> Data? {
        if let inline = record[CKSchema.Field.richText] as? Data,
           inline.count <= CKSchema.maximumTextBytes {
            return inline
        }
        guard let url = validatedAssetURL(
            record[CKSchema.Field.richTextAsset] as? CKAsset,
            maximumBytes: CKSchema.maximumTextBytes
        ) else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func validatedAssetURL(
        _ asset: CKAsset?,
        maximumBytes: Int = CKSchema.maximumAssetBytes
    ) -> URL? {
        guard let url = asset?.fileURL,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 0,
              size <= maximumBytes else { return nil }
        return url
    }

    private static func writeTemporaryAsset(_ data: Data, extension pathExtension: String) -> CKAsset? {
        do {
            try FileManager.default.createDirectory(
                at: temporaryAssetDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let url = temporaryAssetDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(pathExtension)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return CKAsset(fileURL: url)
        } catch {
            return nil
        }
    }

    private static var temporaryAssetDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.storageDirectoryName, isDirectory: true)
            .appendingPathComponent("ck-tmp", isDirectory: true)
    }

    private static func bounded(_ value: String?, length: Int) -> String? {
        guard let value else { return nil }
        return String(value.prefix(length))
    }

    private static func bounded(_ values: [String], count: Int) -> [String] {
        values.prefix(count).map { String($0.prefix(2_048)) }
    }

    private static func fileName(_ value: String) -> String {
        URL(string: value)?.lastPathComponent ?? URL(fileURLWithPath: value).lastPathComponent
    }
}
