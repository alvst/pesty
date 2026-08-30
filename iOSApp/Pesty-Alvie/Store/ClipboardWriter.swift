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
