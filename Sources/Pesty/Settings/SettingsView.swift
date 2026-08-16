import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var section: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
            Divider()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title)
                            .font(.system(size: 20, weight: .bold))
                        Text(section.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 18)
                Divider()
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 760, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("Pesty")
                    .font(.system(size: 16, weight: .bold))
            }
            .padding(.bottom, 18)

            ForEach(SettingsSection.allCases) { item in
                Button { section = item } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(section == item ? Color.accentColor.opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        // A plain-style button only hit-tests its drawn
                        // pixels (the icon and text glyphs) by default - the
                        // whole pill is the intended target, not just those.
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("Pesty \(Bundle.main.appVersion)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 174)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .general: GeneralSettings()
        case .privacy: PrivacySettings()
        case .shortcuts: ShortcutsSettings()
        case .sync: SyncSettings()
        case .about: AboutView()
        }
    }
}

private enum SettingsSection: CaseIterable, Identifiable {
    case general, privacy, shortcuts, sync, about
    var id: Self { self }
    var title: String {
        switch self { case .general: "General"; case .privacy: "Privacy"; case .shortcuts: "Shortcuts"; case .sync: "Sync"; case .about: "About" }
    }
    var subtitle: String {
        switch self {
        case .general: "History, behavior, and app preferences"
        case .privacy: "Keep clips from selected apps out of Pesty"
        case .shortcuts: "Keyboard controls for Pesty"
        case .sync: "Keep your clipboard history available on every Mac"
        case .about: "Pesty for macOS"
        }
    }
    var symbol: String {
        switch self { case .general: "gearshape"; case .privacy: "hand.raised"; case .shortcuts: "keyboard"; case .sync: "icloud"; case .about: "info.circle" }
    }
}

// MARK: - Shared card components

/// A titled group of settings, rendered as a heading above one or more
/// `SettingsSurface` cards. Shared across every section so the whole window
/// stays visually consistent.
private struct SettingsFormGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 17, weight: .semibold))
            content
        }
    }
}

/// The rounded, bordered card that holds a group's actual controls.
private struct SettingsSurface<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08))
            }
    }
}

/// The scaffolding every section body shares: a scrollable, leading-aligned
/// column of groups capped at a comfortable reading width.
private struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .frame(maxWidth: 548, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

private func settingToggle(_ title: String, isOn: Binding<Bool>) -> some View {
    HStack(spacing: 12) {
        Text(title)
            .font(.system(size: 14))
        Spacer(minLength: 16)
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
    }
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity)
}

