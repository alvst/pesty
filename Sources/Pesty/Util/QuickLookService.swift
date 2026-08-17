import AppKit
@preconcurrency import QuickLookUI

@MainActor
final class QuickLookService: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookService()

    private var previewItems: [PreviewItem] = []
    private var startIndexByClipID: [UUID: Int] = [:]
    private var orderedStartIndexes: [(index: Int, id: UUID)] = []
    private var indexObservation: NSKeyValueObservation?
    private var closeObservation: NSObjectProtocol?
    private var resizeObservation: NSObjectProtocol?
    private var moveObservation: NSObjectProtocol?
    private var isRecentering = false
    private var userHasMovedPanel = false
    private let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Pesty-QuickLook", isDirectory: true)

    /// The panel handles its own arrow-key navigation natively once it is the
    /// key window — those keystrokes never reach the bar's own key monitor.
    /// This is how the bar's selection (and its highlight) stays in sync with
    /// whatever the panel is currently showing.
    var onSelectionChange: ((UUID) -> Void)?
    /// The panel left the screen — via `dismiss()`, or natively through its
    /// own Space/Esc handling, which never calls into this service at all.
    /// `willClose` is the one signal common to every path.
    var onPanelDidClose: (() -> Void)?

    private override init() {}

    var isVisible: Bool { QLPreviewPanel.shared()?.isVisible ?? false }

    func dismiss() {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.orderOut(nil)
        panelDidClose()
    }

    func toggle(items: [ClipItem], selectedID: UUID?) {
        guard let panel = QLPreviewPanel.shared() else { return }
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
        guard !newItems.isEmpty else { return }

        previewItems = newItems
        startIndexByClipID = newStartIndexes
        orderedStartIndexes = newStartIndexes.map { ($0.value, $0.key) }.sorted { $0.index < $1.index }
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = selectedIndex
        panel.makeKeyAndOrderFront(nil)
        userHasMovedPanel = false
        recenterPanel()
        observePanel(panel)
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
        if moveObservation == nil {
            // A deliberate repositioning by the user is respected: willMove
            // fires for title-bar drags but not for the panel's own
            // content-driven origin shifts, and the flag rules out this
            // service's recenters — after that, auto-recentering stands down
            // until the panel next opens fresh.
            moveObservation = NotificationCenter.default.addObserver(
                forName: NSWindow.willMoveNotification, object: panel, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    let service = QuickLookService.shared
                    if !service.isRecentering { service.userHasMovedPanel = true }
                }
            }
        }
        if closeObservation == nil {
            // Space/Esc inside the panel close it natively without going
            // through dismiss(); willClose is the one signal common to every
            // such path.
            closeObservation = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: panel, queue: .main
            ) { _ in
                MainActor.assumeIsolated { QuickLookService.shared.panelDidClose() }
            }
        }
    }

    /// Keeps the panel's center on the screen's center. setFrameOrigin only
    /// moves the window, so this cannot re-trigger the resize notification.
    /// Once the user has dragged the panel somewhere on purpose, their
    /// placement wins and this becomes a no-op for the rest of the session.
    private func recenterPanel() {
        guard !userHasMovedPanel,
              let panel = QLPreviewPanel.shared(), panel.isVisible, !panel.inLiveResize,
              let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = panel.frame
        isRecentering = true
        panel.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                                     y: visible.midY - frame.height / 2))
        isRecentering = false
    }

    private func panelDidClose() {
        indexObservation = nil
        purgeTemporaryFiles()
        onPanelDidClose?()
    }

    /// The clip the panel is showing right now, resolved from the panel's
    /// own index. The bar's selection trails the panel by an async KVO hop,
    /// so callers reacting to a keystroke inside the panel must use this
    /// rather than the bar's selected item.
    var currentClipID: UUID? {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return nil }
        return clipID(forPreviewIndex: panel.currentPreviewItemIndex)
    }

    /// A clip can own more than one preview item (e.g. multiple files), so
    /// the match is the clip whose own range of items contains this index,
    /// not an exact key lookup.
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
        purgeTemporaryFiles()
        try? FileManager.default.createDirectory(at: temporaryDirectory,
                                                  withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
    }

    /// The preview files are plain-text copies of clip content, so they must
    /// not outlive the panel that needed them: purged on every dismissal and
    /// again at app termination.
    func purgeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func write(_ data: Data, named title: String, extension fileExtension: String) -> URL? {
        let safeTitle = title.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = "\(safeTitle.isEmpty ? "Clip" : safeTitle)-\(UUID().uuidString).\(fileExtension)"
        let url = temporaryDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
