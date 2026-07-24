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
    private var settingsWindow: NSWindow?
    private var pasteStackController: PasteStackWindowController?
    private var keyMonitor: Any?

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

        setupStatusItem()

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
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Pesty")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Pesty   \(Settings.shared.hotkeyDisplay)",
                     action: #selector(menuOpen), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Clear History", action: #selector(menuClear), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let about = menu.addItem(withTitle: "About Pesty", action: #selector(menuAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(withTitle: "Quit Pesty", action: #selector(menuQuit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func menuOpen() { showBar() }
    @objc private func menuSettings() { showSettings() }
    @objc private func menuClear() { store.clearHistory() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
    @objc private func menuAbout() { showAbout() }

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
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }
        store.searchText = ""
        store.source = requestedSource ?? .history
        store.applyHistoryPolicy()
        if store.source != .pasteStack { store.selectFirst() }

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

    func pasteSelected() {
        guard let item = store.selectedItem else { return }
        hideBar()
        PasteService.paste(item, into: previousApp, monitor: monitor)
    }

    func pasteItem(_ item: ClipItem) {
        hideBar()
        PasteService.paste(item, into: previousApp, monitor: monitor)
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
        hideBar()
        PasteService.paste(entry.item,
                           into: target,
                           monitor: monitor,
                           imageOverride: entry.imagePreview)
    }

    /// Resolve the destination when the user chooses to paste, rather than
    /// holding the app that was active when the Stack was first opened.
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
        return pasteStackTargetApp ?? previousApp
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
        win.setContentSize(NSSize(width: 520, height: 560))
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

        if store.source != .pasteStack,
           cmd,
           let chars = event.charactersIgnoringModifiers,
           let n = Int(chars),
           (1...9).contains(n) {
            let items = store.visibleItems
            if n <= items.count { pasteItem(items[n - 1]) }
            return nil
        }

        switch code {
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
            store.moveSelection(by: -1); return nil
        case kVK_RightArrow, kVK_DownArrow:
            if store.source == .pasteStack {
                pasteSequence.moveSelection(by: 1)
                return nil
            }
            store.moveSelection(by: 1); return nil
        case kVK_Delete:
            if store.source == .pasteStack, let entry = pasteSequence.selectedEntry {
                removePasteStackEntry(entry)
                return nil
            }
            if cmd, let sel = store.selectedItem { store.delete(sel); return nil }
            if !store.searchText.isEmpty {
                store.searchText.removeLast(); store.selectFirst(); return nil
            }
            return nil
        case kVK_ForwardDelete:
            if store.source == .pasteStack, let entry = pasteSequence.selectedEntry {
                removePasteStackEntry(entry)
                return nil
            }
            if let sel = store.selectedItem { store.delete(sel) }
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
}

extension Bundle {
    var appVersion: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
