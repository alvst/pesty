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

    var customTitle: String?
    var createdAt: Date

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
         customTitle: String? = nil,
         createdAt: Date = Date()) {
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
        self.customTitle = customTitle
        self.createdAt = createdAt
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
        guard !query.isEmpty else { return true }
        func hit(_ value: String?) -> Bool {
            guard let value, !value.isEmpty else { return false }
            return TextSearch.contains(value, lowercasedQuery: query)
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
