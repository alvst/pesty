import AppKit
import Carbon.HIToolbox

@MainActor
enum PasteService {

    @discardableResult
    static func copy(_ item: ClipItem, to pasteboard: NSPasteboard = .general) -> Int {
        if item.type == .image {
            guard let img = ClipboardStore.shared.loadImage(for: item) else {
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
                      monitor: ClipboardMonitor) {
        let change = copy(item)
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
        // Let physical shortcut modifiers clear before synthesizing Command-V.
        // Otherwise the target app can receive the user's original shortcut
        // instead of a plain paste.
        target.activate()
        waitForFrontmost(target, attempts: 30)
        #endif
    }

    #if !MAS
    private static func waitForFrontmost(_ app: NSRunningApplication, attempts: Int) {
        guard attempts > 0, !app.isTerminated else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            waitForShortcutModifiersToRelease(attempts: 30)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            waitForFrontmost(app, attempts: attempts - 1)
        }
    }

    private static func waitForShortcutModifiersToRelease(attempts: Int) {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let shortcutMask = CGEventFlags.maskCommand.rawValue
            | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskShift.rawValue
        let modifiersHeld = flags.rawValue & shortcutMask

        guard modifiersHeld == 0 || attempts == 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                waitForShortcutModifiersToRelease(attempts: attempts - 1)
            }
            return
        }

        // Allow the target app one more turn through the run loop after activation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { sendCommandV() }
    }

    private static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    @discardableResult
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
    #endif
}
