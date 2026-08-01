import AppKit
import UniformTypeIdentifiers

/// Builds the external drag representations for a Clipboard clip. The source
/// data stays in Pesty's store; this only vends the representations that a
/// destination app asks for during the active drag session.
@MainActor
enum ClipDragProvider {
    static func make(for item: ClipItem, image: NSImage? = nil) -> NSItemProvider {
        switch item.type {
        case .image:
            if let image = image ?? ClipboardStore.shared.loadImage(for: item),
               let provider = imageProvider(for: image, suggestedName: item.displayTitle) {
                return provider
            }

        case .file:
            if let url = localFileURL(for: item) {
                return NSItemProvider(object: url as NSURL)
            }

        case .richText:
            return richTextProvider(for: item)

        case .text, .link, .color:
            break
        }

        return plainTextProvider(for: item)
    }

    /// A stored file clip can outlive the file it points to. Only pass a
    /// current, local file through to another app; a missing or malformed URL
    /// falls back to the clip's plain-text representation instead.
    static func localFileURL(for item: ClipItem,
                             fileManager: FileManager = .default) -> URL? {
        guard item.type == .file,
              item.fileURLs.count == 1,
              let value = item.fileURLs.first,
              let url = URL(string: value),
              url.isFileURL,
              !url.path.isEmpty,
              fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    private static func richTextProvider(for item: ClipItem) -> NSItemProvider {
        let provider = NSItemProvider()
        if let rtf = item.rtfData, !rtf.isEmpty {
            register(rtf, as: .rtf, on: provider)
        }
        register(Data(plainText(for: item).utf8), as: .utf8PlainText, on: provider)
        provider.suggestedName = item.displayTitle
        return provider
    }

    private static func imageProvider(for image: NSImage,
                                      suggestedName: String) -> NSItemProvider? {
        guard let tiff = image.tiffRepresentation else { return nil }

        let provider = NSItemProvider()
        // TIFF is the representation AppKit gives us directly. PNG gives web
        // and cross-platform destinations a broadly compatible alternative.
        register(tiff, as: .tiff, on: provider)
        if let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            register(png, as: .png, on: provider)
        }
        provider.suggestedName = suggestedName
        return provider
    }

    private static func plainTextProvider(for item: ClipItem) -> NSItemProvider {
        let provider = NSItemProvider()
        register(Data(plainText(for: item).utf8), as: .utf8PlainText, on: provider)
        provider.suggestedName = item.displayTitle
        return provider
    }

    private static func plainText(for item: ClipItem) -> String {
        item.plainText ?? item.text ?? item.colorHex ?? item.displayTitle
    }

    private static func register(_ data: Data, as type: UTType, on provider: NSItemProvider) {
        provider.registerDataRepresentation(
            forTypeIdentifier: type.identifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
    }
}
