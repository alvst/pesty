import AppKit

/// Opens an inline-preview clip in the appropriate native macOS app without
/// exposing Pesty's managed history files to edits made in that app.
@MainActor
enum InlinePreviewExternalOpener {
    private static let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Pesty-External-Previews", isDirectory: true)

    static func actionTitle(for item: ClipItem) -> String? {
        switch item.type {
        case .link:
            return linkURL(for: item) == nil ? nil : "Open in Default Browser"
        case .image:
            return "Open in Preview"
        case .file where item.isImageFile:
            return "Open in Preview"
        case .text, .richText:
            return "Open in TextEdit"
        case .color, .file:
            return nil
        }
    }

    static func open(_ item: ClipItem) {
        switch item.type {
        case .link:
            guard let url = linkURL(for: item) else { return }
            NSWorkspace.shared.open(url)
        case .image:
            guard let source = ClipboardStore.shared.imageURL(for: item),
                  let copy = copyToTemporaryLocation(source, named: item.displayTitle) else { return }
            open(copy, withApplicationBundleID: "com.apple.Preview")
        case .file where item.isImageFile:
            guard let source = item.imageFileURL,
                  let copy = copyToTemporaryLocation(source, named: item.displayTitle) else { return }
            open(copy, withApplicationBundleID: "com.apple.Preview")
        case .richText:
            guard let data = item.rtfData,
                  let url = write(data, named: item.displayTitle, fileExtension: "rtf") else { return }
            open(url, withApplicationBundleID: "com.apple.TextEdit")
        case .text:
            let data = Data((item.text ?? "").utf8)
            guard let url = write(data, named: item.displayTitle, fileExtension: "txt") else { return }
            open(url, withApplicationBundleID: "com.apple.TextEdit")
        case .color, .file:
            return
        }
    }

    private static func linkURL(for item: ClipItem) -> URL? {
        guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text) else { return nil }
        return url
    }

    private static func copyToTemporaryLocation(_ source: URL, named title: String) -> URL? {
        guard let data = try? Data(contentsOf: source) else { return nil }
        let fileExtension = source.pathExtension.isEmpty ? "png" : source.pathExtension
        return write(data, named: title, fileExtension: fileExtension)
    }

    private static func write(_ data: Data, named title: String, fileExtension: String) -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: temporaryDirectory,
                                   withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }

        let safeTitle = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = safeTitle.isEmpty ? "Clip" : String(safeTitle.prefix(80))
        let url = temporaryDirectory
            .appendingPathComponent("\(baseName)-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        do {
            try data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }

    private static func open(_ url: URL, withApplicationBundleID bundleID: String) {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration)
    }
}
