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

        guard let selectedIndex = replacePreviewItems(with: items, selectedID: selectedID) else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = selectedIndex
        panel.makeKeyAndOrderFront(nil)
    }

    /// Rebuilds temporary Quick Look assets when a visible clip changes.
    func refresh(items: [ClipItem], selectedID: UUID?) {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible,
              let selectedIndex = replacePreviewItems(with: items, selectedID: selectedID) else { return }
        panel.reloadData()
        panel.currentPreviewItemIndex = selectedIndex
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

    private func replacePreviewItems(with clips: [ClipItem], selectedID: UUID?) -> Int? {
        prepareTemporaryDirectory()
        var selectedIndex = 0
        var newItems: [PreviewItem] = []
        var newStartIndexes: [UUID: Int] = [:]
        for clip in clips {
            let startIndex = newItems.count
            newItems.append(contentsOf: previewItems(for: clip))
            if startIndex < newItems.count { newStartIndexes[clip.id] = startIndex }
            if clip.id == selectedID, startIndex < newItems.count { selectedIndex = startIndex }
        }
        guard !newItems.isEmpty else { return nil }

        previewItems = newItems
        startIndexByClipID = newStartIndexes
        return selectedIndex
    }

    private func previewItems(for clip: ClipItem) -> [PreviewItem] {
        switch clip.type {
        case .file:
            let files = clip.fileURLs.compactMap(URL.init(string:)).filter(\.isFileURL)
            if !files.isEmpty { return files.map { PreviewItem(url: $0, title: $0.lastPathComponent) } }
        case .image:
            if let url = ClipboardStore.shared.imageURL(for: clip) {
                return [PreviewItem(url: url, title: clip.displayTitle)]
            }
        case .richText:
            if let data = clip.rtfData, let url = write(data, named: clip.displayTitle, extension: "rtf") {
                return [PreviewItem(url: url, title: clip.displayTitle)]
            }
        case .color:
            let hex = clip.colorHex ?? "#000000"
            let html = "<!doctype html><html><body style=\"margin:0;background:\(hex);display:flex;height:100vh;align-items:center;justify-content:center;font:48px -apple-system;color:white;text-shadow:0 2px 8px #0008\">\(hex)</body></html>"
            if let url = write(Data(html.utf8), named: "Color \(hex)", extension: "html") {
                return [PreviewItem(url: url, title: hex)]
            }
        case .text, .link:
            break
        }

        let text = clip.text ?? clip.displayTitle
        guard let url = write(Data(text.utf8), named: clip.displayTitle, extension: "txt") else { return [] }
        return [PreviewItem(url: url, title: clip.displayTitle)]
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
        let filename = "\(safeTitle.isEmpty ? "Clip" : safeTitle)-\(UUID().uuidString).\(fileExtension)"
        let url = temporaryDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch { return nil }
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
