import CloudKit
import Foundation

enum CloudRecordCodec {
    struct DecodedClip {
        var clip: PestyClip
        var imageAssetURL: URL?
    }

    static func populate(_ record: CKRecord, from clip: PestyClip, imageFileURL: URL?) {
        record[CKSchema.Field.type] = clip.kind.rawValue
        writePossiblyLargeText(clip.text, to: record)
        writePossiblyLargeRichText(clip.richTextData, to: record)
        record[CKSchema.Field.image] = imageFileURL.map(CKAsset.init(fileURL:))
        record[CKSchema.Field.imageHash] = bounded(clip.imageHash, length: 128)
        let fileURLs = clip.sourceFileURLs.map {
            Array($0.prefix(CKSchema.maximumFileNameCount)).map { String($0.prefix(2_048)) }
        } ?? []
        writeStringList(fileURLs, to: record, field: CKSchema.Field.fileURLs)
        writeStringList(
            Array(clip.fileNames.prefix(CKSchema.maximumFileNameCount)),
            to: record,
            field: CKSchema.Field.fileNames
        )
        record[CKSchema.Field.colorHex] = bounded(clip.colorHex, length: 9)
        record[CKSchema.Field.sourceBundleID] = bounded(clip.sourceBundleID, length: 512)
        record[CKSchema.Field.sourceAppName] = bounded(clip.sourceAppName, length: 256)
        record[CKSchema.Field.sourceDeviceName] = bounded(clip.sourceDeviceName, length: 256)
        record[CKSchema.Field.customTitle] = bounded(clip.customTitle, length: 512)
        record[CKSchema.Field.createdAt] = clip.capturedAt
        record[CKSchema.Field.updatedAt] = clip.updatedAt
        record[CKSchema.Field.lastUsedAt] = clip.lastUsedAt
        record[CKSchema.Field.container] = clip.containerID?.uuidString ?? CKSchema.historyContainerValue
    }

    static func decodeClip(_ record: CKRecord) -> DecodedClip? {
        guard record.recordType == CKSchema.clipType,
              let id = UUID(uuidString: record.recordID.recordName),
              let rawKind = record[CKSchema.Field.type] as? String,
              let kind = ClipKind(rawValue: rawKind) else { return nil }

        let text = readText(from: record)
        let richText = readRichText(from: record)
        let imageURL = validatedAssetURL(record[CKSchema.Field.image] as? CKAsset)
        let legacyURLs = (record[CKSchema.Field.fileURLs] as? [String]) ?? []
        let names = ((record[CKSchema.Field.fileNames] as? [String]) ?? legacyURLs.map(fileName))
            .prefix(CKSchema.maximumFileNameCount)
            .map { String($0.prefix(512)) }
        let container = (record[CKSchema.Field.container] as? String)
            ?? CKSchema.historyContainerValue
        guard container == CKSchema.historyContainerValue
                || UUID(uuidString: container) != nil else { return nil }
        let createdAt = (record[CKSchema.Field.createdAt] as? Date)
            ?? record.creationDate
            ?? .now
        let updatedAt = (record[CKSchema.Field.updatedAt] as? Date)
            ?? record.modificationDate
            ?? createdAt
        let clip = PestyClip(
            id: id,
            containerID: UUID(uuidString: container),
            kind: kind,
            text: text,
            richTextData: richText,
            imageAssetID: imageURL == nil ? nil : "\(id.uuidString).image",
            imageHash: bounded(record[CKSchema.Field.imageHash] as? String, length: 128),
            fileNames: names,
            colorHex: bounded(record[CKSchema.Field.colorHex] as? String, length: 9),
            sourceBundleID: bounded(record[CKSchema.Field.sourceBundleID] as? String, length: 512),
            sourceAppName: bounded(record[CKSchema.Field.sourceAppName] as? String, length: 256),
            sourceDeviceName: bounded(record[CKSchema.Field.sourceDeviceName] as? String, length: 256),
            sourceFileURLs: legacyURLs.isEmpty
                ? nil
                : legacyURLs.prefix(CKSchema.maximumFileNameCount).map { String($0.prefix(2_048)) },
            customTitle: bounded(record[CKSchema.Field.customTitle] as? String, length: 512),
            capturedAt: createdAt,
            updatedAt: updatedAt,
            lastUsedAt: record[CKSchema.Field.lastUsedAt] as? Date
        )
        return DecodedClip(clip: clip, imageAssetURL: imageURL)
    }

    static func populate(_ record: CKRecord, from board: PestyBoard) {
        record[CKSchema.Field.name] = String(board.name.prefix(256))
        record[CKSchema.Field.colorHex] = bounded(board.colorHex, length: 9)
        record[CKSchema.Field.createdAt] = board.createdAt
        record[CKSchema.Field.updatedAt] = board.updatedAt
        record[CKSchema.Field.sortIndex] = NSNumber(value: board.sortIndex)
        writeStringList(board.clipIDs
            .prefix(CKSchema.maximumBoardClipCount)
            .map(\.uuidString),
            to: record,
            field: CKSchema.Field.clipIDs
        )
        writeStringList(board.pinnedClipIDs
            .prefix(CKSchema.maximumBoardClipCount)
            .map(\.uuidString),
            to: record,
            field: CKSchema.Field.pinnedItemIDs
        )
    }

    static func decodeBoard(_ record: CKRecord) -> PestyBoard? {
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
        let pinnedClipIDs = ((record[CKSchema.Field.pinnedItemIDs] as? [String]) ?? [])
            .prefix(CKSchema.maximumBoardClipCount)
            .compactMap(UUID.init(uuidString:))
        return PestyBoard(
            id: id,
            name: name,
            colorHex: bounded(record[CKSchema.Field.colorHex] as? String, length: 9) ?? "#5B8DEF",
            clipIDs: clipIDs,
            pinnedClipIDs: pinnedClipIDs,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sortIndex: (record[CKSchema.Field.sortIndex] as? NSNumber)?.intValue ?? 0
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
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return CKAsset(fileURL: url)
        } catch {
            return nil
        }
    }

    private static var temporaryAssetDirectory: URL {
        LocalLibraryPersistence.supportDirectory
            .appendingPathComponent("ck-tmp", isDirectory: true)
    }

    private static func bounded(_ value: String?, length: Int) -> String? {
        guard let value else { return nil }
        return String(value.prefix(length))
    }

    private static func writeStringList(_ values: [String], to record: CKRecord, field: String) {
        record[field] = values.isEmpty ? nil : values
    }

    private static func fileName(_ value: String) -> String {
        URL(string: value)?.lastPathComponent ?? URL(fileURLWithPath: value).lastPathComponent
    }
}
