import UIKit
import UniformTypeIdentifiers

enum ClipboardWriter {
    enum CopyError: LocalizedError {
        case unavailablePayload

        var errorDescription: String? {
            "This item does not have a copyable payload on this device yet."
        }
    }

    static func copy(_ clip: PestyClip) throws {
        if clip.kind == .image,
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
