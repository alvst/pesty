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
final class BarWindowController: NSWindowController {

    private static let slideDuration: TimeInterval = 0.18
    private static let slideOvershoot: CGFloat = 16
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
            // Take keyboard focus without changing the active application's
            // menu bar or disturbing the eventual paste destination.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Focus changes are not outside clicks. AppController's actual-click
        // handling owns automatic dismissal, including during presentation.
        panel.hidesOnDeactivate = false
        panel.sharingType = Settings.shared.showDuringScreenSharing ? .readOnly : .none
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func show() {
        guard let panel = window else { return }
        searchBridge.resetForPresentation()
        transitionID &+= 1
        isDismissing = false
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: {
            NSMouseInRect(mouse, $0.frame, false)
        }) ?? NSScreen.screens.min {
            distanceSquared(from: mouse, to: $0.frame) < distanceSquared(from: mouse, to: $1.frame)
        }
        guard let screen else { return }
        let vf = screen.visibleFrame
        let height = min(CGFloat(Settings.shared.barHeight), vf.height)
        let onScreen = NSRect(x: vf.minX, y: vf.minY, width: vf.width, height: height)
        let offScreen = belowScreenFrame(for: onScreen)

        // A show can race a dismissal when the user summons the bar again
        // during the slide-out. Stop the old implicit animation before
        // staging the new display's frame, otherwise AppKit interpolates from
        // the previous screen and visibly flies the bar across displays.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().setFrame(panel.frame, display: true)
        }
        // Make the panel key before it starts moving, so arrow navigation is
        // available immediately while the entire bar slides in as one surface.
        panel.setFrame(offScreen, display: false)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(onScreen, display: true)
        }
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

    private func distanceSquared(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = max(rect.minX - point.x, max(0, point.x - rect.maxX))
        let dy = max(rect.minY - point.y, max(0, point.y - rect.maxY))
        return dx * dx + dy * dy
    }

}
