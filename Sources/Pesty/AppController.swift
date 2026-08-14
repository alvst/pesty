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
    private var inlinePreviewController: InlinePreviewWindowController?
    private var previewWindow: NSWindow?
    private var previewedItemID: UUID?
    private var keyMonitor: Any?
    private var isReopenPresentationPending = false
    private var editorFocusRestore: EditorFocusRestore?
    private let copyToast = CopyToastController()

    private(set) var previousApp: NSRunningApplication?
    private(set) var lastActiveApp: NSRunningApplication?

    var suppressAutoHide = false

    /// The editor is an activating panel, while the Paste Bar deliberately is
    /// not. Retain the original app so closing the editor restores its input
    /// focus without dismissing the still-visible bar.
    private struct EditorFocusRestore {
        let processIdentifier: pid_t
        let restoreAutoHide: Bool
        let resumeBarKeys: Bool
    }

    var isRestoringEditorFocus: Bool { editorFocusRestore != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        monitor.start()

        HotKeyCenter.shared.onTrigger = { [weak self] in self?.handleGlobalShortcut() }
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

        // Pesty's only primary surface is the Paste Bar. Present it for a
        // normal application launch as well as for a subsequent app reopen.
        // The bar is non-activating, so this still preserves the front app's
        // selected input for a later paste.
        if !Settings.shared.onboarded { Settings.shared.onboarded = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.presentBarForApplicationOpen()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        // Finder, Spotlight, and an “Open Pesty-Alvie” shortcut send a reopen event
        // when this accessory app is already running. The bar may still be an
        // NSPanel while it animates below the screen, so do not use AppKit's
        // broad window-visibility signal to decide whether to show it.
        guard !isReopenPresentationPending else { return false }
        isReopenPresentationPending = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isReopenPresentationPending = false
            self.presentBarForApplicationOpen()
        }
        return false
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastActiveApp = app
            if editorFocusRestore?.processIdentifier == app.processIdentifier {
                finishEditorFocusRestore(after: 0.1)
                return
            }
            // Command-Tab and app switching do not reliably make our borderless
            // panel resign key. Treat activation of another app as an explicit
            // dismissal so the bar never stays above the newly active app.
            if barController?.window?.isVisible == true, !suppressAutoHide {
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
        menu.addItem(withTitle: "Open Pesty-Alvie   \(Settings.shared.hotkeyDisplay)",
                     action: #selector(menuOpen), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        let pause = menu.addItem(withTitle: "Pause Pesty-Alvie", action: #selector(menuTogglePause), keyEquivalent: "")
        pause.target = self
        pauseMenuItem = pause
        let clear = menu.addItem(withTitle: "Clear History", action: #selector(menuClear), keyEquivalent: "")
        clear.target = self
        clear.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.addItem(.separator())
        let about = menu.addItem(withTitle: "About Pesty-Alvie", action: #selector(menuAbout), keyEquivalent: "")
        about.target = self
        about.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        let quit = menu.addItem(withTitle: "Quit Pesty-Alvie", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        item.menu = menu
        statusItem = item
        updatePauseMenuItem()
    }

    func setMenuBarIconVisible(_ visible: Bool) {
        if visible {
            setupStatusItem()
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            pauseMenuItem = nil
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
        updatePauseMenuItem()
        if let item = statusItem { updateStatusItemIcon(item) }
    }

    private func updatePauseMenuItem() {
        let paused = monitor.isPaused
        pauseMenuItem?.title = paused ? "Resume Pesty-Alvie" : "Pause Pesty-Alvie"
        pauseMenuItem?.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
    }

    private func updateStatusItemIcon(_ item: NSStatusItem) {
        item.button?.image = NSImage(systemSymbolName: monitor.isPaused ? "pause.circle" : "doc.on.clipboard", accessibilityDescription: AppIdentity.displayName)
        item.button?.image?.isTemplate = true
    }

    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppIdentity.displayName,
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
        if let bar = barController, bar.isPresented {
            hideBar()
        } else {
            showBar()
        }
    }

    private func handleGlobalShortcut() {
        toggleBar()
    }

    /// Used by macOS application-open events rather than the toggle shortcut.
    /// Reopening Pesty must always surface a bar that is currently hidden or
    /// moving below the display; an already exposed bar simply stays frontmost.
    private func presentBarForApplicationOpen() {
        if let bar = barController, bar.isPresented {
            bar.bringToFront()
            startKeyMonitor()
        } else {
            showBar()
        }
    }

    /// Disabling Paste Stacks leaves saved data intact, but immediately removes
    /// it from active navigation and stops an in-progress collection.
    func updatePasteStackAvailability() {
        guard !Settings.shared.pasteStacksEnabled else { return }
        pasteSequence.finishCollecting()
        pasteStackController?.hide()
        guard store.source == .pasteStack else { return }
        QuickLookService.shared.dismiss()
        barController?.resignSearch()
        store.searchText = ""
        store.barInputMode = .cards
        store.source = .history
        store.selectFirst()
    }

    private func availableBarSource(_ source: BarSource) -> BarSource {
        guard !Settings.shared.pasteStacksEnabled else { return source }
        if case .pasteStack = source { return .history }
        return source
    }

    func showBar(source requestedSource: BarSource? = nil) {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
            lastActiveApp = front
        } else if let lastActiveApp, !lastActiveApp.isTerminated {
            // Reopen events arrive after Pesty becomes active. Retain the
            // last non-Pesty app so the bar can still paste back into it.
            previousApp = lastActiveApp
        }
        store.searchText = ""
        store.barInputMode = .cards
        store.source = availableBarSource(requestedSource ?? .history)
        store.applyHistoryPolicy()
        store.prepareForBarPresentation()
        store.inlinePreviewVisible = false
        inlinePreviewController?.hide()

        if barController == nil {
            barController = BarWindowController()
        }
        barController?.resignSearch()
        barController?.show()
        startKeyMonitor()
    }

    func hideBar(immediately: Bool = false) {
        stopKeyMonitor()
        barController?.resignSearch()
        store.barInputMode = .cards
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

    func pasteItem(_ item: ClipItem, asPlainText: Bool = false) {
        let target = pasteTargetApp()
        // Release the non-activating panel before sending the paste event to
        // the source app. Escape/click dismissal keeps its slide-out motion.
        hideBar(immediately: true)
        PasteService.paste(item, into: target, monitor: monitor, asPlainText: asPlainText)
    }

    func copyItem(_ item: ClipItem) {
        let previousChange = NSPasteboard.general.changeCount
        let change = PasteService.copy(item)
        monitor.suppressUntilChangeCount = change
        if change != previousChange {
            store.promoteCopiedItem(item)
        }
        hideBar()
        copyToast.show()
    }

    func copySelected() {
        guard let item = store.selectedItem else { return }
        copyItem(item)
    }

    func editItem(_ item: ClipItem, launchWritingTools: Bool = false) {
        // The Paste Bar's local monitor owns navigation and type-to-search.
        // Suspend it while the editor is first responder so typing and native
        // Writing Tools never get interpreted as bar commands.
        let focusTarget = pasteTargetApp()
        let resumeBarKeys = barController?.window?.isVisible == true
        let wasSuppressingAutoHide = suppressAutoHide
        suppressAutoHide = true
        if resumeBarKeys { stopKeyMonitor() }

        let edit = ClipEditor.run(for: item, launchWritingTools: launchWritingTools)
        guard let edit else {
            restoreFocusAfterEditing(to: focusTarget,
                                     restoreAutoHide: wasSuppressingAutoHide,
                                     resumeBarKeys: resumeBarKeys)
            return
        }

        let changed: Bool
        switch edit {
        case let .text(text, richTextData):
            changed = store.updateTextContent(text, richTextData: richTextData, for: item)
        case let .color(hex):
            changed = store.updateColorContent(hex, for: item)
        }
        guard changed, let updatedItem = store.item(withID: item.id) else {
            restoreFocusAfterEditing(to: focusTarget,
                                     restoreAutoHide: wasSuppressingAutoHide,
                                     resumeBarKeys: resumeBarKeys)
            return
        }

        // Keep the system clipboard in sync, without treating an in-place edit
        // as a new capture or reordering the item's history position.
        let change = PasteService.copy(updatedItem)
        monitor.suppressUntilChangeCount = change
        reconcilePasteStackSearchSelection()

        if previewedItemID == item.id, previewWindow?.isVisible == true {
            showPreview(for: updatedItem)
        }

        restoreFocusAfterEditing(to: focusTarget,
                                 restoreAutoHide: wasSuppressingAutoHide,
                                 resumeBarKeys: resumeBarKeys)
    }

    private func restoreFocusAfterEditing(to target: NSRunningApplication?,
                                          restoreAutoHide: Bool,
                                          resumeBarKeys: Bool) {
        guard let target,
              target.bundleIdentifier != Bundle.main.bundleIdentifier,
              !target.isTerminated else {
            completeEditorFocusRestore(restoreAutoHide: restoreAutoHide,
                                       resumeBarKeys: resumeBarKeys)
            return
        }

        editorFocusRestore = EditorFocusRestore(processIdentifier: target.processIdentifier,
                                                 restoreAutoHide: restoreAutoHide,
                                                 resumeBarKeys: resumeBarKeys)

        let didActivate: Bool
        if target.isActive {
            didActivate = true
        } else if NSApp.isActive {
            NSApp.yieldActivation(to: target)
            didActivate = target.activate(from: .current, options: [])
                || target.activate(options: [])
        } else {
            didActivate = target.activate(options: [])
        }

        guard didActivate else {
            editorFocusRestore = nil
            completeEditorFocusRestore(restoreAutoHide: restoreAutoHide,
                                       resumeBarKeys: resumeBarKeys)
            return
        }

        // App activation and the bar's resign-key notification can land on
        // adjacent run-loop turns. The matching workspace notification usually
        // completes this earlier; this is a fallback for coalesced events.
        finishEditorFocusRestore(after: 0.4)
    }

    private func finishEditorFocusRestore(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let restore = self.editorFocusRestore else { return }
            self.editorFocusRestore = nil
            self.completeEditorFocusRestore(restoreAutoHide: restore.restoreAutoHide,
                                            resumeBarKeys: restore.resumeBarKeys)
        }
    }

    private func completeEditorFocusRestore(restoreAutoHide: Bool,
                                            resumeBarKeys: Bool) {
        suppressAutoHide = restoreAutoHide
        if resumeBarKeys { startKeyMonitor() }
    }

    func showPreview(for item: ClipItem) {
        let host = NSHostingController(rootView: ClipPreviewWindowView(item: item))
        let title = "Preview — \(item.displayTitle)"
        previewedItemID = item.id

        if let window = previewWindow {
            window.title = title
            window.contentViewController = host
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 430))
        window.minSize = NSSize(width: 420, height: 280)
        window.isReleasedWhenClosed = false
        window.center()
        previewWindow = window
        window.makeKeyAndOrderFront(nil)
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

    func commandCopy() {
        if Settings.shared.pasteStacksEnabled,
           store.source == .pasteStack,
           let entry = selectedVisiblePasteStackEntry {
            copyItem(entry.item)
            return
        }
        copySelected()
    }

    func beginDragOut() {
        // Let AppKit establish the dragging session before taking the source
        // panel offscreen; the drag then continues naturally into another app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.hideBar()
        }
    }

    func beginPasteSequence() {
        guard Settings.shared.pasteStacksEnabled else { return }
        pasteSequence.begin()
        showPasteStack()
        hideBar()
        returnToPreviousAppForStackCapture()
    }

    func showPasteStack() {
        guard Settings.shared.pasteStacksEnabled else { return }
        if pasteStackController == nil {
            pasteStackController = PasteStackWindowController()
        }
        suppressAutoHide = true
        pasteStackController?.show()
        DispatchQueue.main.async { [weak self] in self?.suppressAutoHide = false }
    }

    func showPasteStackTab(stackID: UUID? = nil) {
        barController?.resignSearch()
        guard Settings.shared.pasteStacksEnabled else {
            store.searchText = ""
            store.barInputMode = .cards
            store.source = .history
            store.selectFirst()
            return
        }
        store.searchText = ""
        store.barInputMode = .cards
        store.source = .pasteStack
        if let stackID {
            pasteSequence.selectStack(stackID)
        } else {
            pasteSequence.selectFirst()
        }
        if barController?.window?.isVisible != true {
            showBar(source: .pasteStack)
        }
    }

    func selectPasteStack(_ id: UUID) {
        guard Settings.shared.pasteStacksEnabled else { return }
        pasteSequence.selectStack(id)
        reconcilePasteStackSearchSelection()
    }

    func setBarSearchEditing(_ editing: Bool) {
        let mode: BarInputMode = editing ? .search : .cards
        guard store.barInputMode != mode else { return }
        store.barInputMode = mode
    }

    func updateBarSearchText(_ text: String) {
        guard store.searchText != text else { return }
        store.searchText = text
        resetBarSelectionForSearch()
    }

    /// Return leaves the query intact and hands arrows/shortcuts back to the
    /// result cards. With no result there is nowhere to move, so search keeps
    /// focus instead.
    func submitBarSearch() {
        guard store.barInputMode == .search, hasVisibleSearchResult else { return }
        barController?.resignSearch()
        store.barInputMode = .cards
        resetBarSelectionForSearch()
    }

    func focusBarCards() {
        barController?.resignSearch()
        store.barInputMode = .cards
    }

    func clearBarSearch() {
        let hadQuery = !store.searchText.isEmpty
        barController?.resignSearch()
        store.searchText = ""
        store.barInputMode = .cards
        if hadQuery { resetBarSelectionForSearch() }
    }

    func cancelBarSearchOrHide() {
        if !store.searchText.isEmpty {
            clearBarSearch()
        } else {
            hideBar()
        }
    }

    func hidePasteStack() {
        pasteSequence.finishCollecting()
        pasteStackController?.hide()
    }

    var isPasteStackVisible: Bool {
        Settings.shared.pasteStacksEnabled && pasteStackController?.isVisible == true
    }

    func newPasteStack() {
        guard Settings.shared.pasteStacksEnabled else { return }
        pasteSequence.newStack()
        showPasteStack()
        hideBar()
        returnToPreviousAppForStackCapture()
    }

    func pausePasteSequence() {
        pasteSequence.pause()
    }

    func clearPasteStack() {
        pasteSequence.cancel()
        reconcilePasteStackSearchSelection()
    }

    func capturePasteStackItem(_ item: ClipItem) {
        guard Settings.shared.pasteStacksEnabled else { return }
        guard pasteSequence.addIfNeeded(item) else { return }
        // A collecting clip is represented by the stack deck on Clipboard, so
        // do not leave selection on its now-hidden history card.
        if store.source == .history, store.searchText.isEmpty, store.selectedID == item.id {
            store.selectFirst()
        }
        reconcilePasteStackSearchSelection()
    }

    func removePasteStackEntry(_ entry: PasteStackEntry) {
        pasteSequence.remove(entry)
        reconcilePasteStackSearchSelection()
    }

    func reAddPasteStackEntry(_ entry: PasteStackEntry) {
        pasteSequence.reAdd(entry)
        reconcilePasteStackSearchSelection()
    }

    func resetPasteStackProgress() {
        pasteSequence.resetProgress()
        reconcilePasteStackSearchSelection()
    }

    /// Saves the current queue as a Pinboard in its displayed paste order.
    /// Pinboards are persistent and already support the same rich clip types,
    /// so this gives a saved stack a durable, discoverable home.
    func savePasteStack() {
        guard Settings.shared.pasteStacksEnabled,
              pasteSequence.hasEntries,
              let name = TextPrompt.run(title: "Save Paste Stack",
                                        message: "Save the current stack as a pinboard named:",
                                        defaultValue: "Paste Stack") else { return }
        let board = store.addPinboard(name: name)
        for entry in pasteSequence.displayEntries.reversed() {
            store.saveToPinboard(entry.item, boardID: board.id)
        }
    }

    func startPasteSequence() {
        pasteNextInSequence()
    }

    func cancelPasteSequence() {
        pasteSequence.finishCollecting()
    }

    func pasteNextInSequence() {
        guard Settings.shared.pasteStacksEnabled,
              ensureStackCanPaste() else { return }
        guard let entry = pasteSequence.next() else { return }
        reconcilePasteStackSearchSelection()
        performPasteStackEntry(entry)
    }

    func pasteStackEntry(_ entry: PasteStackEntry, asPlainText: Bool = false) {
        guard Settings.shared.pasteStacksEnabled,
              ensureStackCanPaste() else { return }
        guard let entry = pasteSequence.next(entryID: entry.id) else { return }
        reconcilePasteStackSearchSelection()
        performPasteStackEntry(entry, asPlainText: asPlainText)
    }

    func pasteSelectedStackEntry() {
        guard Settings.shared.pasteStacksEnabled,
              let entry = selectedVisiblePasteStackEntry else { return }
        pasteStackEntry(entry)
    }

    private func performPasteStackEntry(_ entry: PasteStackEntry, asPlainText: Bool = false) {
        // A global Paste Stack shortcut can fire while Pesty's floating
        // collector is key. Resolve the real foreground/last-used app at the
        // moment of the shortcut instead of relying on the app that first
        // opened the bar.
        let target = pasteTargetApp()
        hideBar(immediately: true)
        PasteService.paste(entry.item,
                           into: target,
                           monitor: monitor,
                           asPlainText: asPlainText,
                           imageOverride: entry.imagePreview)
    }

    private func pasteTargetApp() -> NSRunningApplication? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = frontmost
            return frontmost
        }
        if let lastActiveApp,
           lastActiveApp.bundleIdentifier != Bundle.main.bundleIdentifier,
           !lastActiveApp.isTerminated {
            return lastActiveApp
        }
        return previousApp
    }

    var pasteMenuTitle: String {
        guard let name = pasteTargetApp()?.localizedName,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Paste"
        }
        return "Paste to \(name)"
    }

    private func ensureStackCanPaste() -> Bool {
        #if MAS
        return true
        #else
        // Do not advance the queue when direct pasting is enabled but macOS has
        // not granted Accessibility yet. Prompting here makes the shortcut's
        // first use self-explanatory instead of silently copying only.
        guard Settings.shared.pasteDirectly else { return true }
        return PasteService.ensureAccessibility(prompt: true)
        #endif
    }

    private func returnToPreviousAppForStackCapture() {
        // Capture happens in the app where the user is working, not in Pesty.
        let target = previousApp ?? lastActiveApp
        DispatchQueue.main.async {
            target?.activate(options: [])
        }
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
        win.title = "Pesty-Alvie Settings"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 760, height: 680))
        win.center()
        win.isReleasedWhenClosed = false
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
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
        // Native context menus, the clip editor, previews, and Settings own
        // their responder chains. The Paste Bar monitor only handles keys that
        // actually arrive at its floating panel.
        guard event.window === barController?.window else { return event }

        let code = Int(event.keyCode)
        let flags = event.modifierFlags
        let cmd = flags.contains(.command)

        // The native search field owns the entire event while it is editing.
        // This includes arrows, selections, clipboard commands, deletion,
        // spaces, keyboard layouts, and composed text.
        if barController?.searchOwnsFirstResponder == true {
            return event
        }

        // Other live editors, such as Pinboard rename, also retain native key
        // behavior. Requiring `currentEditor` avoids reviving a stale field
        // editor that an ordered-out panel retained from an earlier search.
        if let fieldEditor = event.window?.firstResponder as? NSTextView,
           fieldEditor.isFieldEditor,
           let control = fieldEditor.delegate as? NSControl,
           control.currentEditor() === fieldEditor {
            return event
        }

        if store.source != .pasteStack,
           includes(Settings.shared.quickPasteModifier, in: flags),
           let chars = event.charactersIgnoringModifiers,
           let n = Int(chars), (1...9).contains(n) {
            let items = store.visibleItems
            if n <= items.count {
                pasteItem(items[n - 1], asPlainText: includes(Settings.shared.plainTextModifier, in: flags))
            }
            return nil
        }

        switch code {
        case kVK_Space:
            if Settings.shared.clipPreviewStyle == .inlinePesty,
               store.source != .pasteStack,
               store.selectedItem != nil {
                toggleInlinePreview()
            } else if store.source == .pasteStack {
                let entries = pasteSequence.visibleEntries(matching: store.searchText)
                QuickLookService.shared.toggle(items: entries.map(\.item),
                                               selectedID: selectedVisiblePasteStackEntry?.item.id)
            } else {
                QuickLookService.shared.toggle(items: store.visibleItems, selectedID: store.selectedID)
            }
            return nil
        case kVK_Escape:
            cancelBarSearchOrHide()
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            // Holding Return after submitting a search must not immediately
            // paste when the key begins repeating in card mode.
            guard !event.isARepeat else { return nil }
            if store.source == .pasteStack {
                pasteSelectedStackEntry()
                return nil
            }
            pasteSelected(); return nil
        case kVK_ANSI_C:
            if cmd {
                commandCopy()
                return nil
            }
        case kVK_ANSI_Z:
            if cmd,
               !flags.contains(.shift),
               !flags.contains(.option),
               !flags.contains(.control),
               store.undoLastDelete() { return nil }
        case kVK_LeftArrow:
            if cmd { moveBarSection(by: -1) }
            else { moveBarSelection(by: -1) }
            return nil
        case kVK_RightArrow:
            if cmd { moveBarSection(by: 1) }
            else { moveBarSelection(by: 1) }
            return nil
        case kVK_UpArrow:
            moveBarSelection(by: -1); return nil
        case kVK_DownArrow:
            moveBarSelection(by: 1); return nil
        case kVK_Delete:
            // Backspace edits the query before it can remove a filtered stack
            // entry. This matches the existing Clipboard search behavior.
            if !cmd, !store.searchText.isEmpty {
                store.barInputMode = .search
                if barController?.focusSearchAtEnd() == true {
                    return event
                }
                updateBarSearchText(String(store.searchText.dropLast()))
                return nil
            }
            if store.source == .pasteStack, let entry = selectedVisiblePasteStackEntry {
                removePasteStackEntry(entry)
                return nil
            }
            if cmd, let sel = store.selectedItem { store.delete(sel); return nil }
            if let sel = store.selectedItem { store.delete(sel) }
            return nil
        case kVK_ForwardDelete:
            if store.source == .pasteStack, let entry = selectedVisiblePasteStackEntry {
                removePasteStackEntry(entry)
                return nil
            }
            if let sel = store.selectedItem { store.delete(sel) }
            return nil
        default:
            break
        }

        if isPrintableTextIntent(event) {
            store.barInputMode = .search
            if barController?.focusSearchAtEnd() == true {
                // The local monitor runs before responder dispatch. Returning
                // the same event now sends its very first character directly
                // to the newly focused native field editor.
                return event
            }
            if let chars = fallbackSearchCharacters(from: event) {
                updateBarSearchText(store.searchText + chars)
            }
            return nil
        }
        return event
    }

    private func moveBarSelection(by delta: Int) {
        if store.source == .pasteStack {
            pasteSequence.moveSelection(by: delta, matching: store.searchText)
            QuickLookService.shared.updateSelection(selectedID: selectedVisiblePasteStackEntry?.item.id)
            return
        }
        store.moveSelection(by: delta)
        QuickLookService.shared.updateSelection(selectedID: store.selectedID)
    }

    private var selectedVisiblePasteStackEntry: PasteStackEntry? {
        guard store.source == .pasteStack,
              let id = pasteSequence.selectedEntryID else { return nil }
        return pasteSequence.visibleEntries(matching: store.searchText)
            .first(where: { $0.id == id })
    }

    private var hasVisibleSearchResult: Bool {
        if store.source == .pasteStack {
            return !pasteSequence.visibleEntries(matching: store.searchText).isEmpty
        }
        return !store.visibleItems.isEmpty
    }

    private func isPrintableTextIntent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        guard !flags.contains(.command),
              !flags.contains(.control),
              let chars = event.charactersIgnoringModifiers,
              !chars.isEmpty else { return false }
        return chars.unicodeScalars.contains {
            $0.value >= 0x20
                && $0.value != 0x7F
                && !(0xF700...0xF8FF).contains($0.value)
        }
    }

    private func fallbackSearchCharacters(from event: NSEvent) -> String? {
        let flags = event.modifierFlags
        guard !flags.contains(.command),
              !flags.contains(.control),
              let chars = event.characters,
              !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({
                  $0.value >= 0x20
                      && $0.value != 0x7F
                      && !(0xF700...0xF8FF).contains($0.value)
              }) else { return nil }
        return chars
    }

    private func resetBarSelectionForSearch() {
        if store.source == .pasteStack {
            pasteSequence.selectFirst(matching: store.searchText)
        } else {
            store.selectFirst()
        }
    }

    private func reconcilePasteStackSearchSelection() {
        guard store.source == .pasteStack else { return }
        pasteSequence.reconcileSelection(matching: store.searchText)
    }

    /// Cycles the same sources, in the same order, that the tab bar presents.
    /// The plus button is intentionally excluded: it creates a new pinboard
    /// rather than representing a navigable section.
    private func moveBarSection(by delta: Int) {
        let stackSource: [BarSource] = Settings.shared.pasteStacksEnabled ? [.pasteStack] : []
        let sources: [BarSource] = [.history] + stackSource + store.pinboards.map { .pinboard($0.id) }
        guard !sources.isEmpty else { return }

        let currentIndex = sources.firstIndex(of: store.source) ?? 0
        let nextIndex = (currentIndex + delta % sources.count + sources.count) % sources.count
        switch sources[nextIndex] {
        case .pasteStack:
            showPasteStackTab()
        case let source:
            store.source = source
            store.selectFirst()
        }
    }

    private func includes(_ carbonModifier: Int, in flags: NSEvent.ModifierFlags) -> Bool {
        switch carbonModifier {
        case cmdKey: flags.contains(.command)
        case optionKey: flags.contains(.option)
        case controlKey: flags.contains(.control)
        case shiftKey: flags.contains(.shift)
        default: false
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
