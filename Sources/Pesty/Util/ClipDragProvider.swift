import AppKit
import UniformTypeIdentifiers

extension UTType {
    /// In-process drag payload carrying a clip's ID, so drop targets inside
    /// the bar (like the Pinboard tabs) can act on the real ClipItem while
    /// other apps only ever see the content representations.
    static let pestyClipID = UTType(exportedAs: "com.alvst.pesty.clip-id")
}

@MainActor
enum ClipDragProvider {
    /// A cheap draggability test for view code. This is deliberately not
    /// `!pasteboardWriters(for:).isEmpty`: building writers loads and
    /// re-encodes an image clip's full bitmap, far too heavy for something
    /// SwiftUI evaluates on every card render. Views gate on this and build
    /// the writers only once a drag actually starts.
    static func canDrag(_ item: ClipItem) -> Bool {
        switch item.type {
        case .file:
            return item.fileURLs.contains { URL(string: $0)?.isFileURL == true }
        case .image:
            return item.imageFileName != nil
        case .richText:
            return item.rtfData != nil || item.htmlData != nil || item.text != nil
        case .link, .text:
            return item.text != nil
        case .color:
            return item.colorHex != nil
        }
    }

    /// Builds the items for a native `NSDraggingSession`. Unlike the single
    /// `NSItemProvider` that `.onDrag` allowed, a multi-file clip becomes one
    /// dragging item per file, so every file arrives at the drop target.
    /// The first item also carries the in-process clip-ID marker that the
    /// bar's own drop targets (Pinboard tabs, reorder strip) key on.
    static func pasteboardWriters(for item: ClipItem) -> [NSPasteboardWriting] {
        let markerType = NSPasteboard.PasteboardType(UTType.pestyClipID.identifier)

        if item.type == .file {
            let urls = item.fileURLs.compactMap(URL.init(string:)).filter(\.isFileURL)
            let items: [NSPasteboardItem] = urls.map { url in
                let pbItem = NSPasteboardItem()
                pbItem.setString(url.absoluteString, forType: .fileURL)
                return pbItem
            }
            items.first?.setString(item.id.uuidString, forType: markerType)
            return items
        }

        let pbItem = NSPasteboardItem()
        switch item.type {
        case .image:
            guard let image = ClipboardStore.shared.loadImage(for: item),
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { return [] }
            pbItem.setData(png, forType: .png)
            pbItem.setData(tiff, forType: .tiff)
        case .richText:
            if let rtf = item.rtfData { pbItem.setData(rtf, forType: .rtf) }
            if let html = item.htmlData { pbItem.setData(html, forType: .html) }
            guard let text = item.text else { break }
            pbItem.setString(text, forType: .string)
        case .link:
            guard let text = item.text else { return [] }
            pbItem.setString(text, forType: .URL)
            pbItem.setString(text, forType: .string)
        case .color:
            guard let hex = item.colorHex else { return [] }
            pbItem.setString(hex, forType: .string)
        case .text:
            guard let text = item.text else { return [] }
            pbItem.setString(text, forType: .string)
        case .file:
            return []
        }
        pbItem.setString(item.id.uuidString, forType: markerType)
        return [pbItem]
    }
}
