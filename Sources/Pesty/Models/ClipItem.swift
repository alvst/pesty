import AppKit
import UniformTypeIdentifiers

struct ClipItem: Identifiable, Codable, Equatable {
    let id: UUID
    var type: ClipType
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

    init(id: UUID = UUID(),
         type: ClipType,
         text: String? = nil,
         rtfData: Data? = nil,
         imageFileName: String? = nil,
         imageHash: String? = nil,
         fileURLs: [String] = [],
         colorHex: String? = nil,
         sourceBundleID: String? = nil,
         sourceAppName: String? = nil,
         customTitle: String? = nil,
         createdAt: Date = Date()) {
        self.id = id
        self.type = type
        self.text = text
        self.rtfData = rtfData
        self.imageFileName = imageFileName
        self.imageHash = imageHash
        self.fileURLs = fileURLs
        self.colorHex = colorHex
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.customTitle = customTitle
        self.createdAt = createdAt
    }

    var charCount: Int { text?.count ?? 0 }

    /// Finder image files remain file clips for copy/paste purposes, but are
    /// presented as images throughout Pesty so their thumbnail is useful.
    var imageFileURL: URL? {
        guard type == .file,
              fileURLs.count == 1,
              let value = fileURLs.first,
              let url = URL(string: value),
              url.isFileURL,
              let fileType = UTType(filenameExtension: url.pathExtension),
              fileType.conforms(to: .image) else { return nil }
        return url
    }

    var isImageFile: Bool { imageFileURL != nil }

    /// UI-only classification. Keep `type == .file` so pasting and dragging a
    /// Finder image preserves its file representation.
    var presentationType: ClipType { isImageFile ? .image : type }

    /// The representation used when a clip is explicitly pasted as plain text.
    /// Images intentionally do not have one: converting an image to an
    /// arbitrary description would be surprising and lossy.
    var plainText: String? {
        switch type {
        case .image:
            return nil
        case .color:
            return colorHex
        case .file:
            if let text, !text.isEmpty { return text }
            let paths = fileURLs.map { URL(string: $0)?.path ?? $0 }
            return paths.isEmpty ? nil : paths.joined(separator: "\n")
        case .text, .richText, .link:
            return text
        }
    }

    var displayTitle: String {
        if let t = customTitle, !t.isEmpty { return t }
        switch type {
        case .link:
            if let t = text, let url = URL(string: t.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return url.host ?? t
            }
            return text ?? "Link"
        case .image:
            return imageFileName != nil ? "Image" : "Image"
        case .file:
            return fileURLs.first.flatMap { URL(string: $0)?.lastPathComponent } ?? "File"
        case .color:
            return colorHex ?? "Color"
        default:
            let firstLine = (text ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return firstLine.isEmpty ? type.label : String(firstLine.prefix(60))
        }
    }

    var searchableText: String {
        [customTitle, text, sourceAppName, fileURLs.joined(separator: " "), colorHex]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    func sameContent(as other: ClipItem) -> Bool {
        guard type == other.type else { return false }
        switch type {
        case .image:
            if let h = imageHash, let oh = other.imageHash { return h == oh }
            return imageFileName == other.imageFileName
        case .color:
            return colorHex == other.colorHex
        case .file:
            return fileURLs == other.fileURLs
        default:
            return text == other.text
        }
    }
}
