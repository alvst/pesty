import AppKit
import SwiftUI

/// Drags a clip card out of the bar via a native pasteboard session — this
/// replaces SwiftUI's `.onDrag`, which only supports a single payload (a
/// multi-file clip silently dropped all but its first file) and gives no
/// visibility into where the drag is on screen. Tracking that position is
/// what lets the bar stay open while a drag is still hovering over it
/// (e.g. dropping onto a Pinboard tab) and hide only once the drag has
/// genuinely left the bar for whatever's underneath.
struct ClipDragSource: NSViewRepresentable {
    let writers: [NSPasteboardWriting]
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onDragStarted: () -> Void
    let onDragExitedBar: () -> Void

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        update(view)
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        update(view)
    }

    private func update(_ view: DragSourceView) {
        view.writers = writers
        view.onSelect = onSelect
        view.onOpen = onOpen
        view.onDragStarted = onDragStarted
        view.onDragExitedBar = onDragExitedBar
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    var writers: [NSPasteboardWriting] = []
    var onSelect: () -> Void = {}
    var onOpen: () -> Void = {}
    var onDragStarted: () -> Void = {}
    var onDragExitedBar: () -> Void = {}

    private var mouseDownLocation: NSPoint?
    private var mouseDownClickCount = 0
    private var startedDragging = false
    private var hasExitedBar = false

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NSApp.currentEvent?.type == .leftMouseDown else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        mouseDownClickCount = event.clickCount
        startedDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !startedDragging, let start = mouseDownLocation, !writers.isEmpty else { return }
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - start.x, current.y - start.y) >= 4 else { return }

        startedDragging = true
        hasExitedBar = false
        onDragStarted()
        let preview = snapshot()
        let items = writers.map { writer -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(bounds, contents: preview)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = writers.count > 1 ? .pile : .none
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocation = nil
            mouseDownClickCount = 0
            startedDragging = false
        }
        guard !startedDragging else { return }
        // This view's hitTest claims every left-mouse-down over the card, so
        // it has to reproduce the click gestures SwiftUI would otherwise own.
        onSelect()
        if mouseDownClickCount >= 2 { onOpen() }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    /// The bar should stay open while a drag is still hovering over it — e.g.
    /// dropping a clip onto a Pinboard tab to pin it — and only hide once the
    /// drag genuinely leaves the bar's window, freeing it to land on whatever
    /// pasteboard-accepting app or field is underneath.
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard !hasExitedBar, let window else { return }
        guard !window.frame.contains(screenPoint) else { return }
        hasExitedBar = true
        onDragExitedBar()
    }

    private func snapshot() -> NSImage {
        guard let contentView = window?.contentView else {
            return fallbackPreview()
        }
        let rectInWindow = convert(bounds, to: nil)
        let rectInContent = contentView.convert(rectInWindow, from: nil)
        guard let representation = contentView.bitmapImageRepForCachingDisplay(in: rectInContent) else {
            return fallbackPreview()
        }
        contentView.cacheDisplay(in: rectInContent, to: representation)
        representation.size = bounds.size
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return roundedPreview(image)
    }

    private func fallbackPreview() -> NSImage {
        let icon: NSImage
        if let fileURL = writers.first as? NSURL, fileURL.isFileURL, let path = fileURL.path {
            icon = NSWorkspace.shared.icon(forFile: path)
        } else {
            icon = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil) ?? NSImage()
        }
        return NSImage(size: bounds.size, flipped: false) { rect in
            let side = min(64, rect.width, rect.height)
            let iconRect = NSRect(
                x: rect.midX - side / 2,
                y: rect.midY - side / 2,
                width: side,
                height: side
            )
            icon.draw(in: iconRect)
            return true
        }
    }

    private func roundedPreview(_ source: NSImage) -> NSImage {
        let size = bounds.size
        let clipPath = RoundedRectangle(
            cornerRadius: Theme.cardCorner,
            style: .continuous
        ).path(in: CGRect(origin: .zero, size: size)).cgPath
        return NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.addPath(clipPath)
            context.clip()
            source.draw(in: rect)
            context.restoreGState()
            return true
        }
    }
}