private func applicationName(for bundleID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
          let bundle = Bundle(url: url) else { return bundleID }
    return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? bundleID
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable private var settings = Settings.shared
    #if !MAS
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var requestedGrant = false

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    #endif

    var body: some View {
        SettingsPage {
            SettingsFormGroup("Keep History") {
                SettingsSurface {
                    HistoryRetentionSettings()
                    Divider()
                    settingToggle("Delete permanently", isOn: $settings.deletePermanently)
                    Text("Skips the five-minute Undo window — deleted clips are removed immediately and can't be recovered. Hold Option while deleting to bypass Undo for just one deletion, regardless of this setting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 10)
                    Divider()
                    HStack {
                        Text("Erase saved clips now")
                            .font(.system(size: 14))
                        Spacer()
                        Button("Erase History…", role: .destructive) {
                            ClipboardStore.shared.clearHistory()
                        }
                    }
                    .padding(.vertical, 10)
                }
            }

            SettingsFormGroup("Behavior") {
                SettingsSurface {
                    VStack(alignment: .leading, spacing: 0) {
                        #if !MAS
                        settingToggle("Paste directly into the active app", isOn: $settings.pasteDirectly)
                        Divider()
                        #endif
                        settingToggle("Play sound on paste", isOn: $settings.playSound)
                        Divider()
                        settingToggle("Play sound on copy", isOn: $settings.playSoundOnCopy)
                        Divider()
                        settingToggle("Hide Pesty when clicking outside", isOn: $settings.hideOnClickOutside)
                        Divider()
                        settingToggle("Launch at login", isOn: $settings.launchAtLogin)
                        Divider()
                        settingToggle("Show resize handle on the Paste Bar", isOn: $settings.showBarResizeHandle)
                        Divider()
                        settingToggle("Show Pesty in the menu bar", isOn: $settings.showMenuBarIcon)
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Bar height", value: "\(Int(settings.barHeight)) px")
                                .font(.system(size: 14))
                            Slider(value: $settings.barHeight, in: 300...720, step: 10)
                        }
                        .padding(.vertical, 12)
                        #if MAS
                        Text("Select a clip to copy it, then press ⌘V to paste it into your app.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.top, 4)
                            .padding(.bottom, 8)
                        #endif
                    }
                }
            }
            .onChange(of: settings.barHeight) { _, _ in
                AppController.shared.updateConfiguredBarHeight()
            }

            SettingsFormGroup("Clip Previews") {
                SettingsSurface {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Preview style") {
                            Picker("", selection: $settings.clipPreviewStyle) {
                                ForEach(ClipPreviewStyle.allCases) { style in
                                    Text(style.title).tag(style)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        .font(.system(size: 14))
                        .padding(.vertical, 10)
                        Divider()
                        Text(settings.clipPreviewStyle.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 10)
                    }
                }
            }

            SettingsFormGroup("Open Clips With") {
                SettingsSurface {
                    VStack(alignment: .leading, spacing: 0) {
                        previewApplicationRow(for: .text)
                        Divider()
                        previewApplicationRow(for: .image)
                        Divider()
                        previewApplicationRow(for: .link)
                        Divider()
                        HStack {
                            Text("Restore Apple defaults")
                                .font(.system(size: 14))
                            Spacer()
                            Button("Restore") {
                                settings.restorePreviewApplicationDefaults()
                            }
                        }
                        .padding(.vertical, 10)
                    }
                    Text("These set the one-click app in Inline Pesty previews. Use its arrow to choose a different app just once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .padding(.bottom, 8)
                }
            }

            #if !MAS
            SettingsFormGroup("Accessibility") {
                SettingsSurface {
                    HStack(spacing: 12) {
                        Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(accessibilityGranted ? .green : .orange)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(accessibilityGranted ? "Accessibility enabled" : "Accessibility required")
                                .font(.system(size: 14, weight: .medium))
                            Text(accessibilityGranted
                                 ? "Direct paste is ready to use."
                                 : (requestedGrant ? "Waiting for approval in System Settings." : "Required to paste directly into other apps."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !accessibilityGranted {
                            Button("Open Settings") {
                                requestedGrant = true
                                PasteService.ensureAccessibility(prompt: true)
                                openAccessibilityPane()
                            }
                        } else if requestedGrant {
                            Button("Restart Pesty") { AppController.restart() }
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
            #endif
        }
        .background(Color.clear)
        #if !MAS
        .onAppear { accessibilityGranted = AXIsProcessTrusted() }
        .onReceive(poll) { _ in
            let now = AXIsProcessTrusted()
            if now != accessibilityGranted { accessibilityGranted = now }
        }
        #endif
    }

    #if !MAS
    private func openAccessibilityPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    #endif

    private func previewApplicationRow(for target: PreviewOpenTarget) -> some View {
        let bundleID = settings.previewApplicationBundleID(for: target)
        return HStack(spacing: 10) {
            Image(nsImage: AppIconProvider.icon(forBundleID: bundleID))
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(target.title)
                    .font(.system(size: 14, weight: .medium))
                Text(applicationName(for: bundleID))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Change…") {
                choosePreviewApplication(for: target)
            }
        }
        .padding(.vertical, 9)
    }

    private func choosePreviewApplication(for target: PreviewOpenTarget) {
        let panel = NSOpenPanel()
        panel.title = "Choose Default App for \(target.title)"
        panel.message = "Pesty will use this app when opening \(target.title.lowercased()) from an inline preview."
        panel.prompt = "Choose App"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        settings.setPreviewApplicationBundleID(bundleID, for: target)
    }
}

/// The "Keep History" card's mode picker plus either the item-count stepper
/// or the age-based preset slider - drafts changes and confirms before
/// applying anything that would actually remove clips.
private struct HistoryRetentionSettings: View {
    private var settings = Settings.shared
    @State private var draftMode = Settings.shared.historyRetentionMode
    @State private var draftLimit = Settings.shared.historyLimit
    @State private var draftDays = Settings.shared.historyRetentionDays
    @State private var pendingRemovalCount = 0
    @State private var confirmingChange = false

    private var draftPreset: HistoryRetentionPreset { HistoryRetentionPreset(nearestDays: draftDays) }

    private var draftPresetSliderValue: Binding<Double> {
        Binding(
            get: { draftPreset.sliderIndex },
            set: { draftDays = HistoryRetentionPreset(sliderIndex: $0).days }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Keep history by", selection: $draftMode) {
                ForEach(HistoryRetentionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            // A segmented Picker stretches to fill whatever width its
            // container proposes by default - Alvie's Pesty keeps this
            // compact, hugging just its two labels, not the full card.
            .fixedSize()
            if draftMode == .itemCount {
                Stepper(value: $draftLimit, in: 50...5000, step: 50) {
                    LabeledContent("Number of clips", value: "\(draftLimit) items")
                        .font(.system(size: 14))
                }
                Text("Pesty keeps the most recent \(draftLimit) clips.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Keep clips for")
                            .font(.system(size: 14))
                        Spacer()
                        Text(draftPreset.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    Slider(value: draftPresetSliderValue,
                           in: 0...Double(HistoryRetentionPreset.allCases.count - 1),
                           step: 1)
                    HStack(spacing: 0) {
                        ForEach(HistoryRetentionPreset.allCases) { preset in
                            Text(preset.shortTitle)
                                .font(.system(size: 10, weight: preset == draftPreset ? .bold : .medium))
                                .foregroundStyle(preset == draftPreset ? Color.accentColor : .secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                Text(footnote)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
        .onChange(of: draftMode) { evaluateDraft() }
        .onChange(of: draftLimit) { evaluateDraft() }
        .onChange(of: draftDays) { evaluateDraft() }
        .alert("Remove \(pendingRemovalCount) Clips?", isPresented: $confirmingChange) {
            Button("Remove \(pendingRemovalCount) Clips", role: .destructive) { commit() }
            Button("Cancel", role: .cancel) { revert() }
        } message: {
            Text("This setting removes \(pendingRemovalCount) clips from history on this Mac now, and keeps pruning automatically. Pinboards are not affected, and there is no undo.")
        }
    }

    private var footnote: String {
        #if MAS
        "Pruning tidies this Mac only — synced copies stay on your other devices. Pinned clips are never removed."
        #else
        "Pruning applies to this Mac's history. Pinned clips are never removed."
        #endif
    }

    private func evaluateDraft() {
        let count = ClipboardStore.shared.retentionRemovalCount(
            mode: draftMode, limit: draftLimit, days: draftDays)
        if count > 0 {
            pendingRemovalCount = count
            confirmingChange = true
        } else {
            commit()
        }
    }

    private func commit() {
        settings.historyRetentionMode = draftMode
        settings.historyLimit = draftLimit
        settings.historyRetentionDays = draftDays
        ClipboardStore.shared.applyRetentionPolicy()
    }

    private func revert() {
        draftMode = settings.historyRetentionMode
        draftLimit = settings.historyLimit
        draftDays = settings.historyRetentionDays
    }
}

// MARK: - Privacy

private struct PrivacySettings: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        SettingsPage {
            SettingsFormGroup("Excluded Apps") {
                SettingsSurface {
                    Text("Pesty will not save anything copied while one of these apps is frontmost. Copies made from a browser extension are attributed to the browser, so add that too if you use one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .padding(.bottom, settings.ignoredSourceAppBundleIDs.isEmpty ? 12 : 8)

                    if settings.ignoredSourceAppBundleIDs.isEmpty {
                        ContentUnavailableView("No apps excluded",
                                               systemImage: "hand.raised",
                                               description: Text("Add an app to keep its copied content out of Pesty."))
                            .font(.system(size: 12))
                            .padding(.vertical, 14)
                    } else {
                        ForEach(settings.ignoredSourceAppBundleIDs, id: \.self) { bundleID in
                            Divider()
                            ignoredAppRow(bundleID)
                        }
                    }

                    Divider()
                    Button { chooseApps() } label: {
                        Label("Add App…", systemImage: "plus")
                    }
                    .padding(.vertical, 10)
                }
            }

            SettingsFormGroup("Concealed Clips") {
                SettingsSurface {
                    settingToggle("Ignore passwords (concealed clips)", isOn: $settings.ignoreConcealed)
                    Text("Pesty also respects the standard macOS concealed-clipboard marker used by password managers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    private func ignoredAppRow(_ bundleID: String) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIconProvider.icon(forBundleID: bundleID))
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(applicationName(for: bundleID))
                    .font(.system(size: 13, weight: .medium))
                Text(bundleID)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { settings.removeIgnoredSourceApp(bundleID) } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Allow clips from \(applicationName(for: bundleID))")
        }
        .padding(.vertical, 7)
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.title = "Exclude Apps from Pesty"
        panel.message = "Pesty will ignore copied content from the apps you choose."
        panel.prompt = "Add Apps"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier else { continue }
            settings.addIgnoredSourceApp(bundleID)
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettings: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        SettingsPage {
            SettingsFormGroup("Open Pesty") {
                SettingsSurface {
                    LabeledContent("Show the Pesty bar") { HotkeyRecorderView() }
                        .font(.system(size: 14))
                        .padding(.vertical, 9)
                }
            }

            SettingsFormGroup("Quick Paste") {
                SettingsSurface {
                    VStack(spacing: 0) {
                        LabeledContent("Paste items 1–9") {
                            HStack(spacing: 6) {
                                modifierPicker(selection: $settings.quickPasteModifier)
                                Text("+ 1…9").foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 14))
                        .padding(.vertical, 10)
                        Divider()
                        LabeledContent("Paste as plain text") {
                            modifierPicker(selection: $settings.plainTextModifier)
                        }
                        .font(.system(size: 14))
                        .padding(.vertical, 10)
                    }
                    Text("Hold the plain-text modifier while using Quick Paste to strip formatting — with the defaults, ⌘⇧1 pastes the first clip as plain text. The two roles can never share a modifier; picking one that is taken swaps them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    private func modifierPicker(selection: Binding<Int>) -> some View {
        Picker("", selection: selection) {
            ForEach(ShortcutModifier.allCases) { modifier in
                Text("\(modifier.symbol) \(modifier.title)").tag(modifier.carbonValue)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 118)
    }
}

// MARK: - Sync

private struct SyncSettings: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        SettingsPage {
            #if MAS
            SettingsFormGroup("iCloud") {
                SettingsSurface {
                    settingToggle("Sync history with iCloud", isOn: Binding(
                        get: { settings.cloudKitSync },
                        set: { on in
                            settings.cloudKitSync = on
                            if on { CloudSyncService.shared.enable() } else { CloudSyncService.shared.stop() }
                        }))
                    Text(CloudSyncService.shared.status)
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                }
            }
            #else
            SettingsFormGroup("iCloud Drive") {
                SettingsSurface {
                    settingToggle("Sync clipboard via iCloud Drive", isOn: Binding(
                        get: { settings.iCloudSync },
                        set: { _ in AppController.shared.toggleICloudSync() }))
                    Text(ClipboardStore.shared.iCloudAvailable
                         ? "Keeps your history and pinboards in sync across your Macs through iCloud Drive."
                         : "Sign in to iCloud and enable iCloud Drive to use sync.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                }
            }
            #endif
        }
    }
}

// MARK: - About

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable().frame(width: 88, height: 88)
            Text("Pesty").font(.system(size: 26, weight: .bold))
            Text("Version \(Bundle.main.appVersion)")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("A free, open-source clipboard manager for macOS.\nInspired by Paste.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            HStack(spacing: 16) {
                Link("GitHub", destination: URL(string: "https://github.com/momenbasel/pesty")!)
                Link("Report an Issue", destination: URL(string: "https://github.com/momenbasel/pesty/issues")!)
            }
            .padding(.top, 4)
            Button("Quit Pesty", role: .destructive) {
                NSApp.terminate(nil)
            }
            .padding(.top, 8)
            Spacer()
            Text("MIT Licensed · Made with SwiftUI")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
