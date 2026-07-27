import AppKit
import Carbon.HIToolbox

@MainActor
enum PasteService {

    @discardableResult
    static func copy(_ item: ClipItem,
                     to pasteboard: NSPasteboard = .general,
                     asPlainText: Bool = false,
                     imageOverride: NSImage? = nil) -> Int {
        if asPlainText {
            guard let text = item.plainText else { return pasteboard.changeCount }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return pasteboard.changeCount
        }
        if item.type == .image {
            guard let img = imageOverride ?? ClipboardStore.shared.loadImage(for: item) else {
                return pasteboard.changeCount
            }
            pasteboard.clearContents()
            pasteboard.writeObjects([img])
            return pasteboard.changeCount
        }
        pasteboard.clearContents()
        switch item.type {
        case .image:
            break
        case .file:
            let urls = item.fileURLs.compactMap { URL(string: $0) }
            if !urls.isEmpty { pasteboard.writeObjects(urls as [NSURL]) }
            if let t = item.text { pasteboard.setString(t, forType: .string) }
        case .color:
            if let hex = item.colorHex, let c = NSColor(hex: hex) {
                pasteboard.writeObjects([c])
                pasteboard.setString(hex, forType: .string)
            }
        case .richText:
            if let rtf = item.rtfData { pasteboard.setData(rtf, forType: .rtf) }
            if let t = item.text { pasteboard.setString(t, forType: .string) }
        case .text, .link:
            if let t = item.text { pasteboard.setString(t, forType: .string) }
        }
        return pasteboard.changeCount
    }

    static func paste(_ item: ClipItem,
                      into targetApp: NSRunningApplication?,
                      monitor: ClipboardMonitor,
                      asPlainText: Bool = false,
                      imageOverride: NSImage? = nil) {
        let change = copy(item, asPlainText: asPlainText, imageOverride: imageOverride)
        monitor.suppressUntilChangeCount = change
        if Settings.shared.playSound { NSSound(named: "Pop")?.play() }

        guard let target = targetApp, !target.isTerminated else { return }

        #if MAS
        // Mac App Store (sandboxed) build: copy the clip and return focus to the
        // app the user came from so they can paste with ⌘V. No Accessibility
        // APIs and no synthetic keystrokes are used.
        target.activate()
        #else
        // Direct-download build: optionally paste straight into the active app by
        // synthesizing ⌘V. This requires the user's Accessibility grant.
        guard Settings.shared.pasteDirectly && AXIsProcessTrusted() else { return }
        beginDirectPaste(into: target)
        #endif
    }

    #if !MAS
    private static func beginDirectPaste(into target: NSRunningApplication) {
        guard !target.isTerminated else { return }

        // The ordinary path is a non-activating Paste Bar, so the target is
        // still active and its first responder is still intact. Avoid a second
        // activation request in that path; it only introduces a focus race.
        if target.isActive {
            waitForPasteTriggerToRelease(for: target)
            return
        }

        // A menu-bar/reopen path can genuinely leave Pesty frontmost. Request
        // cooperative activation only when Pesty is active; otherwise use the
        // normal activation request for the selected target.
        if NSApp.isActive {
            NSApp.yieldActivation(to: target)
            guard target.activate(from: .current, options: []) else { return }
        } else {
            target.activate(options: [])
        }
        waitForTargetActivation(target, attempts: 30)
    }

    private static func waitForTargetActivation(_ target: NSRunningApplication, attempts: Int) {
        guard !target.isTerminated else { return }
        if target.isActive {
            waitForPasteTriggerToRelease(for: target)
            return
        }
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            waitForTargetActivation(target, attempts: attempts - 1)
        }
    }

    private static func waitForPasteTriggerToRelease(for target: NSRunningApplication) {
        guard !target.isTerminated else { return }

        // `.hidSystemState` observes the keys that are physically down; the
        // combined session state can include our synthetic event source.
        let flags = CGEventSource.flagsState(.hidSystemState)
        let shortcutMask = CGEventFlags.maskCommand.rawValue
            | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskShift.rawValue
        let modifiersHeld = flags.rawValue & shortcutMask
        let returnHeld = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_Return))
            || CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_ANSI_KeypadEnter))

        guard modifiersHeld == 0, !returnHeld else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                waitForPasteTriggerToRelease(for: target)
            }
            return
        }

        // Return's handler completes before the direct app-targeted paste is
        // injected. There is no arbitrary handoff delay or global focus race.
        DispatchQueue.main.async {
            guard !target.isTerminated, target.isActive else { return }
            sendCommandV(to: target.processIdentifier)
        }
    }

    private static func sendCommandV(to processIdentifier: pid_t) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(processIdentifier)
        up.postToPid(processIdentifier)
    }

    @discardableResult
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
    #endif
}
