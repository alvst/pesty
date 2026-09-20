import Foundation

/// A platform-neutral clipboard item. Asset identifiers refer to files in the
/// local cache or, later, to CloudKit assets; they never expose another
/// device's file-system path.
struct PestyClip: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    /// `nil` means History. A value identifies the Pinboard that owns this
    /// copy. Clipboard items are copied into Pinboards with a fresh UUID so a
    /// CloudKit record always has exactly one container.
    var containerID: UUID?
    var kind: ClipKind
    var text: String?
    var richTextData: Data?
    var imageAssetID: String?
    var imageHash: String?
    var fileNames: [String]
    var colorHex: String?
    var sourceBundleID: String?
    var sourceAppName: String?
    var sourceDeviceName: String?
    /// Opaque source-device URLs are retained only so an iOS metadata edit
    /// cannot erase a Mac file clip's original payload on the sync record.
    /// iOS never opens these paths.
    var sourceFileURLs: [String]?
    var customTitle: String?
    var capturedAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var deletedAt: Date?
    /// The active record version retained while a local delete waits for its
    /// five-minute hard-delete deadline. It is never sent as a wire field.
    var preDeletionUpdatedAt: Date?
    /// Remote tombstones and locally expired deletions are final and cannot
    /// be resurrected by the five-minute Undo UI.
    var deletionFinalizedAt: Date?

    init(
        id: UUID = UUID(),
        containerID: UUID? = nil,
        kind: ClipKind,
        text: String? = nil,
        richTextData: Data? = nil,
        imageAssetID: String? = nil,
        imageHash: String? = nil,
        fileNames: [String] = [],
        colorHex: String? = nil,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        sourceDeviceName: String? = nil,
        sourceFileURLs: [String]? = nil,
        customTitle: String? = nil,
        capturedAt: Date = .now,
        updatedAt: Date = .now,
        lastUsedAt: Date? = nil,
        deletedAt: Date? = nil,
        preDeletionUpdatedAt: Date? = nil,
        deletionFinalizedAt: Date? = nil
    ) {
        self.id = id
        self.containerID = containerID
        self.kind = kind
        self.text = text
        self.richTextData = richTextData
        self.imageAssetID = imageAssetID
        self.imageHash = imageHash
        self.fileNames = fileNames
        self.colorHex = colorHex
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.sourceDeviceName = sourceDeviceName
        self.sourceFileURLs = sourceFileURLs
        self.customTitle = customTitle
        self.capturedAt = capturedAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.deletedAt = deletedAt
        self.preDeletionUpdatedAt = preDeletionUpdatedAt
        self.deletionFinalizedAt = deletionFinalizedAt
    }

    var isDeleted: Bool { deletedAt != nil }

    func copied(to containerID: UUID, at date: Date = .now) -> PestyClip {
        PestyClip(
            containerID: containerID,
            kind: kind,
            text: text,
            richTextData: richTextData,
            imageAssetID: imageAssetID,
            imageHash: imageHash,
            fileNames: fileNames,
            colorHex: colorHex,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            sourceDeviceName: sourceDeviceName,
            sourceFileURLs: sourceFileURLs,
            customTitle: customTitle,
            capturedAt: capturedAt,
            updatedAt: date,
            lastUsedAt: lastUsedAt
        )
    }

    func hasSameContent(as other: PestyClip) -> Bool {
        guard kind == other.kind else { return false }
        switch kind {
        case .image:
            if let imageHash, let otherHash = other.imageHash {
                return imageHash == otherHash
            }
            return imageAssetID == other.imageAssetID
        case .file:
            return fileNames == other.fileNames
        case .color:
            return colorHex == other.colorHex
        case .text, .richText, .link:
            return text == other.text
        }
    }

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
            let head = (text ?? "").prefix(4_096)
            let firstLine = String(head.drop(while: \.isNewline).prefix { !$0.isNewline })
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
