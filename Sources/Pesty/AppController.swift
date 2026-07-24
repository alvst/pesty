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
    private var keyMonitor: Any?
    private let copyToast = CopyToastController()

    private(set) var previousApp: NSRunningApplication?
    private(set) var lastActiveApp: NSRunningApplication?

    var suppressAutoHide = false

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

        if !Settings.shared.onboarded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showSettings()
            }
            Settings.shared.onboarded = true
        }
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
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        let pause = menu.addItem(withTitle: "Pause Pesty", action: #selector(menuTogglePause), keyEquivalent: "")
        pause.target = self
        pauseMenuItem = pause
        let clear = menu.addItem(withTitle: "Clear History", action: #selector(menuClear), keyEquivalent: "")
        clear.target = self
        clear.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.addItem(.separator())
        let about = menu.addItem(withTitle: "About Pesty", action: #selector(menuAbout), keyEquivalent: "")
        about.target = self
        about.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        let quit = menu.addItem(withTitle: "Quit Pesty", action: #selector(menuQuit), keyEquivalent: "q")
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
        pauseMenuItem?.title = paused ? "Resume Pesty" : "Pause Pesty"
        pauseMenuItem?.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
    }

    private func updateStatusItemIcon(_ item: NSStatusItem) {
        item.button?.image = NSImage(systemSymbolName: monitor.isPaused ? "pause.circle" : "doc.on.clipboard", accessibilityDescription: "Pesty")
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

    private func handleGlobalShortcut() {
        toggleBar()
    }

    func showBar() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }
        store.searchText = ""
        store.source = .history
        store.applyHistoryPolicy()
        store.prepareForBarPresentation()

        if barController == nil {
            barController = BarWindowController()
        }
        barController?.show()
        startKeyMonitor()
    }

    func hideBar() {
        stopKeyMonitor()
        barController?.hide()
    }

    func pasteSelected(asPlainText: Bool = false) {
        guard let item = store.selectedItem else { return }
        hideBar()
        PasteService.paste(item, into: previousApp, monitor: monitor, asPlainText: asPlainText)
    }

    func pasteItem(_ item: ClipItem, asPlainText: Bool = false) {
        hideBar()
        PasteService.paste(item, into: previousApp, monitor: monitor, asPlainText: asPlainText)
    }

    func copyItem(_ item: ClipItem) {
        let change = PasteService.copy(item)
        monitor.suppressUntilChangeCount = change
        hideBar()
        copyToast.show()
    }

    func copySelected() {
        guard let item = store.selectedItem else { return }
        let change = PasteService.copy(item)
        monitor.suppressUntilChangeCount = change
        hideBar()
        copyToast.show()
    }

    func commandCopy() {
        if pasteSequence.isBuilding, let item = store.selectedItem {
            addToPasteStack(item)
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
        pasteSequence.begin()
        showPasteStack()
    }

    func showPasteStack() {
        if !pasteSequence.isCollecting { pasteSequence.begin() }
        if pasteStackController == nil {
            pasteStackController = PasteStackWindowController()
        }
        // Showing a sibling panel causes the bar to resign key. Keep the bar
        // visible for that transition so its selected clip can be added with ⌘C.
        suppressAutoHide = true
        pasteStackController?.show()
        DispatchQueue.main.async { [weak self] in self?.suppressAutoHide = false }
    }

    func hidePasteStack() {
        pasteSequence.finishCollecting()
        pasteStackController?.hide()
    }

    var isPasteStackVisible: Bool { pasteStackController?.isVisible == true }

    func newPasteStack() {
        pasteSequence.newStack()
        showPasteStack()
    }

    func addToPasteStack(_ item: ClipItem) {
        _ = pasteSequence.addIfNeeded(item)
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

    func startPasteSequence() {
        pasteNextInSequence()
    }

    func cancelPasteSequence() {
        pasteSequence.finishCollecting()
    }

    func pasteNextInSequence() {
        guard let entry = pasteSequence.next() else { return }
        hideBar()
        PasteService.paste(entry.item,
                           into: previousApp,
                           monitor: monitor,
                           imageOverride: entry.imagePreview)
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
        let code = Int(event.keyCode)
        let flags = event.modifierFlags
        let cmd = flags.contains(.command)
        let ctrl = flags.contains(.control)
        let opt = flags.contains(.option)

        if includes(Settings.shared.quickPasteModifier, in: flags),
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
            QuickLookService.shared.toggle(items: store.visibleItems, selectedID: store.selectedID)
            return nil
        case kVK_Escape:
            if pasteSequence.isBuilding {
                cancelPasteSequence()
                return nil
            }
            if !store.searchText.isEmpty { store.searchText = ""; store.selectFirst() }
            else { hideBar() }
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if pasteSequence.isBuilding {
                pasteNextInSequence()
                return nil
            }
            pasteSelected(); return nil
        case kVK_ANSI_C:
            if cmd {
                commandCopy()
                return nil
            }
        case kVK_LeftArrow, kVK_UpArrow:
            moveBarSelection(by: -1); return nil
        case kVK_RightArrow, kVK_DownArrow:
            moveBarSelection(by: 1); return nil
        case kVK_Delete:
            if cmd, let sel = store.selectedItem { store.delete(sel); return nil }
            if !store.searchText.isEmpty {
                store.searchText.removeLast(); store.selectFirst(); return nil
            }
            if let sel = store.selectedItem { store.delete(sel) }
            return nil
        case kVK_ForwardDelete:
            if let sel = store.selectedItem { store.delete(sel) }
            return nil
        default:
            break
        }

        if !cmd && !ctrl && !opt,
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
