import AppKit
import Carbon.HIToolbox

@MainActor
enum PasteService {

    struct CopyResult: Equatable {
        let changeCount: Int
        let didWriteContent: Bool
    }

    @discardableResult
    static func copy(_ item: ClipItem,
                     to pasteboard: NSPasteboard = .general,
                     asPlainText: Bool = false,
                     imageOverride: NSImage? = nil) -> CopyResult {
        if asPlainText {
            guard let text = item.plainText else { return noCopyResult(on: pasteboard) }
            return replaceContents(on: pasteboard) {
                pasteboard.setString(text, forType: .string)
            }
        }

        switch item.type {
        case .image:
            guard let img = imageOverride ?? ClipboardStore.shared.loadImage(for: item) else {
                return noCopyResult(on: pasteboard)
            }
            return replaceContents(on: pasteboard) {
                pasteboard.writeObjects([img])
            }
        case .file:
            let urls = item.fileURLs.compactMap { URL(string: $0) }
            guard !urls.isEmpty || item.text != nil else { return noCopyResult(on: pasteboard) }
            return replaceContents(on: pasteboard) {
                let wroteURLs = !urls.isEmpty && pasteboard.writeObjects(urls as [NSURL])
                let wroteText = item.text.map { pasteboard.setString($0, forType: .string) } ?? false
                return wroteURLs || wroteText
            }
        case .color:
            guard let hex = item.colorHex, let color = NSColor(hex: hex) else {
                return noCopyResult(on: pasteboard)
            }
            return replaceContents(on: pasteboard) {
                let wroteColor = pasteboard.writeObjects([color])
                let wroteText = pasteboard.setString(hex, forType: .string)
                return wroteColor || wroteText
            }
        case .richText:
            guard item.rtfData != nil || item.text != nil else { return noCopyResult(on: pasteboard) }
            return replaceContents(on: pasteboard) {
                let wroteRTF = item.rtfData.map { pasteboard.setData($0, forType: .rtf) } ?? false
                let wroteText = item.text.map { pasteboard.setString($0, forType: .string) } ?? false
                return wroteRTF || wroteText
            }
        case .text, .link:
            guard let text = item.text else { return noCopyResult(on: pasteboard) }
            return replaceContents(on: pasteboard) {
                pasteboard.setString(text, forType: .string)
            }
        }
    }

    private static func noCopyResult(on pasteboard: NSPasteboard) -> CopyResult {
        CopyResult(changeCount: pasteboard.changeCount, didWriteContent: false)
    }

    /// Replacing an item can update the pasteboard change count several times.
    /// Write Pesty's source marker last so observers see the completed content
    /// and can identify it as an intentional Pesty-originated update.
    private static func replaceContents(on pasteboard: NSPasteboard,
                                        writeContent: () -> Bool) -> CopyResult {
        pasteboard.clearContents()
        guard writeContent() else { return noCopyResult(on: pasteboard) }
        PasteboardSourceMarker.markPestyAsSource(on: pasteboard)
        return CopyResult(changeCount: pasteboard.changeCount, didWriteContent: true)
    }

    static func paste(_ item: ClipItem,
                      into targetApp: NSRunningApplication?,
                      monitor: ClipboardMonitor,
                      asPlainText: Bool = false,
                      imageOverride: NSImage? = nil) {
        let copyResult = copy(item, asPlainText: asPlainText, imageOverride: imageOverride)
        guard copyResult.didWriteContent else { return }
        monitor.suppressUntilChangeCount = copyResult.changeCount
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

/// `org.nspasteboard.source` is a lightweight provenance marker used by
/// clipboard managers. It contains only a bundle identifier, never clipboard
/// content, so it is safe to carry alongside every representation Pesty writes.
enum PasteboardSourceMarker {
    static let pasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.source")
    static let pestyBundleIdentifier = "com.greycorelabs.pesty"

    static func markPestyAsSource(on pasteboard: NSPasteboard) {
        pasteboard.setString(pestyBundleIdentifier, forType: pasteboardType)
    }

    static func identifier(on pasteboard: NSPasteboard) -> String? {
        let identifier = pasteboard.string(forType: pasteboardType)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return identifier?.isEmpty == false ? identifier : nil
    }

    static func isPestyOrigin(_ identifier: String?) -> Bool {
        identifier == pestyBundleIdentifier
    }
}
