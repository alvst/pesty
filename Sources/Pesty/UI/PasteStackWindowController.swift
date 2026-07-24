import AppKit
import SwiftUI

final class PasteStackPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PasteStackWindowController: NSWindowController {
    init() {
        let panel = PasteStackPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 380),
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func show() {
        guard let panel = window else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.maxX - panel.frame.width - 22,
                             y: visible.maxY - panel.frame.height - 22)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        window?.orderOut(nil)
    }
}
