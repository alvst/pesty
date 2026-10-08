import AppKit
import CryptoKit

/// A local store snapshot can keep large clip bodies in immutable files while
/// the in-memory model and CloudKit records continue to hold complete values.
/// The Drive store is encoded without this context for older Mac releases.
final class ClipPayloadSidecars: @unchecked Sendable {
    static let codingKey = CodingUserInfoKey(rawValue: "pesty.clipPayloadSidecars")!
    static let textThreshold = 64 * 1024

    enum SidecarError: Error {
        case invalidReference
        case missingPayload
        case corruptPayload
    }

    let directory: URL
    private(set) var referencedNames: Set<String> = []

    init(directory: URL) { self.directory = directory }

    private static func isValidName(_ name: String, suffix: String? = nil) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 64,
              ["txt", "rtf", "html"].contains(String(parts[1])),
              parts[0].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return false }
        if let suffix, parts[1] != Substring(suffix) { return false }
        return true
    }

    func store(_ bytes: Data, extension suffix: String) throws -> String {
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let name = "\(digest).\(suffix)"
        let url = directory.appendingPathComponent(name, isDirectory: false)
        // A hash-named file may have been damaged since a previous save.
        // Never commit a reference to bytes that cannot be decoded later.
        let existing = try? Data(contentsOf: url, options: .mappedIfSafe)
        if existing != bytes {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try bytes.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        }
        referencedNames.insert(name)
        return name
    }

    func load(_ name: String, extension suffix: String) throws -> Data {
        guard Self.isValidName(name, suffix: suffix) else { throw SidecarError.invalidReference }
        let url = directory.appendingPathComponent(name, isDirectory: false)
        guard let bytes = try? Data(contentsOf: url) else { throw SidecarError.missingPayload }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard name == "\(digest).\(suffix)" else { throw SidecarError.corruptPayload }
        referencedNames.insert(name)
        return bytes
    }

    /// Run only after store.json has been committed. A crash before this step
    /// leaves an orphan, while a failed commit leaves every old reference.
    func pruneUnreferenced() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where !referencedNames.contains(file.lastPathComponent)
            && Self.isValidName(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

struct ClipItem: Identifiable, Codable, Equatable {
    static func validatedSourceBundleID(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 255,
              value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ part in
                  !part.isEmpty && part.utf8.allSatisfy { byte in
                      (65...90).contains(byte) || (97...122).contains(byte)
                          || (48...57).contains(byte) || byte == 45 || byte == 95
                  }
              }) else { return nil }
        return value
    }
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
        self.sourceBundleID = Self.validatedSourceBundleID(sourceBundleID)
        self.sourceAppName = self.sourceBundleID == nil ? nil : sourceAppName
        self.sourceDeviceName = sourceDeviceName
        self.customTitle = customTitle
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastUsedAt = lastUsedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, text, rtfData, htmlData, imageFileName, imageHash
        case textSidecar, rtfSidecar, htmlSidecar
        case fileURLs, colorHex, sourceBundleID, sourceAppName, sourceDeviceName
        case customTitle, createdAt, updatedAt, lastUsedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(ClipType.self, forKey: .type)
        let sidecars = decoder.userInfo[ClipPayloadSidecars.codingKey] as? ClipPayloadSidecars
        if let name = try container.decodeIfPresent(String.self, forKey: .textSidecar) {
            guard let sidecars else { throw ClipPayloadSidecars.SidecarError.missingPayload }
            let bytes = try sidecars.load(name, extension: "txt")
            guard let value = String(data: bytes, encoding: .utf8) else {
                throw ClipPayloadSidecars.SidecarError.corruptPayload
            }
            text = value
        } else {
            text = try container.decodeIfPresent(String.self, forKey: .text)
        }
        if let name = try container.decodeIfPresent(String.self, forKey: .rtfSidecar) {
            guard let sidecars else { throw ClipPayloadSidecars.SidecarError.missingPayload }
            rtfData = try sidecars.load(name, extension: "rtf")
        } else {
            rtfData = try container.decodeIfPresent(Data.self, forKey: .rtfData)
        }
        if let name = try container.decodeIfPresent(String.self, forKey: .htmlSidecar) {
            guard let sidecars else { throw ClipPayloadSidecars.SidecarError.missingPayload }
            htmlData = try sidecars.load(name, extension: "html")
        } else {
            htmlData = try container.decodeIfPresent(Data.self, forKey: .htmlData)
        }
        imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
        imageHash = try container.decodeIfPresent(String.self, forKey: .imageHash)
        fileURLs = try container.decodeIfPresent([String].self, forKey: .fileURLs) ?? []
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
        sourceBundleID = Self.validatedSourceBundleID(
            try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
        )
        sourceAppName = sourceBundleID == nil ? nil
            : try container.decodeIfPresent(String.self, forKey: .sourceAppName)
        sourceDeviceName = try container.decodeIfPresent(String.self, forKey: .sourceDeviceName)
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let sidecars = encoder.userInfo[ClipPayloadSidecars.codingKey] as? ClipPayloadSidecars
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        if let text, let sidecars, text.utf8.count > ClipPayloadSidecars.textThreshold {
            try container.encode(
                sidecars.store(Data(text.utf8), extension: "txt"), forKey: .textSidecar
            )
        } else {
            try container.encodeIfPresent(text, forKey: .text)
        }
        if let rtfData, !rtfData.isEmpty, let sidecars {
            try container.encode(sidecars.store(rtfData, extension: "rtf"), forKey: .rtfSidecar)
        } else {
            try container.encodeIfPresent(rtfData, forKey: .rtfData)
        }
        if let htmlData, !htmlData.isEmpty, let sidecars {
            try container.encode(sidecars.store(htmlData, extension: "html"), forKey: .htmlSidecar)
        } else {
            try container.encodeIfPresent(htmlData, forKey: .htmlData)
        }
        try container.encodeIfPresent(imageFileName, forKey: .imageFileName)
        try container.encodeIfPresent(imageHash, forKey: .imageHash)
        try container.encode(fileURLs, forKey: .fileURLs)
        try container.encodeIfPresent(colorHex, forKey: .colorHex)
        try container.encodeIfPresent(sourceBundleID, forKey: .sourceBundleID)
        try container.encodeIfPresent(sourceAppName, forKey: .sourceAppName)
        try container.encodeIfPresent(sourceDeviceName, forKey: .sourceDeviceName)
        try container.encodeIfPresent(customTitle, forKey: .customTitle)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
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
            guard text == other.text else { return false }
            if imageHash != nil || other.imageHash != nil {
                if let h = imageHash, let oh = other.imageHash { return h == oh }
                return imageFileName == other.imageFileName
            }
            return true
        }
    }
}
