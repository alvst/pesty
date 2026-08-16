import AppKit
import SwiftUI
import Carbon.HIToolbox

final class PasteStackPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PasteStackWindowController: NSWindowController, NSWindowDelegate {
    var isVisible: Bool { window?.isVisible == true }
    private var keyMonitor: Any?
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
        startKeyMonitor()
    }

    func hide() {
        stopKeyMonitor()
        window?.orderOut(nil)
    }

    /// The tray was mouse-only: the bar's central key monitor deliberately
    /// ignores every non-bar window. A local monitor scoped to this panel
    /// gives it arrow-key/Return navigation without touching bar handling.
    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === window else { return event }
            return handleKey(event)
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let sequence = PasteSequence.shared
        // The tray's list filters by the bar's shared search text, so
        // navigation must use the same filter - arrowing with an empty
        // query would walk entries the tray isn't even showing, and Return
        // could paste one of them.
        let query = ClipboardStore.shared.searchText
        switch Int(event.keyCode) {
        case kVK_UpArrow, kVK_LeftArrow:
            sequence.moveSelection(by: -1, matching: query)
            return nil
        case kVK_DownArrow, kVK_RightArrow:
            sequence.moveSelection(by: 1, matching: query)
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard !event.isARepeat else { return nil }
            if let entry = sequence.visibleEntries(matching: query)
                .first(where: { $0.id == sequence.selectedEntryID }) {
                AppController.shared.pasteStackEntry(entry)
            }
            return nil
        case kVK_Escape:
            AppController.shared.hidePasteStack()
            return nil
        default:
            return event
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // The collector is deliberately persistent: after a paste it shows
        // which clip is next, even though focus has returned to the target app.
        // The user closes it explicitly with its close button.
    }
}
