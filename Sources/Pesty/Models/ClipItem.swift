import AppKit

struct ClipItem: Identifiable, Codable, Equatable {
    let id: UUID
    var type: ClipType
    var text: String?
    var rtfData: Data?
    var htmlData: Data?
    var imageFileName: String?
    var imageHash: String?
    var fileURLs: [String]
    var colorHex: String?

    var sourceBundleID: String?
    var sourceAppName: String?
    var sourceDeviceName: String?

    var customTitle: String?
    var createdAt: Date
    /// Last content/metadata change used by record-level CloudKit conflict
    /// resolution. Older stores decode this as `createdAt`.
    var updatedAt: Date
    var lastUsedAt: Date?

    init(id: UUID = UUID(),
         type: ClipType,
         text: String? = nil,
         rtfData: Data? = nil,
         htmlData: Data? = nil,
         imageFileName: String? = nil,
         imageHash: String? = nil,
         fileURLs: [String] = [],
         colorHex: String? = nil,
         sourceBundleID: String? = nil,
         sourceAppName: String? = nil,
         sourceDeviceName: String? = nil,
         customTitle: String? = nil,
         createdAt: Date = Date(),
         updatedAt: Date? = nil,
         lastUsedAt: Date? = nil) {
        self.id = id
        self.type = type
        self.text = text
        self.rtfData = rtfData
        self.htmlData = htmlData
        self.imageFileName = imageFileName
        self.imageHash = imageHash
        self.fileURLs = fileURLs
        self.colorHex = colorHex
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.sourceDeviceName = sourceDeviceName
        self.customTitle = customTitle
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastUsedAt = lastUsedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, text, rtfData, htmlData, imageFileName, imageHash
        case fileURLs, colorHex, sourceBundleID, sourceAppName, sourceDeviceName
        case customTitle, createdAt, updatedAt, lastUsedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(ClipType.self, forKey: .type)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        rtfData = try container.decodeIfPresent(Data.self, forKey: .rtfData)
        htmlData = try container.decodeIfPresent(Data.self, forKey: .htmlData)
        imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
        imageHash = try container.decodeIfPresent(String.self, forKey: .imageHash)
        fileURLs = try container.decodeIfPresent([String].self, forKey: .fileURLs) ?? []
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
        sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
        sourceAppName = try container.decodeIfPresent(String.self, forKey: .sourceAppName)
        sourceDeviceName = try container.decodeIfPresent(String.self, forKey: .sourceDeviceName)
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }

    /// Pinboards own copies rather than sharing an entity ID with History or
    /// another Pinboard. The caller duplicates any image file separately.
    func copiedWithFreshID(at date: Date = .now) -> ClipItem {
        ClipItem(
            type: type,
            text: text,
            rtfData: rtfData,
            htmlData: htmlData,
            imageFileName: imageFileName,
            imageHash: imageHash,
            fileURLs: fileURLs,
            colorHex: colorHex,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            sourceDeviceName: sourceDeviceName,
            customTitle: customTitle,
            createdAt: createdAt,
            updatedAt: date,
            lastUsedAt: lastUsedAt
        )
    }

    var charCount: Int { text?.count ?? 0 }

    /// How much of a clip a card is allowed to hand to `Text`.
    ///
    /// A card shows at most ten truncated lines, but SwiftUI lays out
    /// everything it is given before deciding what to truncate — handing it a
    /// multi-megabyte clip in full is what made the bar unresponsive after
    /// copying a large file's contents. Ten lines cannot need more than this.
    static let cardPreviewLimit = 2048

    /// How far `displayTitle` will scan for a first line. The result is capped
    /// at 60 characters, so only the head can ever matter.
    static let titleScanLimit = 4096

    /// The bounded text a card renders. Prefer this to `text` anywhere the
    /// result is truncated for display anyway.
    var cardPreviewText: String {
        guard let text else { return "" }
        return String(text.prefix(Self.cardPreviewLimit))
    }

    /// The lossless text representation used by the explicit “Paste as Plain
    /// Text” action. Images intentionally do not expose one: inventing a
    /// description for an image would be surprising and lossy.
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
            // Scan only the head. `split(whereSeparator:)` walks the entire
            // clip and allocates one substring per line — 212k of them, and
            // ~150 ms, for a 7 MB JSON paste — purely to read the first.
            // Leading newlines are dropped to match what `split` skipped.
            let head = (text ?? "").prefix(Self.titleScanLimit)
            let firstLine = head.drop(while: \.isNewline).prefix { !$0.isNewline }
            return firstLine.isEmpty ? type.label : String(firstLine.prefix(60))
        }
    }

    /// Case-insensitive search without building a lowercased copy of the clip.
    ///
    /// The previous `searchableText` joined every field and lowercased the
    /// result — a second full-size allocation per item on every keystroke.
    /// Matching each field in place costs one scan and no allocation (see
    /// `TextSearch`), and the cheap fields are tried first so a hit on a title
    /// or app name never touches the body at all.
    ///
    /// `query` is expected to be lowercased already, as both call sites do.
    func matches(query: String) -> Bool {
        matches(query: TextSearch.Query(query))
    }

    /// Uses one prepared query across every field and every clip in a filter
    /// pass, avoiding repeated UTF-8 query allocation in this inner loop.
    func matches(query: TextSearch.Query) -> Bool {
        guard !query.text.isEmpty else { return true }
        func hit(_ value: String?) -> Bool {
            guard let value, !value.isEmpty else { return false }
            return TextSearch.contains(value, query: query)
        }
        if hit(customTitle) || hit(sourceAppName) || hit(colorHex) { return true }
        if fileURLs.contains(where: { hit($0) }) { return true }
        return hit(text)
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
