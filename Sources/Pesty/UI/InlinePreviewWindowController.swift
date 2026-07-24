import AppKit
import SwiftUI

private final class InlinePreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosts the Inline Pesty preview in its own floating panel. Keeping it separate
/// from the bar lets the card strip retain its normal size and makes the preview
/// read as a document window anchored to the selected clip.
@MainActor
final class InlinePreviewWindowController: NSWindowController {
    private let hostingView: NSHostingView<AnyView>
    private var currentItemID: UUID?
    private var currentPointerOffset: CGFloat = 0

    init() {
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        hostingView = host

        let panel = InlinePreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 430),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
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

    func show(item: ClipItem, anchoredTo cardFrame: CGRect, in barPanel: NSWindow) {
        guard let panel = window,
              let screen = barPanel.screen
                    ?? NSScreen.screens.first(where: { $0.frame.intersects(barPanel.frame) })
                    ?? NSScreen.main else { return }

        let cardOnScreen = NSRect(
            x: barPanel.frame.minX + cardFrame.minX,
            y: barPanel.frame.minY + barPanel.frame.height - cardFrame.maxY,
            width: cardFrame.width,
            height: cardFrame.height)
        let presentation = presentationFrame(for: cardOnScreen, on: screen)

        let needsNewContent = !panel.isVisible
            || currentItemID != item.id
            || abs(currentPointerOffset - presentation.pointerOffset) > 1
        if needsNewContent {
            hostingView.rootView = AnyView(
                PestyPreviewPopover(item: item, pointerOffset: presentation.pointerOffset)
            )
            currentItemID = item.id
            currentPointerOffset = presentation.pointerOffset
        }

        panel.setFrame(presentation.frame, display: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func presentationFrame(for card: NSRect, on screen: NSScreen) -> (frame: NSRect, pointerOffset: CGFloat) {
        let visible = screen.visibleFrame
        let horizontalInset: CGFloat = 34
        let width = min(1_180, max(360, visible.width - horizontalInset * 2))
        let minX = visible.minX + horizontalInset
        let maxX = visible.maxX - horizontalInset - width
        let desiredX = card.midX - width / 2
        let x = min(max(minX, desiredX), maxX)

        // The pointer tip lands immediately above the card header, while the
        // document sheet extends upward into its own window above the bar.
        let arrowTipY = card.maxY - 2
        let availableHeight = visible.maxY - arrowTipY - 30
        let height = min(470, max(250, availableHeight))
        let pointerLimit = max(0, width / 2 - 42)
        let pointerOffset = min(pointerLimit, max(-pointerLimit, card.midX - (x + width / 2)))

        return (
            NSRect(x: x, y: arrowTipY, width: width, height: height),
            pointerOffset
        )
    }
}
