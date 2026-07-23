import AppKit
import SwiftUI

final class PasteStackPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PasteStackWindowController: NSWindowController, NSWindowDelegate {
    var isVisible: Bool { window?.isVisible == true }
    init() {
        let panel = PasteStackPanel(
            contentRect: NSRect(x: 0, y: 0, width: 318, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: PasteStackView())
        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func show() {
        guard let panel = window else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let x = visible.maxX - panel.frame.width - 22
        let y = min(visible.maxY - panel.frame.height - 22,
                    visible.minY + CGFloat(Settings.shared.barHeight) + 14)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        window?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Moving back to the Pesty bar is part of collecting clips. A click in
        // another app, however, should keep the existing click-outside behavior.
        DispatchQueue.main.async {
            guard Settings.shared.hideOnClickOutside,
                  !(NSApp.keyWindow is BarPanel) else { return }
            AppController.shared.hideBar()
            AppController.shared.hidePasteStack()
        }
    }
}
