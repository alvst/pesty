import AppKit
import UniformTypeIdentifiers

@MainActor
enum ClipDragProvider {
    static func make(for item: ClipItem) -> NSItemProvider {
        switch item.type {
        case .image:
            if let image = ClipboardStore.shared.loadImage(for: item),
               let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                let provider = NSItemProvider()
                register(png, as: .png, on: provider)
                register(tiff, as: .tiff, on: provider)
                provider.suggestedName = item.displayTitle
                return provider
            }
        case .file:
            if let url = item.fileURLs.first.flatMap(URL.init(string:)), url.isFileURL {
                return NSItemProvider(object: url as NSURL)
            }
        case .richText:
            if let rtf = item.rtfData {
                let provider = NSItemProvider()
                register(rtf, as: .rtf, on: provider)
                register(Data((item.text ?? "").utf8), as: .utf8PlainText, on: provider)
                provider.suggestedName = item.displayTitle
                return provider
            }
        case .text, .link, .color:
            break
        }

        let provider = NSItemProvider()
        register(Data((item.text ?? item.colorHex ?? item.displayTitle).utf8), as: .utf8PlainText, on: provider)
        provider.suggestedName = item.displayTitle
        return provider
    }

    private static func register(_ data: Data, as type: UTType, on provider: NSItemProvider) {
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
    }
}
