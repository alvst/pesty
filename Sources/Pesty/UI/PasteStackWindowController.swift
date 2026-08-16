import AppKit
import Carbon.HIToolbox
import SwiftUI

final class PasteStackPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosts the floating Paste Stack card list: a small, always-on-top panel
/// positioned near the bottom-right corner of the active screen so it stays
/// out of the way while the user copies clips in other apps.
@MainActor
final class PasteStackWindowController: NSWindowController, NSWindowDelegate {
    private var keyMonitor: Any?

    var isVisible: Bool { window?.isVisible == true }

    init() {
        let panel = PasteStackPanel(
            contentRect: NSRect(x: 0, y: 0, width: 318, height: 464),
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
        startKeyMonitor()
    }

    func hide() {
        stopKeyMonitor()
        window?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        // The panel is deliberately persistent: after a paste it keeps showing
        // what's next, even though focus has returned to the target app. The
        // user dismisses it explicitly with its own close button.
        stopKeyMonitor()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        startKeyMonitor()
    }

    /// Arrow-key navigation and Enter-to-paste while the panel holds focus.
    /// A local monitor (rather than SwiftUI focus) keeps this independent of
    /// whichever card view happens to be under the mouse.
    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleKey(event)
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let sequence = PasteSequence.shared
        switch Int(event.keyCode) {
        case kVK_UpArrow, kVK_LeftArrow:
            sequence.moveSelection(by: -1)
            return nil
        case kVK_DownArrow, kVK_RightArrow:
            sequence.moveSelection(by: 1)
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let entry = sequence.selectedEntry {
                AppController.shared.pasteStackEntry(entry)
            }
            return nil
        default:
            return event
        }
    }
}
