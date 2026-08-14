import Foundation

/// A platform-neutral clipboard item. Asset identifiers refer to files in the
/// local cache or, later, to CloudKit assets; they never expose another
/// device's file-system path.
struct PestyClip: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var kind: ClipKind
    var text: String?
    var richTextData: Data?
    var imageAssetID: String?
    var imageHash: String?
    var fileNames: [String]
    var colorHex: String?
    var sourceAppName: String?
    var sourceDeviceName: String?
    var customTitle: String?
    var capturedAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        kind: ClipKind,
        text: String? = nil,
        richTextData: Data? = nil,
        imageAssetID: String? = nil,
        imageHash: String? = nil,
        fileNames: [String] = [],
        colorHex: String? = nil,
        sourceAppName: String? = nil,
        sourceDeviceName: String? = nil,
        customTitle: String? = nil,
        capturedAt: Date = .now,
        updatedAt: Date = .now,
        lastUsedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.richTextData = richTextData
        self.imageAssetID = imageAssetID
        self.imageHash = imageHash
        self.fileNames = fileNames
        self.colorHex = colorHex
        self.sourceAppName = sourceAppName
        self.sourceDeviceName = sourceDeviceName
        self.customTitle = customTitle
        self.capturedAt = capturedAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.deletedAt = deletedAt
    }

    var isDeleted: Bool { deletedAt != nil }

    var displayTitle: String {
        if let customTitle = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customTitle.isEmpty {
            return customTitle
        }

        switch kind {
        case .link:
            if let text, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return url.host ?? text
            }
            return text ?? "Link"
        case .image:
            return imageAssetID == nil ? "Image available when synced" : "Image"
        case .file:
            return fileNames.first ?? "File"
        case .color:
            return colorHex ?? "Color"
        case .text, .richText:
            let firstLine = text?
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init) ?? ""
            return firstLine.isEmpty ? kind.title : String(firstLine.prefix(70))
        }
    }

    var previewText: String? {
        switch kind {
        case .image:
            return imageAssetID == nil ? "This image will be available after its asset is synced." : nil
        case .file:
            return fileNames.isEmpty ? "File available on its source device" : fileNames.joined(separator: ", ")
        case .color:
            return colorHex
        default:
            return text
        }
    }

    var copyableText: String? {
        switch kind {
        case .text, .richText, .link:
            return text
        case .color:
            return colorHex
        case .file:
            return fileNames.isEmpty ? nil : fileNames.joined(separator: "\n")
        case .image:
            return nil
        }
    }

    var searchableText: String {
        [customTitle, text, sourceAppName, sourceDeviceName, fileNames.joined(separator: " "), colorHex]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    mutating func markUsed(at date: Date = .now) {
        lastUsedAt = date
        updatedAt = date
    }
}
