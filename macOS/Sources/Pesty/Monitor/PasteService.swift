import AppKit
import Carbon.HIToolbox

/// The standard pasteboard source marker is untrusted input. Keep only a
/// plausible bundle identifier before using it for a clip's icon,
/// exclusion rule, or outgoing attribution.
@MainActor
enum SourceAttribution {
    static func validBundleID(_ value: String?) -> String? {
        ClipItem.validatedSourceBundleID(value)
    }

    static func resolvedMarker(_ value: String?) -> (bundleID: String, name: String?)? {
        guard let bundleID = validBundleID(value) else { return nil }
        if bundleID == AppIdentity.bundleIdentifier {
            return (bundleID, AppIdentity.displayName)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url),
              bundle.bundleIdentifier == bundleID else { return (bundleID, nil) }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        return (bundleID, name)
    }
}

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
        let sources = items.map { SourceAttribution.validBundleID($0.sourceBundleID) }
        let firstSource = sources.first ?? nil
        let commonSource = firstSource != nil && sources.allSatisfy({ $0 == firstSource })
            ? firstSource : nil
        markSource(commonSource, on: pasteboard)
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
                markSource(item.sourceBundleID, on: pasteboard)
                return pasteboard.changeCount
            }
        case .cleanFormatting:
            if let rtf = FormatConverter.cleanedRTF(for: item) {
                pasteboard.clearContents()
                pasteboard.setData(rtf, forType: .rtf)
                if let text = item.plainText { pasteboard.setString(text, forType: .string) }
                markSource(item.sourceBundleID, on: pasteboard)
                return pasteboard.changeCount
            }
            // No rich source to clean: plain text is the honest result.
            if item.plainText != nil {
                return copy(item, to: pasteboard, format: .plainText, imageOverride: imageOverride)
            }
        case .markdown:
            if let markdown = FormatConverter.markdown(for: item) {
                pasteboard.clearContents()
                pasteboard.setString(markdown, forType: .string)
                markSource(item.sourceBundleID, on: pasteboard)
                return pasteboard.changeCount
            }
            if item.plainText != nil {
                return copy(item, to: pasteboard, format: .plainText, imageOverride: imageOverride)
            }
        case .original:
            break
        }
        if item.type == .image {
            let png = imageOverride == nil ? storedPNG(for: item) : nil
            guard png != nil || imageOverride != nil
                    || ClipboardStore.shared.loadImage(for: item) != nil else {
                return pasteboard.changeCount
            }
            pasteboard.clearContents()
            if let png {
                pasteboard.setData(png, forType: .png)
            } else if let image = imageOverride ?? ClipboardStore.shared.loadImage(for: item) {
                pasteboard.writeObjects([image])
            }
            markSource(item.sourceBundleID, on: pasteboard)
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
        // Preserve an image attached to a text/rich-text clip as another
        // pasteboard representation, so apps that accept both can receive it.
        if item.type != .image {
            if let imageOverride {
                pasteboard.writeObjects([imageOverride])
            } else if let png = storedPNG(for: item) {
                pasteboard.setData(png, forType: .png)
            } else if let image = ClipboardStore.shared.loadImage(for: item) {
                pasteboard.writeObjects([image])
            }
        }
        markSource(item.sourceBundleID, on: pasteboard)
        return pasteboard.changeCount
    }

    private static func markSource(_ bundleID: String?, on pasteboard: NSPasteboard) {
        pasteboard.setString(SourceAttribution.validBundleID(bundleID)
                             ?? AppIdentity.bundleIdentifier, forType: sourceType)
    }

    /// The store already keeps captured pixels as PNG. Publishing those bytes
    /// avoids decoding the image and serializing it again as a large TIFF.
    private static func storedPNG(for item: ClipItem) -> Data? {
        guard let url = ClipboardStore.shared.imageURL(for: item),
              url.pathExtension.lowercased() == "png",
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else {
            return nil
        }
        return data
    }

    @discardableResult
    static func paste(_ item: ClipItem,
                      into targetApp: NSRunningApplication?,
                      monitor: ClipboardMonitor,
                      format: PasteFormat = .original,
                      imageOverride: NSImage? = nil,
                      onPaste: (() -> Void)? = nil) -> Bool {
        // A missing image must never leave the previous clipboard content in
        // place and then send ⌘V for that unrelated content.
        let image = imageOverride
        guard item.type != .image || image != nil
                || ClipboardStore.shared.imageURL(for: item).map({
                    FileManager.default.isReadableFile(atPath: $0.path)
                }) == true else { return false }
        // Whatever is on the pasteboard right now is about to be replaced;
        // make sure history has it before it goes.
        monitor.pollNow()
        #if !MAS
        if let target = targetApp, !target.isTerminated,
           Settings.shared.pasteDirectly, AXIsProcessTrusted() {
            directPasteQueue.append(DirectPasteRequest(
                item: item, target: target, monitor: monitor,
                format: format, image: image, onPaste: onPaste
            ))
            processNextDirectPaste()
            return true
        }
        #endif
        let before = NSPasteboard.general.changeCount
        let change = copy(item, format: format, imageOverride: image)
        guard change != before else { return false }
        monitor.suppressUntilChangeCount = change
        if Settings.shared.playSound { FeedbackSound.play(FeedbackSound.paste) }
        onPaste?()

        guard let target = targetApp, !target.isTerminated else { return true }

        #if MAS
        // Mac App Store (sandboxed) build: copy the clip and return focus to the
        // app the user came from so they can paste with ⌘V. No Accessibility
        // APIs and no synthetic keystrokes are used.
        AppController.shared.reportSandboxPasteRequiresManualPaste()
        target.activate()
        #else
        // Direct-download build: optionally paste straight into the active app by
        // synthesizing ⌘V. This requires the user's Accessibility grant.
        guard Settings.shared.pasteDirectly else { return true }
        guard AXIsProcessTrusted() else {
            // Silently doing nothing here reads as "paste is broken" — every
            // rebuild invalidates the TCC grant, so this is a common state.
            AppController.shared.reportMissingAccessibilityForDirectPaste()
            return true
        }
        #endif
        return true
    }

    #if !MAS
    private struct DirectPasteRequest {
        let item: ClipItem
        let target: NSRunningApplication
        let monitor: ClipboardMonitor
        let format: PasteFormat
        let image: NSImage?
        let onPaste: (() -> Void)?
    }

    private static var directPasteQueue: [DirectPasteRequest] = []
    private static var directPasteInFlight = false

    private static func processNextDirectPaste() {
        guard !directPasteInFlight, !directPasteQueue.isEmpty else { return }
        directPasteInFlight = true
        beginDirectPaste(directPasteQueue.removeFirst())
    }

    private static func finishDirectPaste() {
        directPasteInFlight = false
        processNextDirectPaste()
    }

    private static func beginDirectPaste(_ request: DirectPasteRequest) {
        let target = request.target
        guard !target.isTerminated else { finishDirectPaste(); return }
        if target.isActive {
            waitForPasteTriggerToRelease(request, attempts: 250)
            return
        }

        if NSApp.isActive {
            NSApp.yieldActivation(to: target)
            guard target.activate(from: .current, options: []) else {
                finishDirectPaste()
                return
            }
        } else {
            target.activate(options: [])
        }
        waitForTargetActivation(request, attempts: 30)
    }

    private static func waitForTargetActivation(_ request: DirectPasteRequest, attempts: Int) {
        let target = request.target
        guard !target.isTerminated else { finishDirectPaste(); return }
        if target.isActive {
            waitForPasteTriggerToRelease(request, attempts: 250)
            return
        }
        guard attempts > 0 else { finishDirectPaste(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            waitForTargetActivation(request, attempts: attempts - 1)
        }
    }

    private static func waitForPasteTriggerToRelease(_ request: DirectPasteRequest, attempts: Int) {
        let target = request.target
        guard !target.isTerminated else { finishDirectPaste(); return }
        guard attempts > 0 else { finishDirectPaste(); return }

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
                waitForPasteTriggerToRelease(request, attempts: attempts - 1)
            }
            return
        }

        DispatchQueue.main.async {
            guard !target.isTerminated, target.isActive else { finishDirectPaste(); return }
            request.monitor.pollNow()
            let before = NSPasteboard.general.changeCount
            let change = copy(request.item, format: request.format, imageOverride: request.image)
            guard change != before else { finishDirectPaste(); return }
            request.monitor.suppressUntilChangeCount = change
            if Settings.shared.playSound { FeedbackSound.play(FeedbackSound.paste) }
            guard sendCommandV(to: target.processIdentifier) else { finishDirectPaste(); return }
            request.onPaste?()
            // Let the target process this paste before replacing the
            // pasteboard with the next hotkey press's payload.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                finishDirectPaste()
            }
        }
    }

    @discardableResult
    private static func sendCommandV(to processIdentifier: pid_t) -> Bool {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(processIdentifier)
        up.postToPid(processIdentifier)
        return true
    }

    @discardableResult
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
    #endif
}
