import UIKit

enum ClipboardWriter {
    enum CopyError: LocalizedError {
        case unavailablePayload

        var errorDescription: String? {
            "This item does not have a copyable payload on this device yet."
        }
    }

    static func copy(_ clip: PestyClip) throws {
        if clip.kind == .link,
           let text = clip.text,
           let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            UIPasteboard.general.url = url
            return
        }

        guard let text = clip.copyableText, !text.isEmpty else {
            throw CopyError.unavailablePayload
        }
        UIPasteboard.general.string = text
    }
}
