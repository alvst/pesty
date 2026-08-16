import AppKit
import UniformTypeIdentifiers

@MainActor
enum ClipDragProvider {
    static func fileURLs(for item: ClipItem) -> [URL] {
        guard item.type == .file else { return [] }
        return item.fileURLs.compactMap { value in
            guard let url = URL(string: value), url.isFileURL else { return nil }
            return url
        }
    }

    /// A cheap draggability test for view code. This is deliberately not
    /// `!pasteboardWriters(for:).isEmpty`: building writers reads and
    /// re-encodes an image clip's full bitmap, far too heavy for something
    /// SwiftUI evaluates on every card render. Views gate on this and build
    /// the writers only once a drag actually starts.
    static func canDrag(_ item: ClipItem) -> Bool {
        switch item.type {
        case .file:
            return !fileURLs(for: item).isEmpty
        case .image:
            return item.imageFileName != nil
        case .richText:
            return item.rtfData != nil || item.text != nil
        case .link, .text:
            return item.text != nil
        case .color:
            return item.colorHex != nil
        }
    }

    /// The full set of pasteboard writers for dragging this clip out - one
    /// per file for `.file` clips (so a multi-file clip drags as that many
    /// items, matching how Finder itself hands off a multi-selection), or a
    /// single `NSPasteboardItem` for everything else. Empty when the clip has
    /// nothing draggable.
    ///
    /// `NSDraggingItem` needs an `NSPasteboardWriting` conformer, which
    /// `NSItemProvider` doesn't satisfy - SwiftUI's `.onDrag` bridges that
    /// gap privately, but a native `NSDraggingSession` has to build its own
    /// `NSPasteboardItem` instead.
    static func pasteboardWriters(for item: ClipItem) -> [NSPasteboardWriting] {
        switch item.type {
        case .file:
            return fileURLs(for: item).map { $0 as NSURL }
        default:
            guard let writer = pasteboardItem(for: item) else { return [] }
            return [writer]
        }
    }

    private static func pasteboardItem(for item: ClipItem) -> NSPasteboardItem? {
        let pbItem = NSPasteboardItem()

        switch item.type {
        case .text:
            guard let text = item.text else { return nil }
            pbItem.setString(text, forType: .string)

        case .richText:
            guard item.rtfData != nil || item.text != nil else { return nil }
            if let rtfData = item.rtfData {
                pbItem.setData(rtfData, forType: .rtf)
            }
            if let text = item.text {
                pbItem.setString(text, forType: .string)
            }

        case .link:
            guard let text = item.text, let url = linkURL(from: text) else { return nil }
            pbItem.setString(url.absoluteString, forType: .URL)
            pbItem.setString(text, forType: .string)

        case .color:
            guard let hex = item.colorHex, let color = NSColor(hex: hex) else { return nil }
            guard let data = try? NSKeyedArchiver.archivedData(
                withRootObject: color, requiringSecureCoding: true
            ) else { return nil }
            pbItem.setData(data, forType: .color)
            pbItem.setString(hex, forType: .string)

        case .image:
            guard let imageURL = ClipboardStore.shared.imageURL(for: item),
                  let data = try? Data(contentsOf: imageURL, options: .mappedIfSafe) else { return nil }
            pbItem.setData(data, forType: NSPasteboard.PasteboardType(UTType.png.identifier))
            if let image = NSImage(contentsOf: imageURL), let tiff = image.tiffRepresentation {
                pbItem.setData(tiff, forType: .tiff)
            }

        case .file:
            return nil
        }

        return pbItem
    }

    private static func linkURL(from text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }
}
