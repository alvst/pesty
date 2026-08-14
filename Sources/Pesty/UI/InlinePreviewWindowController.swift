import AppKit
import SwiftUI

private final class InlinePreviewPanel: NSPanel {
    // Keep keyboard focus in the Paste Bar while the preview remains clickable.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A compact, non-modal preview anchored above the selected clip. It leaves the
/// Paste Bar at its normal height instead of turning it into a preview sheet.
@MainActor
final class InlinePreviewWindowController: NSWindowController {
    private let hostingView: NSHostingView<AnyView>
    private var currentItemID: UUID?
    private var currentPointerOffset: CGFloat = 0

    init() {
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        hostingView = host

        let panel = InlinePreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 340),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.modalPanel.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.contentView = host

        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func show(item: ClipItem, anchoredTo cardFrame: CGRect, in barWindow: NSWindow) {
        guard let panel = window,
              let screen = barWindow.screen
                    ?? NSScreen.screens.first(where: { $0.frame.intersects(barWindow.frame) })
                    ?? NSScreen.main else { return }

        let cardOnScreen = NSRect(
            x: barWindow.frame.minX + cardFrame.minX,
            y: barWindow.frame.minY + barWindow.frame.height - cardFrame.maxY,
            width: cardFrame.width,
            height: cardFrame.height
        )
        let presentation = presentationFrame(for: cardOnScreen, on: screen)

        if !panel.isVisible || currentItemID != item.id || abs(currentPointerOffset - presentation.pointerOffset) > 1 {
            hostingView.rootView = AnyView(
                PestyPreviewPopover(item: item, pointerOffset: presentation.pointerOffset)
            )
            currentItemID = item.id
            currentPointerOffset = presentation.pointerOffset
        }

        panel.setFrame(presentation.frame, display: true)
        // A non-key panel would otherwise remain behind the key Paste Bar.
        panel.orderFrontRegardless()
        barWindow.makeKey()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func presentationFrame(for card: NSRect, on screen: NSScreen) -> (frame: NSRect, pointerOffset: CGFloat) {
        let visible = screen.visibleFrame
        let horizontalInset: CGFloat = 20
        let width = min(540, max(360, visible.width - horizontalInset * 2))
        let minX = visible.minX + horizontalInset
        let maxX = visible.maxX - horizontalInset - width
        let x = min(max(minX, card.midX - width / 2), maxX)

        let arrowTipY = card.maxY - 2
        let availableHeight = visible.maxY - arrowTipY - 20
        let height = min(420, max(260, availableHeight))
        let pointerLimit = max(0, width / 2 - 34)
        let pointerOffset = min(pointerLimit, max(-pointerLimit, card.midX - (x + width / 2)))

        return (NSRect(x: x, y: arrowTipY, width: width, height: height), pointerOffset)
    }
}
