import AppKit
import Carbon.HIToolbox

@MainActor
enum PasteService {
    /// Shared pasteboard marker understood by clipboard managers. It identifies the
    /// application which placed the current content on the pasteboard, even though
    /// Pesty is not the foreground app by the time another manager observes it.
    private static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")
    private static let sourceBundleID = "com.greycorelabs.pesty"

    @discardableResult
    static func copy(_ item: ClipItem,
                     to pasteboard: NSPasteboard = .general,
                     asPlainText: Bool = false,
                     imageOverride: NSImage? = nil) -> Int {
        if asPlainText, let text = item.text ?? item.colorHex {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            markPestyAsSource(on: pasteboard)
            return pasteboard.changeCount
        }
        if item.type == .image {
            guard let img = imageOverride ?? ClipboardStore.shared.loadImage(for: item) else {
                return pasteboard.changeCount
            }
            pasteboard.clearContents()
            pasteboard.writeObjects([img])
            markPestyAsSource(on: pasteboard)
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
        markPestyAsSource(on: pasteboard)
        return pasteboard.changeCount
    }

    private static func markPestyAsSource(on pasteboard: NSPasteboard) {
        // Use Pesty's packaged identifier rather than the host process identifier,
        // which is absent when running from SwiftPM and would not resolve an icon.
        pasteboard.setString(sourceBundleID, forType: sourceType)
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
        // A Paste Stack shortcut normally includes Command and Option. Wait for
        // those physical keys to be released before sending our own Command-V;
        // otherwise macOS can interpret it as the still-held sequence shortcut
        // and the queue advances without text ever reaching the target.
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

        // Give AppKit one more turn through the run loop after activation.
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
