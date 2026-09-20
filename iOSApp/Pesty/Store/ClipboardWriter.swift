import UIKit
import UniformTypeIdentifiers

enum ClipboardWriter {
    enum CopyError: LocalizedError {
        case unavailablePayload

        var errorDescription: String? {
            "This item does not have a copyable payload on this device yet."
        }
    }

    static func copy(_ clip: PestyClip, format: CopyFormat = .original) throws {
        switch format {
        case .plainText:
            guard let text = clip.copyableText, !text.isEmpty else { throw CopyError.unavailablePayload }
            UIPasteboard.general.string = text
            return
        case .cleanFormatting:
            if let rtf = FormatConverter.cleanedRTF(for: clip) {
                var item: [String: Any] = [UTType.rtf.identifier: rtf]
                if let text = clip.text { item[UTType.utf8PlainText.identifier] = text }
                UIPasteboard.general.setItems([item], options: [.localOnly: false])
                return
            }
            // No rich source to clean: plain text is the honest result.
            try copy(clip, format: .plainText)
            return
        case .markdown:
            if let markdown = FormatConverter.markdown(for: clip) {
                UIPasteboard.general.string = markdown
                return
            }
            try copy(clip, format: .plainText)
            return
        case .original:
            break
        }

        // An image clip, or a copied image file whose pixels came along
        // (a Mac screenshot): the picture is the useful thing to paste here.
        if clip.kind == .image || clip.kind == .file,
           let url = LocalAssetPersistence.url(for: clip.imageAssetID),
           let image = UIImage(contentsOfFile: url.path) {
            UIPasteboard.general.image = image
            return
        }

        if clip.kind == .link,
           let text = clip.text,
           let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            UIPasteboard.general.url = url
            return
        }

        if clip.kind == .richText,
           let richTextData = clip.richTextData,
           richTextData.count <= CKSchema.maximumTextBytes {
            var item: [String: Any] = [UTType.rtf.identifier: richTextData]
            if let text = clip.text { item[UTType.utf8PlainText.identifier] = text }
            UIPasteboard.general.setItems([item], options: [.localOnly: false])
            return
        }

        guard let text = clip.copyableText, !text.isEmpty else {
            throw CopyError.unavailablePayload
        }
        UIPasteboard.general.string = text
    }
}

/// Reads the system clipboard for the library's "Add Clipboard" action and
/// the optional import that runs when the app comes to the foreground. It is
/// never polled in the background.
enum ClipboardReader {
    enum Payload {
        case image(Data)
        case richText(Data, plainText: String?)
        case text(String, kind: ClipKind)
    }

    enum ReadError: LocalizedError {
        case empty
        case unavailableImage

        var errorDescription: String? {
            switch self {
            case .empty:
                "The clipboard does not contain text, a link, rich text, or an image."
            case .unavailableImage:
                "The image on the clipboard could not be added."
            }
        }
    }

    /// Formats UIImage and NSImage both decode from the stored bytes, so they
    /// are kept exactly as copied. Re-encoding a 12 MP photo as PNG made it
    /// several times larger, slow to import, and sometimes pushed it past the
    /// 50 MB sync limit.
    private static let passthroughImageTypes: [UTType] = [.png, .jpeg, .heic, .heif, .gif]

    /// True when there is an image to import. Inspecting the registered types
    /// never triggers the system paste-permission alert; reading data does.
    static func hasImportableContent(on pasteboard: UIPasteboard = .general) -> Bool {
        pasteboard.hasImages
            || pasteboard.hasStrings
            || pasteboard.hasURLs
            || !imageTypes(on: pasteboard).isEmpty
            || pasteboard.contains(pasteboardTypes: [UTType.rtf.identifier])
    }

    static func read(from pasteboard: UIPasteboard = .general) throws -> Payload {
        if let data = try imageData(from: pasteboard) {
            return .image(data)
        }

        if let rtf = pasteboard.data(forPasteboardType: UTType.rtf.identifier),
           rtf.count <= CKSchema.maximumTextBytes {
            let plainText = try? NSAttributedString(
                data: rtf,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ).string
            return .richText(rtf, plainText: plainText)
        }

        if pasteboard.hasURLs, let url = pasteboard.url, !url.isFileURL {
            return .text(url.absoluteString, kind: .link)
        }

        if let text = pasteboard.string,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(text, kind: kind(for: text))
        }

        throw ReadError.empty
    }

    /// Every image type the pasteboard advertises, including ones that only
    /// arrive through an item provider (Photos, Files, Universal Clipboard),
    /// which `UIPasteboard.image` regularly returns nil for.
    private static func imageTypes(on pasteboard: UIPasteboard) -> [UTType] {
        var identifiers = pasteboard.types
        for provider in pasteboard.itemProviders {
            identifiers.append(contentsOf: provider.registeredTypeIdentifiers)
        }
        var seen = Set<String>()
        return identifiers.compactMap { identifier -> UTType? in
            guard seen.insert(identifier).inserted,
                  let type = UTType(identifier),
                  type.conforms(to: .image) else { return nil }
            return type
        }
    }

    private static func imageData(from pasteboard: UIPasteboard) throws -> Data? {
        let available = imageTypes(on: pasteboard)
        guard !available.isEmpty || pasteboard.hasImages else { return nil }

        for wanted in passthroughImageTypes {
            for type in available where type.conforms(to: wanted) {
                if let data = pasteboard.data(forPasteboardType: type.identifier), !data.isEmpty {
                    return data
                }
            }
        }

        // TIFF, BMP, WebP and friends: decode here and store PNG so the Mac
        // and the widget can show them without guessing the format.
        for type in available {
            if let data = pasteboard.data(forPasteboardType: type.identifier),
               let image = UIImage(data: data),
               let png = image.pngData() {
                return png
            }
        }

        if let image = pasteboard.image, let png = image.pngData() {
            return png
        }
        throw ReadError.unavailableImage
    }

    private static func kind(for text: String) -> ClipKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isNewline }),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return .text
        }
        return .link
    }
}
