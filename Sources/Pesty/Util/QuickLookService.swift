import AppKit
@preconcurrency import QuickLookUI

@MainActor
final class QuickLookService: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookService()

    private var previewItems: [PreviewItem] = []
    private var startIndexByClipID: [UUID: Int] = [:]
    private let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Pesty-QuickLook", isDirectory: true)

    private override init() {}

    var isVisible: Bool { QLPreviewPanel.shared()?.isVisible ?? false }

    func toggle(items: [ClipItem], selectedID: UUID?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }

        prepareTemporaryDirectory()
        var selectedIndex = 0
        var newItems: [PreviewItem] = []
        var newStartIndexes: [UUID: Int] = [:]
        for clip in items {
            let startIndex = newItems.count
            newItems.append(contentsOf: previewItems(for: clip))
            if startIndex < newItems.count { newStartIndexes[clip.id] = startIndex }
            if clip.id == selectedID, startIndex < newItems.count { selectedIndex = startIndex }
        }
        guard !newItems.isEmpty else { return }

        previewItems = newItems
        startIndexByClipID = newStartIndexes
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = selectedIndex
        panel.makeKeyAndOrderFront(nil)
    }

    func updateSelection(selectedID: UUID?) {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible,
              let selectedID, let index = startIndexByClipID[selectedID] else { return }
        panel.currentPreviewItemIndex = index
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int { previewItems.count }

    func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
        previewItems[index]
    }

    private func previewItems(for clip: ClipItem) -> [PreviewItem] {
        switch clip.type {
        case .file:
            let files = clip.fileURLs.compactMap(URL.init(string:)).filter(\.isFileURL)
            if !files.isEmpty { return files.map { PreviewItem(url: $0, title: clip.type.label) } }
        case .image:
            if let url = ClipboardStore.shared.imageURL(for: clip) {
                return [PreviewItem(url: url, title: clip.type.label)]
            }
        case .richText:
            if let data = clip.rtfData, let url = write(data, named: clip.displayTitle, extension: "rtf") {
                return [PreviewItem(url: url, title: clip.type.label)]
            }
        case .color:
            let hex = clip.colorHex ?? "#000000"
            let html = "<!doctype html><html><body style=\"margin:0;background:\(hex);display:flex;height:100vh;align-items:center;justify-content:center;font:48px -apple-system;color:white;text-shadow:0 2px 8px #0008\">\(hex)</body></html>"
            if let url = write(Data(html.utf8), named: "Color \(hex)", extension: "html") {
                return [PreviewItem(url: url, title: hex)]
            }
        case .text:
            let text = clip.text ?? clip.displayTitle
            if let url = write(Data(textPreviewHTML(for: text).utf8), named: "Text", extension: "html") {
                return [PreviewItem(url: url, title: clip.type.label)]
            }
        case .link:
            let text = clip.text ?? clip.displayTitle
            if let url = write(Data(textPreviewHTML(for: text, isLink: true).utf8), named: "Link", extension: "html") {
                return [PreviewItem(url: url, title: clip.type.label)]
            }
        }

        let text = clip.text ?? clip.displayTitle
        guard let url = write(Data(text.utf8), named: clip.displayTitle, extension: "txt") else { return [] }
        return [PreviewItem(url: url, title: clip.type.label)]
    }

    private func prepareTemporaryDirectory() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        try? FileManager.default.createDirectory(at: temporaryDirectory,
                                                  withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
    }

    private func write(_ data: Data, named title: String, extension fileExtension: String) -> URL? {
        let safeTitle = title.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = safeTitle.isEmpty ? "Clip" : String(safeTitle.prefix(80))
        let filename = "\(baseName)-\(UUID().uuidString).\(fileExtension)"
        let url = temporaryDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch { return nil }
    }

    /// Use a local, self-contained document so Quick Look can present text and
    /// links more readably without loading remote content or running scripts.
    private func textPreviewHTML(for text: String, isLink: Bool = false) -> String {
        let characterCount = text.count
        let wordCount = text.split { $0.isWhitespace || $0.isNewline }.count
        let lineCount = max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)
        let escaped = escapeHTML(text)
        let content = isLink ? "<div class=\"url\">\(escaped)</div>" : "<pre>\(escaped)</pre>"
        let words = wordCount == 1 ? "word" : "words"
        let lines = lineCount == 1 ? "line" : "lines"

        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><style>
        :root { color-scheme: light; }
        * { box-sizing: border-box; }
        html, body { width: 100%; height: 100%; margin: 0; }
        body { padding: 16px; background: #f7f7f8; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
        .content { min-height: calc(100% - 40px); padding: 20px 22px; border-radius: 10px; background: #2d3442; color: #f2f4f8; overflow: auto; }
        pre { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; font: 600 20px/1.45 ui-monospace, SFMono-Regular, Menlo, Monaco, monospace; }
        .url { font: 600 19px/1.45 -apple-system, BlinkMacSystemFont, sans-serif; overflow-wrap: anywhere; color: #f2f4f8; }
        .meta { height: 40px; display: flex; align-items: end; gap: 11px; color: #7b7d82; font: 16px/1.2 -apple-system, BlinkMacSystemFont, sans-serif; }
        .separator { color: #b9bbc0; }
        </style></head><body>
        <main class="content">\(content)</main>
        <footer class="meta"><span>\(characterCount) characters</span><span class="separator">·</span><span>\(wordCount) \(words)</span><span class="separator">·</span><span>\(lineCount) \(lines)</span></footer>
        </body></html>
        """
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private final class PreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        previewItemURL = url
        previewItemTitle = title
    }
}
