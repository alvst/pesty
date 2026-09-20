import AppKit

/// Catches the dismissal click before it reaches the underlying document.
/// A global event monitor runs too late: Safari has already cleared its text
/// selection by the time the monitor tells us to hide the bar.
@MainActor
final class BarOutsideClickShield {
    private var panels: [BarDismissalPanel] = []

    func show(onDismiss: @escaping () -> Void) {
        hide()
        panels = NSScreen.screens.map { screen in
            let panel = BarDismissalPanel(frame: screen.frame, onDismiss: onDismiss)
            panel.orderFrontRegardless()
            return panel
        }

        // Settings and standalone previews are ordinary windows. Keep them
        // clickable above the shield; floating companion panels already sit
        // at a higher level. Reverse the order to retain their relative order.
        for window in NSApp.orderedWindows.reversed()
        where !(window is BarDismissalPanel)
            && window.isVisible && window.isOnActiveSpace && window.level == .normal {
            window.orderFrontRegardless()
        }
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}

final class BarDismissalPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: NSRect, onDismiss: @escaping () -> Void) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        level = .normal
        // Keep a nonzero backing alpha so the entire rectangle participates
        // in WindowServer hit testing, with no perceptible visual overlay.
        backgroundColor = NSColor.black.withAlphaComponent(0.001)
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        ignoresMouseEvents = false
        isExcludedFromWindowsMenu = true
        setAccessibilityElement(false)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = BarDismissalView(onDismiss: onDismiss)
    }
}

final class BarDismissalView: NSView {
    private let onDismiss: () -> Void
    private var didDismiss = false

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { dismiss() }
    override func rightMouseDown(with event: NSEvent) { dismiss() }
    override func otherMouseDown(with event: NSEvent) { dismiss() }

    private func dismiss() {
        guard !didDismiss else { return }
        didDismiss = true
        onDismiss()
    }
}
