import AppKit
import SwiftUI

/// Drags a clip card out of the bar via a native pasteboard session - this
/// replaces SwiftUI's `.onDrag`, which only supports a single payload and
/// gives no visibility into where the drag is on screen. Tracking that
/// position is what lets the bar stay open while a drag is still hovering
/// over it (e.g. dropping onto a Pinboard tab to pin the clip) and only
/// drop once the drag has genuinely left the bar for whatever's underneath.
struct ClipDragSource: NSViewRepresentable {
    /// Deferred: building writers re-encodes an image clip's full bitmap, so
    /// it must only run when a drag actually starts - never as part of
    /// evaluating the card's view body.
    let makeWriters: () -> [NSPasteboardWriting]
    let onSelect: () -> Void
    let onToggleSelect: () -> Void
    let onExtendSelect: () -> Void
    let onOpen: () -> Void
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
        view.makeWriters = makeWriters
        view.onSelect = onSelect
        view.onToggleSelect = onToggleSelect
        view.onExtendSelect = onExtendSelect
        view.onOpen = onOpen
        view.onDragExitedBar = onDragExitedBar
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    var makeWriters: () -> [NSPasteboardWriting] = { [] }
    var onSelect: () -> Void = {}
    var onToggleSelect: () -> Void = {}
    var onExtendSelect: () -> Void = {}
    var onOpen: () -> Void = {}
    var onDragExitedBar: () -> Void = {}

    private var mouseDownLocation: NSPoint?
    private var mouseDownClickCount = 0
    private var startedDragging = false
    private var dragAttemptFailed = false
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
        dragAttemptFailed = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !startedDragging, !dragAttemptFailed, let start = mouseDownLocation else { return }
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - start.x, current.y - start.y) >= 4 else { return }

        let writers = makeWriters()
        guard !writers.isEmpty else {
            // Nothing draggable after all (e.g. the backing image file is
            // gone). Don't retry the expensive build on every drag pixel;
            // the release still counts as a normal click.
            dragAttemptFailed = true
            return
        }

        startedDragging = true
        hasExitedBar = false
        let preview = snapshot(writers: writers)
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
        // it has to reproduce the shift/cmd multi-select gestures SwiftUI
        // would otherwise own instead of just falling through to them.
        if event.modifierFlags.contains(.shift) {
            onExtendSelect()
        } else if event.modifierFlags.contains(.command) {
            onToggleSelect()
        } else {
            onSelect()
            if mouseDownClickCount >= 2 { onOpen() }
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    /// The bar should stay open while a drag is still hovering over it - e.g.
    /// dropping a clip onto a Pinboard tab to pin it - and only drop once the
    /// drag genuinely leaves the bar's window, freeing it to land on whatever
    /// pasteboard-accepting app or field is underneath.
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard !hasExitedBar, let window else { return }
        guard !window.frame.contains(screenPoint) else { return }
        hasExitedBar = true
        onDragExitedBar()
    }

    private func snapshot(writers: [NSPasteboardWriting]) -> NSImage {
        guard let contentView = window?.contentView else {
            return fallbackPreview(writers: writers)
        }
        let rectInWindow = convert(bounds, to: nil)
        let rectInContent = contentView.convert(rectInWindow, from: nil)
        guard let representation = contentView.bitmapImageRepForCachingDisplay(in: rectInContent) else {
            return fallbackPreview(writers: writers)
        }
        contentView.cacheDisplay(in: rectInContent, to: representation)
        representation.size = bounds.size
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return roundedPreview(image)
    }

    private func fallbackPreview(writers: [NSPasteboardWriting]) -> NSImage {
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
