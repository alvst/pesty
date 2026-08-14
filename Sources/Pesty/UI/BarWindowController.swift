import AppKit
import SwiftUI
import Carbon.HIToolbox

final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Give a tracking context menu first refusal. Otherwise Cmd-C on a
        // right-clicked card could copy the bar's selected card instead.
        if super.performKeyEquivalent(with: event) { return true }

        // AppKit routes Command-key combinations through key equivalents before
        // SwiftUI receives a keyDown event. Handle bar-level Copy only after a
        // menu has had the opportunity to consume its own shortcut.
        if event.keyCode == kVK_ANSI_C, event.modifierFlags.contains(.command) {
            AppController.shared.commandCopy()
            return true
        }
        return false
    }
}

@MainActor
final class BarWindowController: NSWindowController, NSWindowDelegate {

    private static let slideDuration: TimeInterval = 0.18
    private static let slideOvershoot: CGFloat = 16
    private var isPresenting = false
    private var isDismissing = false
    private var transitionID = 0
    private let searchBridge = BarSearchFieldBridge()

    /// `NSWindow.isVisible` remains true while the dismissal animation moves
    /// the panel below the screen. Treat that state as hidden to callers that
    /// need to reveal Pesty again.
    var isPresented: Bool {
        window?.isVisible == true && !isDismissing
    }

    init() {
        let panel = BarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 360),
            // A non-activating panel can take key events without taking the
            // previous app's first responder away. That keeps a focused Safari
            // field ready for the eventual paste after the global shortcut.
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
        let content = NSHostingView(rootView: BarView(searchBridge: searchBridge))
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.contentView = content
            glass.cornerRadius = Theme.cornerRadius
            glass.tintColor = NSColor.black.withAlphaComponent(0.12)
            glass.style = .regular
            panel.contentView = glass
        } else {
            panel.contentView = content
        }
        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func show() {
        guard let panel = window else { return }
        transitionID &+= 1
        let showTransitionID = transitionID
        isDismissing = false
        isPresenting = true
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens.first else { isPresenting = false; return }
        let vf = screen.visibleFrame
        let height = CGFloat(Settings.shared.barHeight)
        let onScreen = NSRect(x: vf.minX, y: vf.minY, width: vf.width, height: height)
        let offScreen = belowScreenFrame(for: onScreen)

        // Make the non-activating panel key before it starts moving, so arrow
        // navigation remains immediate while the entire bar slides in as one
        // surface.
        panel.setFrame(offScreen, display: false)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(onScreen, display: true)
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.transitionID == showTransitionID else { return }
                self.isPresenting = false
            }
        })
    }

    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
    }

    var searchOwnsFirstResponder: Bool {
        searchBridge.ownsFirstResponder(in: window)
    }

    @discardableResult
    func focusSearchAtEnd() -> Bool {
        searchBridge.focusAtEnd()
    }

    func resignSearch() {
        searchBridge.resign()
    }

    func hide(immediately: Bool = false) {
        guard let panel = window, panel.isVisible, !isDismissing else { return }
        isPresenting = false
        isDismissing = true
        transitionID &+= 1
        let hideTransitionID = transitionID
        if immediately {
            panel.orderOut(nil)
            isDismissing = false
            return
        }
        let off = belowScreenFrame(for: panel.frame)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.slideDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(off, display: true)
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.transitionID == hideTransitionID else { return }
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
        let frame = NSRect(x: visible.minX,
                           y: visible.minY,
                           width: visible.width,
                           height: height)
        panel.setFrame(frame, display: true)
    }

    private func belowScreenFrame(for frame: NSRect) -> NSRect {
        NSRect(x: frame.minX,
               y: frame.minY - frame.height - Self.slideOvershoot,
               width: frame.width,
               height: frame.height)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard Settings.shared.hideOnClickOutside,
              !isPresenting,
              !AppController.shared.suppressAutoHide,
              !AppController.shared.isRestoringEditorFocus else { return }
        // Key focus briefly moves to Quick Look or the Paste Stack tray while
        // both remain companion surfaces to the bar. Defer one run loop so the
        // new key window is known before deciding whether focus really left Pesty.
        DispatchQueue.main.async {
            guard !AppController.shared.suppressAutoHide,
                  !AppController.shared.isRestoringEditorFocus else { return }
            guard QuickLookService.shared.isVisible || NSApp.keyWindow is PasteStackPanel else {
                AppController.shared.hideBar()
                return
            }
        }
    }
}
