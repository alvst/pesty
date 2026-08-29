import AppKit
import Carbon.HIToolbox

/// How a clip's content is written to the pasteboard when pasting.
enum PasteFormat {
    /// The clip exactly as captured.
    case original
    /// Text only, all formatting removed.
    case plainText
    /// Bold, italic, underline, and links survive; fonts, sizes, and colors
    /// are normalized away.
    case cleanFormatting
    /// Rich content converted to Markdown text.
    case markdown
}

@MainActor
enum PasteService {
    /// Shared pasteboard marker understood by clipboard managers. It identifies the
    /// application which placed the current content on the pasteboard, even though
    /// Pesty is not the foreground app by the time another manager observes it.
    private static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")
    private static var sourceBundleID: String {
        Bundle.main.bundleIdentifier ?? AppIdentity.bundleIdentifier
    }

    /// Copies several clips as one payload: their text joined by newlines,
    /// which is the only representation a mixed selection can share. A single
    /// clip still routes through `copy(_:)` so it keeps its rich text, image,
    /// or file representations intact.
    @discardableResult
    static func copy(_ items: [ClipItem], to pasteboard: NSPasteboard = .general) -> Int {
        guard items.count > 1 else {
            guard let item = items.first else { return pasteboard.changeCount }
            return copy(item, to: pasteboard)
        }
        let text = items.compactMap(\.plainText).joined(separator: "\n")
        guard !text.isEmpty else { return pasteboard.changeCount }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        markPestyAsSource(on: pasteboard)
        return pasteboard.changeCount
    }

    @discardableResult
    static func copy(_ item: ClipItem,
                     to pasteboard: NSPasteboard = .general,
                     format: PasteFormat = .original,
                     imageOverride: NSImage? = nil) -> Int {
        switch format {
        case .plainText:
            if let text = item.plainText {
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                markPestyAsSource(on: pasteboard)
                return pasteboard.changeCount
            }
        case .cleanFormatting:
            if let rtf = FormatConverter.cleanedRTF(for: item) {
                pasteboard.clearContents()
                pasteboard.setData(rtf, forType: .rtf)
                if let text = item.plainText { pasteboard.setString(text, forType: .string) }
                markPestyAsSource(on: pasteboard)
                return pasteboard.changeCount
            }
            // No rich source to clean: plain text is the honest result.
            if let text = item.plainText {
                return copy(item, to: pasteboard, format: .plainText, imageOverride: imageOverride)
            }
        case .markdown:
            if let markdown = FormatConverter.markdown(for: item) {
                pasteboard.clearContents()
                pasteboard.setString(markdown, forType: .string)
                markPestyAsSource(on: pasteboard)
                return pasteboard.changeCount
            }
            if let text = item.plainText {
                return copy(item, to: pasteboard, format: .plainText, imageOverride: imageOverride)
            }
        case .original:
            break
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
        // Use Pesty-Alvie's packaged identifier rather than the host process identifier,
        // which is absent when running from SwiftPM and would not resolve an icon.
        pasteboard.setString(sourceBundleID, forType: sourceType)
    }

    static func paste(_ item: ClipItem,
                      into targetApp: NSRunningApplication?,
                      monitor: ClipboardMonitor,
                      format: PasteFormat = .original,
                      imageOverride: NSImage? = nil) {
        // Whatever is on the pasteboard right now is about to be replaced;
        // make sure history has it before it goes.
        monitor.pollNow()
        let change = copy(item, format: format, imageOverride: imageOverride)
        monitor.suppressUntilChangeCount = change
        if Settings.shared.playSound { FeedbackSound.play(FeedbackSound.paste) }

        guard let target = targetApp, !target.isTerminated else { return }

        #if MAS
        // Mac App Store (sandboxed) build: copy the clip and return focus to the
        // app the user came from so they can paste with ⌘V. No Accessibility
        // APIs and no synthetic keystrokes are used.
        target.activate()
        #else
        // Direct-download build: optionally paste straight into the active app by
        // synthesizing ⌘V. This requires the user's Accessibility grant.
        guard Settings.shared.pasteDirectly else { return }
        guard AXIsProcessTrusted() else {
            // Silently doing nothing here reads as "paste is broken" — every
            // rebuild invalidates the TCC grant, so this is a common state.
            AppController.shared.reportMissingAccessibilityForDirectPaste()
            return
        }
        beginDirectPaste(into: target)
        #endif
    }

    #if !MAS
    private static func beginDirectPaste(into target: NSRunningApplication) {
        guard !target.isTerminated else { return }
        if target.isActive {
            waitForPasteTriggerToRelease(for: target)
            return
        }

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
