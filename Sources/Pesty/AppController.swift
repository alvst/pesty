import AppKit
import SwiftUI
import Carbon.HIToolbox
@preconcurrency import QuickLookUI
import os.log

private let dragLog = Logger(subsystem: "com.greycorelabs.pesty", category: "PinboardDrag")

extension Notification.Name {
    /// Posted when a drag that started in the bar ends (drop, abandon, or
    /// Escape-cancel), so drop targets can clear hover chrome — a trailing
    /// dropUpdated can otherwise repaint a caret or ring after performDrop
    /// already cleared it.
    static let pestyDragSessionEnded = Notification.Name("PestyDragSessionEnded")
}

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
    private var dragOutTimer: Timer?
    private var isReopenPresentationPending = false
    private var editorFocusRestore: EditorFocusRestore?
    private let copyToast = CopyToastController()
    private let barHeightGhost = BarHeightGhostController()

    private(set) var previousApp: NSRunningApplication?
    private(set) var lastActiveApp: NSRunningApplication?

    var suppressAutoHide = false

    /// True for as long as the clip editor owns the screen. Editing suppresses
    /// auto-hide so the bar survives the editor taking focus, but the bar must
    /// still get out of the way if the user leaves for another app entirely.
    private var isEditorOpen = false

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
        installMainMenu()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        monitor.start()

        HotKeyCenter.shared.onTrigger = { [weak self] in self?.handleGlobalShortcut() }
        HotKeyCenter.shared.onSequenceTrigger = { [weak self] in self?.pasteNextInSequence() }
        HotKeyCenter.shared.start()

        QuickLookService.shared.onSelectionChange = { [weak self] id in
            guard let self, store.source != .pasteStack else { return }
            store.selectedID = id
        }
        QuickLookService.shared.onPanelDidClose = { [weak self] in
            self?.quickLookDidClose()
        }

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
            // While the editor is open, auto-hide is suppressed on purpose —
            // but that suppression is about the editor's own focus, not about
            // the user switching to a different app. Leaving for another app
            // should still drop the bar.
            if barController?.window?.isVisible == true, !suppressAutoHide || isEditorOpen {
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
        let open = menu.addItem(withTitle: "Open Pesty-Alvie   \(Settings.shared.hotkeyDisplay)",
                                action: #selector(menuOpen), keyEquivalent: "")
        open.target = self
        open.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        let pause = menu.addItem(withTitle: "Pause Pesty-Alvie", action: #selector(menuTogglePause), keyEquivalent: "")
        pause.target = self
        pause.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)
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
        // The real bar supersedes any height outline still lingering.
        barHeightGhost.hide()
        barController?.show()
        // An open Settings window rises with the bar instead of staying
        // buried behind whatever app the user summoned Pesty over.
        if let settings = settingsWindow, settings.isVisible {
            settings.orderFrontRegardless()
        }
        startKeyMonitor()
    }

    func hideBar(immediately: Bool = false) {
        stopKeyMonitor()
        barController?.resignSearch()
        store.barInputMode = .cards
        store.inlinePreviewVisible = false
        inlinePreviewController?.hide()
        // Quick Look is a companion surface to the bar; it never outlives it.
        QuickLookService.shared.dismiss()
        barController?.hide(immediately: immediately)
        // The bar itself never activates Pesty, but an alert, a drop, or a
        // click on Settings can. Hiding while Pesty is active would strand
        // keyboard focus with no visible window — hand it back, unless a
        // Pesty window like Settings is exactly what the user focused.
        yieldActivationToPreviousApp()
    }

    /// Returns focus to the app the user came from — but never while another
    /// Pesty window (Settings, the editor) holds key: stealing focus back
    /// from a window the user just clicked would make it unusable.
    @discardableResult
    private func yieldActivationToPreviousApp() -> Bool {
        guard NSApp.isActive else { return false }
        if let key = NSApp.keyWindow, key !== barController?.window, !(key is QLPreviewPanel) {
            return false
        }
        guard let target = previousApp ?? lastActiveApp, !target.isTerminated else { return false }
        NSApp.yieldActivation(to: target)
        target.activate()
        return true
    }

    /// Whether the Paste Bar is currently on screen, for surfaces that must
    /// lay themselves out around it.
    var isBarPresented: Bool { barController?.isPresented == true }

    /// Feedback for the Settings height slider: resize the real bar when it
    /// is up, and otherwise outline the proposed size where the bar would be.
    func previewBarHeight(_ height: Double) {
        if isBarPresented {
            barHeightGhost.hide()
            resizeVisibleBar(to: height)
        } else {
            barHeightGhost.show(height: CGFloat(height))
        }
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

    func pasteSelected(format: PasteFormat = .original) {
        let items = store.selectedItems
        if items.count > 1 {
            pasteCombined(items)
            return
        }
        guard let item = store.selectedItem else { return }
        pasteItem(item, format: format)
    }

    /// Several clips paste as one block, joined by newlines. Nothing is
    /// promoted: the combined text is a one-off payload, not a clip that
    /// belongs in the history.
    private func pasteCombined(_ items: [ClipItem]) {
        let text = items.compactMap(\.plainText).joined(separator: "\n")
        guard !text.isEmpty else { return }
        let target = pasteTargetApp()
        hideBar(immediately: true)
        PasteService.paste(ClipItem(type: .text, text: text),
                           into: target, monitor: monitor, format: .plainText)
    }

    func pasteItem(_ item: ClipItem, format: PasteFormat = .original) {
        let target = pasteTargetApp()
        // Release the non-activating panel before sending the paste event to
        // the source app. Escape/click dismissal keeps its slide-out motion.
        hideBar(immediately: true)
        PasteService.paste(item, into: target, monitor: monitor, format: format)
        if Settings.shared.promoteOnPaste {
            store.promoteCopiedItem(item)
        }
    }

    func copyItem(_ item: ClipItem) {
        let previousChange = NSPasteboard.general.changeCount
        let change = PasteService.copy(item)
        monitor.suppressUntilChangeCount = change
        if change != previousChange {
            store.promoteCopiedItem(item)
        }
        // Tink, not Pop: copy and paste stay audibly distinct.
        if Settings.shared.playSoundOnCopy { FeedbackSound.play(FeedbackSound.copy) }
        hideBar()
        copyToast.show()
    }

    func copySelected() {
        let items = store.selectedItems
        guard !items.isEmpty else { return }
        guard items.count > 1 else {
            copyItem(items[0])
            return
        }
        // A combined copy has no single source clip to promote.
        monitor.suppressUntilChangeCount = PasteService.copy(items)
        if Settings.shared.playSoundOnCopy { FeedbackSound.play(FeedbackSound.copy) }
        hideBar()
        copyToast.show()
    }

    /// Deletes every selected clip, so ⌫ acts on exactly what the rings show.
    private func deleteBarSelection(permanently: Bool) {
        let items = store.selectedItems
        guard !items.isEmpty else { return }
        for item in items { store.delete(item, permanently: permanently) }
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

        isEditorOpen = true
        // The editor supersedes Quick Look. Dismiss it only after marking the
        // editor open so its normal close callback does not hand focus back to
        // the previous app in the middle of this window transition.
        QuickLookService.shared.dismiss()
        let edit = ClipEditor.run(for: item, launchWritingTools: launchWritingTools)
        isEditorOpen = false

        // Cancelling or dismissing ends the session the bar was opened for,
        // so the bar leaves with the editor. Saving does not: the edit lands
        // on a card the user is still looking at, so the bar stays up.
        //
        // This is a `defer` rather than a step inside the focus-restore
        // callback on purpose. That callback is only reached by way of an
        // app-activation notification, and every path to it can bail early —
        // no app to return to, activation refused, the restore already
        // consumed. A dismissal the user explicitly asked for must not hinge
        // on one of those notifications arriving. `defer` runs on every exit
        // below, including the guards.
        //
        // Not gated on `hideOnClickOutside`: that setting is about focus
        // drifting away from the bar, whereas abandoning the editor is a
        // deliberate end to the interaction.
        let dismissesBar = resumeBarKeys && edit == nil
        defer {
            if dismissesBar {
                suppressAutoHide = wasSuppressingAutoHide
                editorFocusRestore = nil
                hideBar()
                // `hideBar` yields activation only when no other Pesty window
                // holds key, and the just-closed editor panel can still be key
                // for an instant. Hand focus back explicitly so dismissing the
                // bar always lands the user in the app they came from.
                if let focusTarget, !focusTarget.isTerminated, !focusTarget.isActive,
                   focusTarget.bundleIdentifier != Bundle.main.bundleIdentifier {
                    NSApp.yieldActivation(to: focusTarget)
                    focusTarget.activate()
                }
            } else {
                restoreFocusAfterEditing(to: focusTarget,
                                         restoreAutoHide: wasSuppressingAutoHide,
                                         resumeBarKeys: resumeBarKeys)
            }
        }

        guard let edit else { return }

        var changed = false
        switch edit {
        case let .text(text, richTextData, title, bodyChanged):
            if bodyChanged {
                changed = store.updateTextContent(text, richTextData: richTextData, for: item)
            }
            if title != item.customTitle {
                store.setTitle(title, for: item)
                changed = true
            }
        case let .color(hex):
            changed = store.updateColorContent(hex, for: item)
        }
        guard changed, let updatedItem = store.item(withID: item.id) else { return }

        // Keep the system clipboard in sync, without treating an in-place edit
        // as a new capture or reordering the item's history position.
        let change = PasteService.copy(updatedItem)
        monitor.suppressUntilChangeCount = change
        reconcilePasteStackSearchSelection()

        if previewedItemID == item.id, previewWindow?.isVisible == true {
            showPreview(for: updatedItem)
        }
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
        if resumeBarKeys {
            // The editor took key away from the panel. Hand it back the
            // nonactivating way the bar normally holds it, so a bar left open
            // after a save responds to arrows and Return straight away.
            if barController?.isPresented == true { barController?.bringToFront() }
            startKeyMonitor()
        }
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

    /// True while a drag that started inside the bar is still holding the
    /// mouse button.
    var isDragSessionActive: Bool { dragOutTimer != nil }

    /// The clip whose card is being dragged. The drag never leaves this
    /// process for in-bar drops, so the ID is handed over directly — custom
    /// pasteboard types don't survive the drag pasteboard's promise
    /// round-trip reliably (loadDataRepresentation fails for undeclared
    /// UTIs), and the payload on the pasteboard is only a marker.
    private(set) var draggedClipID: UUID?
    private var dragSessionCancelled = false

    func beginDragOut(itemID: UUID) {
        draggedClipID = itemID
        // The native dragging session reports when the drag leaves the bar
        // (dragSessionExitedBar), so the poll only handles Escape and
        // drag-end bookkeeping.
        beginDragTracking(hidesBarWhenLeaving: false)
    }

    /// The dragging session crossed out of the bar's window: it is headed
    /// for another app, so the bar hides to uncover the drop target —
    /// unless Escape already neutralized the drag.
    func dragSessionExitedBar() {
        guard !dragSessionCancelled else { return }
        hideBar()
    }

    func beginTabDrag() {
        // A Pinboard tab means nothing outside the bar, so the bar stays up
        // for the whole drag; tracking still runs for Escape-to-cancel.
        draggedClipID = nil
        beginDragTracking(hidesBarWhenLeaving: false)
    }

    private func beginDragTracking(hidesBarWhenLeaving: Bool) {
        dragLog.debug("drag tracking started (hidesBarWhenLeaving=\(hidesBarWhenLeaving))")
        dragSessionCancelled = false
        // The bar stays up while the drag remains inside it, so a card can be
        // dropped on a Pinboard tab. Once the drag leaves the panel it is
        // headed for another app, and the bar hides to uncover the drop
        // target. Drag sessions run the loop in the event-tracking mode, so
        // the timer must be scheduled in .common to fire at all. The interval
        // also samples the Escape key, so it must stay short enough to catch
        // a quick tap.
        dragOutTimer?.invalidate()
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated { self?.pollDrag(timer, hidesBarWhenLeaving: hidesBarWhenLeaving) }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragOutTimer = timer
    }

    private func pollDrag(_ timer: Timer, hidesBarWhenLeaving: Bool) {
        // Buttons released: the drag is over. If it ended over the bar (a
        // Pinboard drop or an abandoned drag), the bar stays. draggedClipID
        // survives until the next drag — performDrop may still be reading it.
        if NSEvent.pressedMouseButtons == 0 {
            timer.invalidate()
            dragOutTimer = nil
            NotificationCenter.default.post(name: .pestyDragSessionEnded, object: nil)
            return
        }
        // Key events never reach this app's monitors during a drag session,
        // so Escape is sampled directly. Cancelling empties the drag
        // pasteboard and forgets the dragged clip: wherever the user lets
        // go — even in another app — the drop delivers nothing.
        if !dragSessionCancelled,
           CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Escape)) {
            dragSessionCancelled = true
            draggedClipID = nil
            NSPasteboard(name: .drag).clearContents()
            NotificationCenter.default.post(name: .pestyDragSessionEnded, object: nil)
            dragLog.debug("drag cancelled via Escape")
        }
        if hidesBarWhenLeaving, !dragSessionCancelled,
           let panel = barController?.window, panel.isVisible,
           !panel.frame.contains(NSEvent.mouseLocation) {
            hideBar()
        }
    }

    /// Pins a dragged clip onto a Pinboard tab. The card may have come from
    /// the history strip, another Pinboard, or a Paste Stack, so the ID is
    /// resolved across all of them.
    /// AppKit activates an app when a drop lands in one of its windows, so
    /// an in-bar drop (pin, reorder) silently steals focus from the app the
    /// user came from. Hand activation straight back and re-key the panel the
    /// nonactivating way it was before the drop.
    func restoreFocusAfterInBarDrop() {
        suppressAutoHide = true
        // First hop: let AppKit finish the drop-triggered activation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            guard yieldActivationToPreviousApp() else {
                suppressAutoHide = false
                return
            }
            // Second hop: once the target is active again, take key back the
            // nonactivating way the panel normally holds it, then re-arm
            // click-outside hiding.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                barController?.bringToFront()
                suppressAutoHide = false
            }
        }
    }

    /// Opening Quick Look activates Pesty (the panel must be able to become
    /// key). When it closes, focus goes back to the app the user came from,
    /// and the bar — if still up — retakes key the nonactivating way, so
    /// arrows and Return work again immediately.
    private func quickLookDidClose() {
        // When Edit dismisses Quick Look, the editor owns focus restoration;
        // the panel's ordinary handoff would race the new modal window.
        guard NSApp.isActive, !isEditorOpen else { return }
        suppressAutoHide = true
        yieldActivationToPreviousApp()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            if barController?.isPresented == true {
                barController?.bringToFront()
            }
            suppressAutoHide = false
        }
    }

    private var warnedAccessibilityThisLaunch = false

    /// Direct paste silently degrading to copy-only reads as "paste is
    /// broken". Explain once per launch, with a shortcut to the grant.
    func reportMissingAccessibilityForDirectPaste() {
        guard !warnedAccessibilityThisLaunch else { return }
        warnedAccessibilityThisLaunch = true
        suppressAutoHide = true
        defer { suppressAutoHide = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Pesty-Alvie can\u{2019}t paste directly"
        alert.informativeText = "The clip was copied, but macOS is blocking the automatic \u{2318}V because Accessibility permission isn\u{2019}t granted (a rebuilt app needs re-granting). Paste manually with \u{2318}V, or grant access in System Settings \u{2192} Privacy & Security \u{2192} Accessibility."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func addToPasteStack(_ item: ClipItem, toTop: Bool) {
        guard Settings.shared.pasteStacksEnabled else { return }
        pasteSequence.add(item, toTop: toTop)
    }

    func pinClip(id: UUID, toBoard boardID: UUID) {
        let candidates = store.history
            + store.pinboards.flatMap(\.items)
            + pasteSequence.entries.map(\.item)
            + pasteSequence.savedStacks.flatMap { $0.entries.map(\.item) }
        guard let item = candidates.first(where: { $0.id == id }) else {
            dragLog.debug("pinClip: no clip found for id \(id)")
            return
        }
        dragLog.debug("pinClip: pinning \(id) to board \(boardID)")
        store.saveToPinboard(item, boardID: boardID)
        restoreFocusAfterInBarDrop()
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

    func pasteStackEntry(_ entry: PasteStackEntry, format: PasteFormat = .original) {
        guard Settings.shared.pasteStacksEnabled,
              ensureStackCanPaste() else { return }
        guard let entry = pasteSequence.next(entryID: entry.id) else { return }
        reconcilePasteStackSearchSelection()
        performPasteStackEntry(entry, format: format)
    }

    func pasteSelectedStackEntry() {
        guard Settings.shared.pasteStacksEnabled,
              let entry = selectedVisiblePasteStackEntry else { return }
        pasteStackEntry(entry)
    }

    private func performPasteStackEntry(_ entry: PasteStackEntry, format: PasteFormat = .original) {
        // A global Paste Stack shortcut can fire while Pesty's floating
        // collector is key. Resolve the real foreground/last-used app at the
        // moment of the shortcut instead of relying on the app that first
        // opened the bar.
        let target = pasteTargetApp()
        hideBar(immediately: true)
        PasteService.paste(entry.item,
                           into: target,
                           monitor: monitor,
                           format: format,
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
        // Same reasoning as the preview window: Settings outlives its first
        // appearance, so it has to come to the user's Space rather than
        // sending the user to it.
        win.collectionBehavior.insert(.moveToActiveSpace)
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
    }

    /// Pesty is an `LSUIElement` app, so this menu is never drawn — but
    /// `NSApplication` matches ⌘-key equivalents against the main menu on its
    /// way to the first responder, and with no main menu at all there is
    /// nothing to match. That left every standard text command dead in the
    /// clip editor, the bar's search field, and Pinboard rename: no Undo, no
    /// Cut/Copy/Paste, no Select All, no Find.
    ///
    /// Only Edit is installed. An application menu would put ⌘Q and ⌘W in
    /// front of the bar's own key handling, which is not worth reintroducing
    /// for a menu bar the user cannot see.
    private func installMainMenu() {
        let edit = NSMenu(title: "Edit")

        func add(_ title: String, _ action: String, _ key: String,
                 _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) {
            let item = NSMenuItem(title: title, action: Selector((action)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = tag
            // A nil target sends the action down the responder chain, so
            // whichever text view or field is editing gets it.
            item.target = nil
            edit.addItem(item)
        }

        add("Undo", "undo:", "z")
        add("Redo", "redo:", "z", [.command, .shift])
        edit.addItem(.separator())
        add("Cut", "cut:", "x")
        add("Copy", "copy:", "c")
        add("Paste", "paste:", "v")
        add("Paste and Match Style", "pasteAsPlainText:", "v", [.command, .option, .shift])
        add("Delete", "delete:", "")
        add("Select All", "selectAll:", "a")
        edit.addItem(.separator())
        add("Find…", "performTextFinderAction:", "f",
            tag: NSTextFinder.Action.showFindInterface.rawValue)
        add("Find Next", "performTextFinderAction:", "g",
            tag: NSTextFinder.Action.nextMatch.rawValue)
        add("Find Previous", "performTextFinderAction:", "g", [.command, .shift],
            tag: NSTextFinder.Action.previousMatch.rawValue)

        let editItem = NSMenuItem()
        editItem.submenu = edit

        let main = NSMenu()
        // AppKit reserves the first submenu for the application menu. Leaving
        // it empty keeps Edit's key equivalents working without claiming any.
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)
        main.addItem(editItem)
        NSApp.mainMenu = main
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
        // A live drag session owns the keyboard: AppKit cancels the drag when
        // Escape reaches it, and none of the bar's own shortcuts should fire
        // mid-drag (Escape would otherwise hide the bar out from under the
        // drag instead of cancelling it).
        if isDragSessionActive {
            dragLog.debug("key \(event.keyCode) passed through during drag")
            return event
        }

        // While Quick Look is key its native arrows/Space/Esc run untouched,
        // but clipboard shortcuts still belong to the bar's selection — the
        // panel's own responder chain has no idea what "Copy" means here.
        if QLPreviewPanel.sharedPreviewPanelExists(),
           QLPreviewPanel.shared()?.isKeyWindow == true {
            if Int(event.keyCode) == kVK_ANSI_C, event.modifierFlags.contains(.command) {
                commandCopy()
                return nil
            }
            return event
        }

        // Native context menus, the clip editor, previews, and Settings own
        // their responder chains. The Paste Bar monitor only handles keys that
        // actually arrive at its floating panel.
        guard event.window === barController?.window else { return event }

        let code = Int(event.keyCode)
        let flags = event.modifierFlags
        let cmd = flags.contains(.command)

        let searchHasFocus = barController?.searchOwnsFirstResponder == true

        // Other live editors, such as Pinboard rename, retain native key
        // behavior. Requiring `currentEditor` avoids reviving a stale field
        // editor that an ordered-out panel retained from an earlier search.
        let renameHasFocus: Bool = {
            guard !searchHasFocus,
                  let fieldEditor = event.window?.firstResponder as? NSTextView,
                  fieldEditor.isFieldEditor,
                  let control = fieldEditor.delegate as? NSControl,
                  control.currentEditor() === fieldEditor else { return false }
            return true
        }()

        // Space means Preview, not a character — even when the search field
        // happens to hold focus with nothing typed yet. Only once a query is
        // actually being composed does Space become an ordinary space, so
        // multi-word searches still work.
        if code == kVK_Space,
           !renameHasFocus,
           !flags.contains(.command),
           !flags.contains(.option),
           !flags.contains(.control),
           store.searchText.isEmpty {
            togglePreviewForSelection()
            return nil
        }

        // The native search field owns the entire event while it is editing.
        // This includes arrows, selections, clipboard commands, deletion,
        // spaces, keyboard layouts, and composed text.
        if searchHasFocus { return event }
        if renameHasFocus { return event }

        if store.source != .pasteStack,
           includes(Settings.shared.quickPasteModifier, in: flags),
           let chars = event.charactersIgnoringModifiers,
           let n = Int(chars), (1...9).contains(n) {
            let items = store.visibleItems
            if n <= items.count {
                pasteItem(items[n - 1],
                          format: includes(Settings.shared.plainTextModifier, in: flags) ? .plainText : .original)
            }
            return nil
        }

        switch code {
        case kVK_Space:
            togglePreviewForSelection()
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
            else { moveBarSelection(by: -1, extending: flags.contains(.shift)) }
            return nil
        case kVK_RightArrow:
            if cmd { moveBarSection(by: 1) }
            else { moveBarSelection(by: 1, extending: flags.contains(.shift)) }
            return nil
        case kVK_UpArrow:
            moveBarSelection(by: -1, extending: flags.contains(.shift)); return nil
        case kVK_DownArrow:
            moveBarSelection(by: 1, extending: flags.contains(.shift)); return nil
        case kVK_ANSI_A:
            // ⌘A in card mode selects every visible clip. The search field is
            // handled well above this, so it keeps native select-all.
            guard cmd, store.source != .pasteStack else { break }
            store.selectAllVisible()
            return nil
        case kVK_Delete:
            // ⌘⌫ during an active search means "delete to line start" in the
            // field — never "destroy the selected clip". Text-field semantics
            // win the whole time a query is being edited.
            if cmd, store.barInputMode == .search || barController?.searchOwnsFirstResponder == true {
                return event
            }
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
            deleteBarSelection(permanently: flags.contains(.option))
            return nil
        case kVK_ForwardDelete:
            if store.source == .pasteStack, let entry = selectedVisiblePasteStackEntry {
                removePasteStackEntry(entry)
                return nil
            }
            deleteBarSelection(permanently: flags.contains(.option))
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

    /// `extending` is ⇧-arrow. The Paste Stack keeps its own single-selection
    /// model, so it simply moves.
    private func moveBarSelection(by delta: Int, extending: Bool = false) {
        if store.source == .pasteStack {
            pasteSequence.moveSelection(by: delta, matching: store.searchText)
            QuickLookService.shared.updateSelection(selectedID: selectedVisiblePasteStackEntry?.item.id)
            return
        }
        store.moveSelection(by: delta, extending: extending)
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

    /// Space's preview action, shared by the early Space rule and the card
    /// key switch so both routes behave identically.
    private func togglePreviewForSelection() {
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
