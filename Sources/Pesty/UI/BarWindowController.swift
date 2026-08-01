import AppKit
import SwiftUI

final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if AppController.shared.handleBarCommandShortcut(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class BarWindowController: NSWindowController, NSWindowDelegate {

    private static let slideDuration: TimeInterval = 0.18
    private static let slideOvershoot: CGFloat = 16
    private var isPresenting = false
    private var isDismissing = false
    /// Identifies the latest presentation or dismissal. Completion handlers
    /// use it to avoid ordering the panel out after a newer transition begins.
    private var transitionID = 0

    init() {
        let panel = BarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 360),
            // Preserve the front app's first responder (for example, a
            // focused Safari field) while Pesty receives navigation keys.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.contentView = NSHostingView(rootView: BarView())
        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    /// The bar is available for interaction while it is on screen or entering,
    /// but not after a dismissal has begun. `NSWindow.isVisible` stays true for
    /// the latter case until the slide-down completion handler orders it out.
    var isPresented: Bool {
        window?.isVisible == true && !isDismissing
    }

    func show() {
        guard let panel = window else { return }
        transitionID &+= 1
        let presentationTransitionID = transitionID
        isDismissing = false
        isPresenting = true
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens.first else { isPresenting = false; return }
        let vf = screen.visibleFrame
        let height = CGFloat(Settings.shared.barHeight)
        let onScreen = NSRect(x: vf.minX, y: vf.minY, width: vf.width, height: height)
        let offScreen = belowScreenFrame(for: onScreen)

        // Make the panel key before it starts moving. That keeps an immediately
        // following arrow key responsive while the bar and its cards rise as a
        // single surface from below the screen.
        panel.setFrame(offScreen, display: false)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(onScreen, display: true)
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.transitionID == presentationTransitionID else { return }
                self.isPresenting = false
            }
        })
    }

    func hide(immediately: Bool = false) {
        guard let panel = window, panel.isVisible else { return }
        // An explicit paste should always win over an already-running visual
        // dismissal so the panel cannot receive the synthetic paste shortcut.
        guard immediately || !isDismissing else { return }
        transitionID &+= 1
        let dismissalTransitionID = transitionID
        isPresenting = false
        if immediately {
            isDismissing = false
            panel.orderOut(nil)
            return
        }
        isDismissing = true
        let off = belowScreenFrame(for: panel.frame)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.slideDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(off, display: true)
        }, completionHandler: { [weak self, weak panel] in
            DispatchQueue.main.async {
                guard let self, let panel,
                      self.transitionID == dismissalTransitionID else { return }
                panel.orderOut(nil)
                self.isDismissing = false
            }
        })
    }

    /// Updates the open panel immediately so dragging the resize handle feels
    /// attached to the bar instead of merely changing a future preference.
    func resize(to height: CGFloat) {
        guard let panel = window, panel.isVisible else { return }
        guard let screen = panel.screen
                ?? NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) })
                ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.minX, y: visible.minY,
                              width: visible.width, height: height), display: true)
    }

    private func belowScreenFrame(for frame: NSRect) -> NSRect {
        NSRect(x: frame.minX,
               y: frame.minY - frame.height - Self.slideOvershoot,
               width: frame.width,
               height: frame.height)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let panel = notification.object as? NSWindow,
              Settings.shared.hideOnClickOutside,
              !isPresenting,
              !AppController.shared.suppressAutoHide else { return }
        // A preview panel becomes key immediately after the strip hands it a
        // clip. Defer until that transition is visible before deciding whether
        // focus actually left Pesty.
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel,
                  panel.isVisible,
                  !panel.isKeyWindow,
                  !self.isPresenting,
                  !QuickLookService.shared.isVisible,
                  !ClipboardStore.shared.inlinePreviewVisible else { return }
            AppController.shared.hideBar()
        }
    }
}
