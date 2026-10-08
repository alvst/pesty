import AppKit
import SwiftUI

/// Lets a plain mouse wheel scroll a horizontal strip.
///
/// Every scrollable surface in the bar runs horizontally, and a wheel only
/// reports vertical deltas — so without this a user on a mouse rather than a
/// trackpad cannot move the card strip at all. Trackpad gestures already carry
/// a horizontal delta and are left untouched.
///
/// Place it in a `background` behind the scroll view it should drive; it draws
/// nothing and takes no hits.
struct HorizontalScrollWheelSupport: NSViewRepresentable {
    func makeNSView(context: Context) -> HorizontalScrollWheelView { HorizontalScrollWheelView() }
    func updateNSView(_ view: HorizontalScrollWheelView, context: Context) {}

    static func dismantleNSView(_ view: HorizontalScrollWheelView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class HorizontalScrollWheelView: NSView {
    private var monitor: Any?

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The smallest horizontally-scrollable scroll view under the pointer.
    /// Smallest, because the bar nests strips inside panels: the one the
    /// cursor is actually over is the innermost match, not the outermost.
    private func targetScrollView(for event: NSEvent) -> NSScrollView? {
        guard let contentView = window?.contentView else { return nil }

        func descendants(of view: NSView) -> [NSScrollView] {
            view.subviews.flatMap { child in
                ((child as? NSScrollView).map { [$0] } ?? []) + descendants(of: child)
            }
        }

        return descendants(of: contentView)
            .filter { scrollView in
                guard let document = scrollView.documentView,
                      document.bounds.width > scrollView.contentView.bounds.width + 1
                else { return false }
                return scrollView.visibleRect.contains(scrollView.convert(event.locationInWindow, from: nil))
            }
            .min { $0.visibleRect.width * $0.visibleRect.height < $1.visibleRect.width * $1.visibleRect.height }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === window,
              bounds.contains(convert(event.locationInWindow, from: nil)),
              // A trackpad swipe that is mostly horizontal is already handled
              // by SwiftUI; only redirect a gesture that is clearly vertical.
              event.scrollingDeltaY != 0,
              abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
              let scrollView = targetScrollView(for: event),
              let document = scrollView.documentView
        else { return event }

        let clipView = scrollView.contentView
        // A wheel reports coarse line deltas rather than pixels, so one notch
        // has to be scaled up to move a card-width strip a useful distance.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 24
        let minX = document.bounds.minX
        let maxX = max(minX, document.bounds.maxX - clipView.bounds.width)
        let targetX = min(maxX, max(minX, clipView.bounds.origin.x - event.scrollingDeltaY * scale))
        guard targetX != clipView.bounds.origin.x else { return event }

        clipView.scroll(to: NSPoint(x: targetX, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
        return nil
    }

    func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    deinit { stopMonitoring() }
}
