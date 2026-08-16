import AppKit
@preconcurrency import QuickLookUI
import os.log

private let qlLog = Logger(subsystem: "com.greycorelabs.pesty", category: "QuickLook")

@MainActor
final class QuickLookService: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookService()

    private var previewItems: [PreviewItem] = []
    private var startIndexByClipID: [UUID: Int] = [:]
    private var orderedStartIndexes: [(index: Int, id: UUID)] = []
    private var indexObservation: NSKeyValueObservation?
    private var closeObservation: NSObjectProtocol?
    private var resizeObservation: NSObjectProtocol?
    private let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(AppIdentity.quickLookDirectoryName, isDirectory: true)

    /// Quick Look's own arrow keys moved its selection; the bar's highlight
    /// should follow.
    var onSelectionChange: ((UUID) -> Void)?
    /// The panel left the screen — by its own Space/Esc handling, its close
    /// button, or dismiss(). Focus restoration lives with AppController.
    var onPanelDidClose: (() -> Void)?

    private override init() {}

    var isVisible: Bool { QLPreviewPanel.shared()?.isVisible ?? false }

    func dismiss() {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        qlLog.debug("dismiss()")
        panel.orderOut(nil)
        panelDidClose()
    }

    func toggle(items: [ClipItem], selectedID: UUID?) {
        guard let panel = QLPreviewPanel.shared() else {
            qlLog.debug("toggle: no shared panel")
            return
        }
        if panel.isVisible {
            dismiss()
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
        guard !newItems.isEmpty else {
            qlLog.debug("toggle: no previewable items")
            return
        }

        previewItems = newItems
        startIndexByClipID = newStartIndexes
        orderedStartIndexes = newStartIndexes.map { (index: $0.value, id: $0.key) }
            .sorted { $0.index < $1.index }
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = selectedIndex
        qlLog.debug("toggle: presenting \(newItems.count) items at \(selectedIndex), appActive=\(NSApp.isActive)")
        // A window can only become key while its app is active, and the bar
        // deliberately never activates this accessory app. Quick Look must
        // take focus to own Space/arrows — exactly like Finder's preview —
        // and AppController hands focus back when the panel closes.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        recenterPanel()
        observePanel(panel)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            qlLog.debug("post-present: visible=\(panel.isVisible) key=\(panel.isKeyWindow) appActive=\(NSApp.isActive)")
        }
    }

    func updateSelection(selectedID: UUID?) {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible,
              let selectedID, let index = startIndexByClipID[selectedID],
              panel.currentPreviewItemIndex != index else { return }
        panel.currentPreviewItemIndex = index
    }

    private func observePanel(_ panel: QLPreviewPanel) {
        indexObservation = panel.observe(\.currentPreviewItemIndex, options: [.new]) { [weak self] _, change in
            guard let index = change.newValue, index >= 0 else { return }
            DispatchQueue.main.async {
                guard let self, let id = self.clipID(forPreviewIndex: index) else { return }
                self.onSelectionChange?(id)
            }
        }
        if resizeObservation == nil {
            // The panel resizes itself to each item's natural size, keeping a
            // corner anchored. Re-centering on every content resize keeps the
            // preview's center fixed instead; live user resizes are left alone.
            resizeObservation = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: panel, queue: .main
            ) { _ in
                MainActor.assumeIsolated { QuickLookService.shared.recenterPanel() }
            }
        }
        if closeObservation == nil {
            // Space/Esc inside the panel close it without going through
            // dismiss(); willClose is the one signal common to every path.
            closeObservation = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: panel, queue: .main
            ) { _ in
                MainActor.assumeIsolated { QuickLookService.shared.panelDidClose() }
            }
        }
    }

    /// Keeps the panel's center on the screen's center. setFrameOrigin only
    /// moves the window, so this cannot re-trigger the resize notification.
    private func recenterPanel() {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible, !panel.inLiveResize,
              let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                                     y: visible.midY - frame.height / 2))
    }

    private func panelDidClose() {
        qlLog.debug("panel closed")
        indexObservation = nil
        onPanelDidClose?()
    }

    private func clipID(forPreviewIndex index: Int) -> UUID? {
        orderedStartIndexes.last { $0.index <= index }?.id
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int { previewItems.count }

    func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
        previewItems[index]
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
