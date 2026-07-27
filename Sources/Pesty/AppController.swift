import AppKit
import SwiftUI
import Carbon.HIToolbox

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    static let shared = AppController()

    let store = ClipboardStore.shared
    let monitor = ClipboardMonitor()
    let pasteSequence = PasteSequence.shared

    private var barController: BarWindowController?
    private var statusItem: NSStatusItem?
    private var pauseMenuItem: NSMenuItem?
    private var settingsWindow: NSWindow?
    private var pasteStackController: PasteStackWindowController?
    private var previewWindow: NSWindow?
    private var inlinePreviewController: InlinePreviewWindowController?
    private var previewedItemID: UUID?
    private var keyMonitor: Any?
    private var isReopenPresentationPending = false

    private(set) var previousApp: NSRunningApplication?
    private(set) var lastActiveApp: NSRunningApplication?
    private var pasteStackTargetApp: NSRunningApplication?

    var suppressAutoHide = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        monitor.start()

        HotKeyCenter.shared.onTrigger = { [weak self] in self?.toggleBar() }
        HotKeyCenter.shared.onSequenceTrigger = { [weak self] in self?.pasteNextInSequence() }
        HotKeyCenter.shared.start()

        setMenuBarIconVisible(Settings.shared.showMenuBarIcon)

        if Settings.shared.launchAtLogin { LaunchAtLogin.set(enabled: true) }

        if CommandLine.arguments.contains("--demo") {
            store.seedDemo()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showBar()
            }
            return
        }

        if !Settings.shared.onboarded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showSettings()
            }
            Settings.shared.onboarded = true
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        // Finder, Spotlight, and the Dock send a reopen event when the user
        // invokes an app that is already running. The clipboard bar is an
        // NSPanel, so AppKit's `hasVisibleWindows` value does not reliably
        // describe whether Pesty already has a surface on screen.
        guard !hasVisiblePestySurface else { return true }
        guard !isReopenPresentationPending else { return false }

        isReopenPresentationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isReopenPresentationPending = false

            // A window can appear while AppKit finishes the reopen event
            // (for example, during onboarding). Avoid presenting a second
            // Pesty surface in that case.
            guard !self.hasVisiblePestySurface else { return }
            self.showBar()
        }
        return false
    }

    private var hasVisiblePestySurface: Bool {
        NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized }
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastActiveApp = app
            // Command-Tab and app switching do not reliably make our borderless
            // panel resign key. Treat activation of another app as an explicit
            // dismissal so the bar never stays above the newly active app.
            if barController?.window?.isVisible == true {
                hideBar()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    private func setupStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItemIcon(item)
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Pesty   \(Settings.shared.hotkeyDisplay)",
                     action: #selector(menuOpen), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",").target = self
        let pause = menu.addItem(withTitle: "Pause Pesty", action: #selector(menuTogglePause), keyEquivalent: "")
        pause.target = self
        pauseMenuItem = pause
        menu.addItem(withTitle: "Clear History", action: #selector(menuClear), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let about = menu.addItem(withTitle: "About Pesty", action: #selector(menuAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(withTitle: "Quit Pesty", action: #selector(menuQuit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    func setMenuBarIconVisible(_ visible: Bool) {
        if visible {
            setupStatusItem()
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func menuOpen() { showBar() }
    @objc private func menuSettings() { showSettings() }
    @objc private func menuClear() { store.clearHistory() }
    @objc private func menuTogglePause() { togglePestyPause() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
    @objc private func menuAbout() { showAbout() }

    func togglePestyPause() {
        monitor.togglePause()
        pauseMenuItem?.title = monitor.isPaused ? "Resume Pesty" : "Pause Pesty"
        if let item = statusItem { updateStatusItemIcon(item) }
    }

    private func updateStatusItemIcon(_ item: NSStatusItem) {
        item.button?.image = NSImage(
            systemSymbolName: monitor.isPaused ? "pause.circle" : "doc.on.clipboard",
            accessibilityDescription: "Pesty")
        item.button?.image?.isTemplate = true
    }

    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Pesty",
            .applicationVersion: Bundle.main.appVersion,
            .credits: NSAttributedString(
                string: "A free, open-source clipboard manager for macOS.\nInspired by Paste.",
                attributes: [.font: NSFont.systemFont(ofSize: 11)])
        ])
    }

    func toggleICloudSync() {
        let enabling = !Settings.shared.iCloudSync
        if enabling && !ClipboardStore.shared.iCloudAvailable {
            let alert = NSAlert()
            alert.messageText = "iCloud Drive Unavailable"
            alert.informativeText = "Sign in to iCloud and enable iCloud Drive in System Settings to sync your clipboard across your Macs."
            alert.runModal()
            return
        }
        Settings.shared.iCloudSync = enabling
        ClipboardStore.shared.setICloudSync(enabling)
    }

    static func restart() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    func toggleBar() {
        if let bar = barController, bar.window?.isVisible == true {
            hideBar()
        } else {
            showBar()
        }
    }

    func showBar(source requestedSource: BarSource? = nil) {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, !isPesty(front) {
            previousApp = front
            lastActiveApp = front
        } else if let lastActiveApp, !lastActiveApp.isTerminated {
            // Reopen events arrive after Pesty becomes active, so retain the
            // most recently active non-Pesty app as the eventual paste target.
            previousApp = lastActiveApp
        }
        store.searchText = ""
        store.source = requestedSource ?? .history
        store.applyHistoryPolicy()
        if store.source != .pasteStack { store.selectFirst() }
        store.inlinePreviewVisible = false
        inlinePreviewController?.hide()

        if barController == nil {
            barController = BarWindowController()
        }
        barController?.show()
        store.noteBarPresented()
        startKeyMonitor()
    }

    func hideBar(immediately: Bool = false) {
        stopKeyMonitor()
        store.inlinePreviewVisible = false
        inlinePreviewController?.hide()
        barController?.hide(immediately: immediately)
    }

    func toggleInlinePreview() {
        guard Settings.shared.clipPreviewStyle == .inlinePesty,
              store.source != .pasteStack,
              store.selectedItem != nil else { return }
        if store.inlinePreviewVisible {
            hideInlinePreview()
        } else {
            store.inlinePreviewVisible = true
        }
    }

    func hideInlinePreview() {
        store.inlinePreviewVisible = false
        inlinePreviewController?.hide()
    }

    func updateInlinePreview(item: ClipItem, cardFrame: CGRect) {
        guard store.inlinePreviewVisible,
              let barWindow = barController?.window,
              barWindow.isVisible else { return }
        if inlinePreviewController == nil {
            inlinePreviewController = InlinePreviewWindowController()
        }
        inlinePreviewController?.show(item: item, anchoredTo: cardFrame, in: barWindow)
    }

    func resizeVisibleBar(to height: Double) {
        barController?.resize(to: CGFloat(height))
    }

    func pasteSelected(asPlainText: Bool = false) {
        guard let item = store.selectedItem else { return }
        pasteItem(item, asPlainText: asPlainText)
    }

    /// The app that will receive a paste after the floating Pesty panel closes.
    /// `previousApp` is captured before the panel activates, while
    /// `lastActiveApp` covers menu-bar and reopen paths where it is unavailable.
    private var pasteTarget: NSRunningApplication? {
        [lastActiveApp, previousApp, NSWorkspace.shared.frontmostApplication]
            .compactMap { $0 }
            .first { !$0.isTerminated && !isPesty($0) }
    }

    var pasteMenuTitle: String {
        guard let name = pasteTarget?.localizedName,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Paste"
        }
        return "Paste to \(name)"
    }

    func pasteItem(_ item: ClipItem, asPlainText: Bool = false) {
        let target = pasteTarget
        // Return must not leave the non-activating panel key while the
        // synthetic Command-V is handed back to the previous app. Dismiss it
        // before requesting target activation; Escape/click dismissal keeps
        // the normal slide-out animation.
        hideBar(immediately: true)
        PasteService.paste(item, into: target, monitor: monitor, asPlainText: asPlainText)
    }

    func copyItem(_ item: ClipItem) {
        let change = PasteService.copy(item)
        monitor.suppressUntilChangeCount = change
        hideBar()
    }

    func beginPasteSequence() {
        pasteStackTargetApp = previousApp ?? lastActiveApp
        pasteSequence.begin()
        showPasteStack()
        hideBar()

        let target = pasteStackTargetApp
        DispatchQueue.main.async {
            target?.activate(options: [])
        }
    }

    func showPasteStack() {
        if pasteStackController == nil {
            pasteStackController = PasteStackWindowController()
        }
        pasteStackController?.show()
    }

    func hidePasteStack() {
        pasteStackController?.hide()
    }

    func showPasteStackTab(stackID: UUID? = nil) {
        store.searchText = ""
        store.source = .pasteStack
        if let stackID {
            pasteSequence.selectStack(stackID)
        } else {
            pasteSequence.selectFirst()
        }
        pasteStackController?.hide()
        if barController?.window?.isVisible != true {
            showBar(source: .pasteStack)
        }
    }

    func cancelPasteSequence() {
        pasteSequence.cancel()
        pasteStackController?.hide()
        pasteStackTargetApp = nil
    }

    func newPasteStack() {
        pasteStackTargetApp = previousApp ?? lastActiveApp
        pasteSequence.newStack()
        showPasteStack()
        hideBar()

        let target = pasteStackTargetApp
        DispatchQueue.main.async {
            target?.activate(options: [])
        }
    }

    func pausePasteSequence() {
        pasteSequence.pause()
    }

    func clearPasteStack() {
        cancelPasteSequence()
    }

    func capturePasteStackItem(_ item: ClipItem) {
        _ = pasteSequence.addIfNeeded(item)
    }

    /// Adds a Clipboard-history clip to the current Paste Stack. Once moved,
    /// the clip is represented by the stack deck instead of a duplicate card
    /// in the unfiltered Clipboard strip.
    func moveHistoryItemToPasteStack(_ item: ClipItem) {
        guard pasteSequence.addHistoryItem(item) else { return }

        if store.source == .history,
           store.searchText.isEmpty,
           store.selectedID == item.id {
            store.selectFirst()
        }
    }

    func removePasteStackEntry(_ entry: PasteStackEntry) {
        pasteSequence.remove(entry)
    }

    func reAddPasteStackEntry(_ entry: PasteStackEntry) {
        pasteSequence.reAdd(entry)
    }

    func resetPasteStackProgress() {
        pasteSequence.resetProgress()
    }

    /// Saves the deck in its displayed paste order so a temporary Paste Stack
    /// can become a durable Pinboard.
    func savePasteStack() {
        guard pasteSequence.hasEntries,
              let name = TextPrompt.run(title: "Save Paste Stack",
                                        message: "Save the current stack as a pinboard named:",
                                        defaultValue: "Paste Stack") else { return }

        let board = store.addPinboard(name: name)
        for entry in pasteSequence.displayEntries.reversed() {
            store.saveToPinboard(entry.item, boardID: board.id)
        }
    }

    func pasteNextInSequence() {
        #if !MAS
        guard !Settings.shared.pasteDirectly || PasteService.ensureAccessibility(prompt: true) else { return }
        #endif

        guard let entry = pasteSequence.next() else { return }
        performPasteStackEntry(entry)
    }

    func pasteStackEntry(_ entry: PasteStackEntry) {
        guard let entry = pasteSequence.next(entryID: entry.id) else { return }
        performPasteStackEntry(entry)
    }

    func pasteSelectedStackEntry() {
        guard let entry = pasteSequence.selectedEntry else { return }
        pasteStackEntry(entry)
    }

    private func performPasteStackEntry(_ entry: PasteStackEntry) {
        let target = pasteTargetApp()
        hideBar(immediately: true)
        PasteService.paste(entry.item,
                           into: target,
                           monitor: monitor,
                           imageOverride: entry.imagePreview)
    }

    /// Resolve the destination when the user chooses to paste, rather than
    /// holding the app that was active when the Stack was first opened.
    private func pasteTargetApp() -> NSRunningApplication? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           !isPesty(frontmost) {
            previousApp = frontmost
            return frontmost
        }
        if let lastActiveApp,
           !isPesty(lastActiveApp),
           !lastActiveApp.isTerminated {
            return lastActiveApp
        }
        return pasteStackTargetApp ?? previousApp
    }

    func editItem(_ item: ClipItem, launchWritingTools: Bool = false) {
        suppressAutoHide = true
        // The bar's local monitor normally consumes typeable keys for search
        // and navigation. Suspend it while the native editor owns first
        // responder so typing, Delete, Return, and Writing Tools all reach
        // the NSTextView instead.
        let resumeBarKeys = barController?.window?.isVisible == true
        if resumeBarKeys { stopKeyMonitor() }
        defer {
            suppressAutoHide = false
            if resumeBarKeys { startKeyMonitor() }
        }

        guard let edit = ClipEditor.run(for: item, launchWritingTools: launchWritingTools) else { return }

        let changed: Bool
        switch edit {
        case let .text(text, richTextData):
            changed = store.updateTextContent(text, richTextData: richTextData, for: item)
        case let .color(hex):
            changed = store.updateColorContent(hex, for: item)
        }
        guard changed, let updatedItem = store.item(withID: item.id) else { return }

        // The edited content becomes the live clipboard as well. Suppress the
        // monitor so this is an in-place change rather than a duplicate entry.
        let change = PasteService.copy(updatedItem)
        monitor.suppressUntilChangeCount = change

        if previewedItemID == item.id { showPreview(for: updatedItem) }
    }

    func showPreview(for item: ClipItem) {
        let host = NSHostingController(rootView: ClipPreviewView(item: item))
        let title = "Preview — \(item.displayTitle)"
        previewedItemID = item.id

        if let window = previewWindow {
            window.title = title
            window.contentViewController = host
            window.makeKeyAndOrderFront(nil)
            return
        }

        let previewWindow = NSWindow(contentViewController: host)
        previewWindow.title = title
        previewWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        previewWindow.setContentSize(NSSize(width: 540, height: 400))
        previewWindow.minSize = NSSize(width: 400, height: 260)
        previewWindow.isReleasedWhenClosed = false
        previewWindow.center()
        self.previewWindow = previewWindow
        previewWindow.makeKeyAndOrderFront(nil)
    }

    func showSharePicker(for item: ClipItem) {
        let items = shareItems(for: item)
        guard !items.isEmpty,
              let view = barController?.window?.contentView ?? NSApp.keyWindow?.contentView else { return }

        let picker = NSSharingServicePicker(items: items)
        let anchor = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
    }

    private func shareItems(for item: ClipItem) -> [Any] {
        switch item.type {
        case .image:
            return store.loadImage(for: item).map { [$0] } ?? []
        case .file:
            let urls = item.fileURLs.compactMap(URL.init(string:))
            return urls.isEmpty ? item.plainText.map { [$0 as NSString] } ?? [] : urls
        case .color, .text, .richText, .link:
            return item.plainText.map { [$0 as NSString] } ?? []
        }
    }

    private func isPesty(_ app: NSRunningApplication) -> Bool {
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return true }
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return app.bundleIdentifier == bundleID
    }

    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView()
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "Pesty Settings"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 760, height: 680))
        win.center()
        win.isReleasedWhenClosed = false
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
    }

    /// Handles commands that only apply while the Paste Bar owns keyboard focus.
    /// The panel's key-equivalent path calls this before SwiftUI receives command keys.
    func handleBarCommandShortcut(_ event: NSEvent) -> Bool {
        guard barController?.window?.isKeyWindow == true else { return false }

        let flags = event.modifierFlags
        guard flags.contains(.command), flags.contains(.shift),
              !flags.contains(.control), !flags.contains(.option) else { return false }

        switch Int(event.keyCode) {
        case kVK_ANSI_S:
            showSettings()
            return true
        case kVK_ANSI_P:
            togglePestyPause()
            return true
        default:
            return false
        }
    }

    private func startKeyMonitor() {
        stopKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
    }

    private func stopKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        // Events belonging to a native context menu, editor, or Settings
        // window must stay with their own responder chain. The bar monitor is
        // only responsible for keys delivered to the Paste Bar panel itself.
        guard event.window === barController?.window else { return event }
        if handleBarCommandShortcut(event) { return nil }

        let code = Int(event.keyCode)
        let flags = event.modifierFlags
        let cmd = flags.contains(.command)
        let ctrl = flags.contains(.control)
        let opt = flags.contains(.option)

        if store.source != .pasteStack,
           includes(Settings.shared.quickPasteModifier, in: flags),
           let chars = event.charactersIgnoringModifiers,
           let n = Int(chars),
           (1...9).contains(n) {
            let items = store.visibleItems
            if n <= items.count {
                pasteItem(items[n - 1], asPlainText: includes(Settings.shared.plainTextModifier, in: flags))
            }
            return nil
        }

        switch code {
        case kVK_Space where store.searchText.isEmpty:
            if Settings.shared.clipPreviewStyle == .nativeQuickLook {
                QuickLookService.shared.toggle(items: store.visibleItems, selectedID: store.selectedID)
            } else {
                toggleInlinePreview()
            }
            return nil
        case kVK_Escape:
            if !store.searchText.isEmpty { store.searchText = ""; store.selectFirst() }
            else { hideBar() }
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if store.source == .pasteStack {
                pasteSelectedStackEntry()
                return nil
            }
            pasteSelected(); return nil
        case kVK_LeftArrow, kVK_UpArrow:
            if store.source == .pasteStack {
                pasteSequence.moveSelection(by: -1)
                return nil
            }
            moveBarSelection(by: -1); return nil
        case kVK_RightArrow, kVK_DownArrow:
            if store.source == .pasteStack {
                pasteSequence.moveSelection(by: 1)
                return nil
            }
            moveBarSelection(by: 1); return nil
        case kVK_Delete:
            if store.source == .pasteStack, let entry = pasteSequence.selectedEntry {
                removePasteStackEntry(entry)
                return nil
            }
            if cmd { store.deleteSelected(); return nil }
            if !store.searchText.isEmpty {
                store.searchText.removeLast(); store.selectFirst(); return nil
            }
            return nil
        case kVK_ForwardDelete:
            if store.source == .pasteStack, let entry = pasteSequence.selectedEntry {
                removePasteStackEntry(entry)
                return nil
            }
            store.deleteSelected()
            return nil
        default:
            break
        }

        if store.source != .pasteStack,
           !cmd && !ctrl && !opt,
           let chars = event.characters, chars.count == 1,
           let scalar = chars.unicodeScalars.first,
           scalar.value >= 32, scalar.value != 127 {
            store.searchText.append(chars)
            store.selectFirst()
            return nil
        }
        return event
    }

    private func moveBarSelection(by delta: Int) {
        store.moveSelection(by: delta)
        QuickLookService.shared.updateSelection(selectedID: store.selectedID)
    }

    private func includes(_ carbonModifier: Int, in flags: NSEvent.ModifierFlags) -> Bool {
        switch carbonModifier {
        case cmdKey: return flags.contains(.command)
        case optionKey: return flags.contains(.option)
        case controlKey: return flags.contains(.control)
        case shiftKey: return flags.contains(.shift)
        default: return false
        }
    }
}

extension Bundle {
    var appVersion: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
