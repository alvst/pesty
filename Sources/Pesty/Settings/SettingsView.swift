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
                Text("Pesty-Alvie")
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
                        // A plain button only hit-tests its drawn pixels;
                        // the whole row is the target, not just the glyphs.
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("Pesty-Alvie \(Bundle.main.appVersion)")
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
        case .extensions: ExtensionsSettings()
        case .sync: SyncSettings()
        case .about: AboutView()
        }
    }
}

private enum SettingsSection: CaseIterable, Identifiable {
    case general, privacy, shortcuts, extensions, sync, about
    var id: Self { self }
    var title: String {
        switch self { case .general: "General"; case .privacy: "Privacy"; case .shortcuts: "Shortcuts"; case .extensions: "Extensions"; case .sync: "Sync"; case .about: "About" }
    }
    var subtitle: String {
        switch self {
        case .general: "History, behavior, and app preferences"
        case .privacy: "Keep clips from selected apps out of Pesty-Alvie"
        case .shortcuts: "Keyboard controls for Pesty-Alvie and Paste Stack"
        case .extensions: "Manage scripts that decorate clips and transform paste"
        case .sync: "Keep your clipboard library available across your devices"
        case .about: "Pesty-Alvie for macOS"
        }
    }
    var symbol: String {
        switch self { case .general: "gearshape"; case .privacy: "hand.raised"; case .shortcuts: "keyboard"; case .extensions: "puzzlepiece.extension"; case .sync: "icloud"; case .about: "info.circle" }
    }
}

private struct GeneralSettings: View {
    @Bindable private var settings = Settings.shared
    #if !MAS
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var requestedGrant = false

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    #endif

    @State private var storageBytes: Int64?

    private var storageSummary: String {
        let count = ClipboardStore.shared.history.count
        let clips = "\(count) clip\(count == 1 ? "" : "s")"
        guard let storageBytes else { return clips }
        return "\(clips) · \(ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file))"
    }

    private func refreshStorageSize() async {
        let dir = ClipboardStore.shared.dataDirectory
        storageBytes = await Task.detached(priority: .utility) {
            Self.directorySize(at: dir)
        }.value
    }

    /// Walks the store directory off the main actor; images can make it
    /// large enough that a synchronous walk would hitch the Settings window.
    nonisolated private static func directorySize(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url,
                                                              includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                settingsGroup("Keep History") {
                    settingCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Picker("Keep history by", selection: $settings.historyRetentionMode) {
                                ForEach(HistoryRetentionMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            if settings.historyRetentionMode == .itemCount {
                                Stepper(value: $settings.historyLimit, in: 50...5000, step: 50) {
                                    LabeledContent("Number of clips", value: "\(settings.historyLimit) items")
                                        .font(.system(size: 14))
                                }
                                Text("Pesty-Alvie keeps the most recent \(settings.historyLimit) clips.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                VStack(alignment: .leading, spacing: 9) {
                                    HStack {
                                        Text("Keep clips for")
                                            .font(.system(size: 14))
                                        Spacer()
                                        Text(settings.historyRetention.title)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    Slider(value: retentionSliderValue,
                                           in: 0...Double(HistoryRetention.allCases.count - 1),
                                           step: 1)
                                    HStack(spacing: 0) {
                                        ForEach(HistoryRetention.allCases) { retention in
                                            Text(retention.shortSliderTitle)
                                                .font(.system(size: 10, weight: retention == settings.historyRetention ? .bold : .medium))
                                                .foregroundStyle(retention == settings.historyRetention ? Color.accentColor : .secondary)
                                                .frame(maxWidth: .infinity)
                                        }
                                    }
                                }
                                Text(settings.historyRetention.description)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Divider()
                            HStack {
                                Text("Currently storing")
                                    .font(.system(size: 14))
                                Spacer()
                                Text(storageSummary)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 10)
                            Divider()
                            settingToggle("Delete permanently", isOn: $settings.deletePermanently)
                            Text("Skips the five-minute Undo window — deleted clips are removed immediately and can't be recovered. Hold Option while deleting to bypass Undo for just one deletion, regardless of this setting.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Divider()
                            HStack {
                                Text("Erase saved clips now")
                                    .font(.system(size: 14))
                                Spacer()
                                Button("Erase History…", role: .destructive) {
                                    ClipboardStore.shared.clearHistory()
                                }
                            }
                        }
                    }
                }

                settingsGroup("Pasting") {
                    settingCard {
                        VStack(alignment: .leading, spacing: 0) {
                            #if !MAS
                            settingToggle("Paste directly into the active app", isOn: $settings.pasteDirectly)
                            Divider()
                            #endif
                            settingToggle("Move pasted clips to the top of history", isOn: $settings.promoteOnPaste)
                            Divider()
                            settingToggle("Play sound on paste", isOn: $settings.playSound)
                            settingToggle("Play sound on copy", isOn: $settings.playSoundOnCopy)
                        }
                    }
                }

                settingsGroup("Window & Appearance") {
                    settingCard {
                        VStack(alignment: .leading, spacing: 0) {
                            settingToggle("Hide Pesty-Alvie when clicking outside", isOn: $settings.hideOnClickOutside)
                            Divider()
                            settingToggle("Launch at login", isOn: $settings.launchAtLogin)
                            Divider()
                            settingToggle("Paste-style clip cards", isOn: $settings.pasteStyleCards)
                            Divider()
                            settingToggle("Show resize handle on the Pesty-Alvie bar", isOn: $settings.showBarResizeHandle)
                            Divider()
                            settingToggle("Show Pesty-Alvie in the menu bar", isOn: $settings.showMenuBarIcon)
                            Divider()
                            VStack(alignment: .leading, spacing: 8) {
                                LabeledContent("Bar height", value: "\(Int(settings.barHeight)) px")
                                    .font(.system(size: 14))
                                Slider(value: $settings.barHeight, in: 300...720, step: 10)
                                    .onChange(of: settings.barHeight) { _, height in
                                        AppController.shared.previewBarHeight(height)
                                    }
                            }
                            .padding(.vertical, 12)
                        }
                    }
                }

                settingsGroup("Clip Colors") {
                    settingCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Color theme", selection: $settings.clipColorTheme) {
                                ForEach(ClipColorTheme.allCases) { theme in
                                    Text(theme.title).tag(theme)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .padding(.vertical, 9)
                            Divider()
                            Text(settings.clipColorTheme.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 9)
                            if settings.clipColorTheme == .accentShades {
                                Divider()
                                HStack(spacing: 12) {
                                    ColorPicker("Base color",
                                                selection: clipColorAccent,
                                                supportsOpacity: false)
                                        .font(.system(size: 14))
                                    Spacer(minLength: 8)
                                    HStack(spacing: 4) {
                                        ForEach(Array(SourceColor.accentShades(for: settings.clipColorAccentHex).enumerated()),
                                                id: \.offset) { _, color in
                                            Circle()
                                                .fill(color)
                                                .frame(width: 13, height: 13)
                                        }
                                    }
                                    .accessibilityLabel("Ten stable shades of the selected base color")
                                }
                                .padding(.vertical, 10)
                                Text("Each source app keeps one of ten deterministic shades, so its cards stay recognizable without drifting too far from your chosen color.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.bottom, 9)
                            }
                        }
                    }
                }

                settingsGroup("Clip Navigation") {
                    settingCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Selected clip position", selection: $settings.selectedClipPosition) {
                                ForEach(SelectedClipPosition.allCases) { position in
                                    Text(position.title).tag(position)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .padding(.vertical, 9)
                            Divider()
                            Text(settings.selectedClipPosition.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 9)
                        }
                    }
                }

                settingsGroup("Clip Previews") {
                    settingCard {
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

                settingsGroup("Open Clips With") {
                    settingCard {
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
                        Text("These set the one-click app in Inline Pesty-Alvie previews. Use its arrow to choose a different app just once.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.bottom, 8)
                    }
                }

                #if !MAS
                settingsGroup("Accessibility") {
                    settingCard {
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
                                Button("Restart Pesty-Alvie") { AppController.restart() }
                            }
                        }
                    }
                }
                #endif
            }
            .frame(maxWidth: 548, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color.clear)
        .task { await refreshStorageSize() }
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

    private var clipColorAccent: Binding<Color> {
        Binding(
            get: { Color(hex: settings.clipColorAccentHex) ?? .pink },
            set: { settings.clipColorAccentHex = NSColor($0).hexString }
        )
    }

    private func settingToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        SettingSwitchRow(title: title, isOn: isOn)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
    }

    private var retentionSliderValue: Binding<Double> {
        Binding(
            get: { settings.historyRetention.sliderIndex },
            set: { settings.historyRetention = HistoryRetention(sliderIndex: $0) }
        )
    }

    private func settingRow<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        LabeledContent(title, content: content)
            .font(.system(size: 14))
            .padding(.vertical, 10)
    }

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
        panel.message = "Pesty-Alvie will use this app when opening \(target.title.lowercased()) from an inline preview."
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

    private func applicationName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url) else { return bundleID }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundleID
    }

    private func settingsGroup<Content: View>(_ title: String,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 17, weight: .semibold))
            content()
        }
    }

    private func settingCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08))
            }
    }
}

private struct PrivacySettings: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsFormGroup("Excluded Apps") {
                    SettingsSurface {
                        Text("Pesty-Alvie will not save anything copied while one of these apps is the source. This is useful for password managers such as 1Password.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.bottom, settings.ignoredSourceAppBundleIDs.isEmpty ? 12 : 8)

                        if settings.ignoredSourceAppBundleIDs.isEmpty {
                            ContentUnavailableView("No apps excluded",
                                                   systemImage: "hand.raised",
                                                   description: Text("Add an app to keep its copied content out of Pesty-Alvie."))
                            .font(.system(size: 12))
                            .padding(.vertical, 14)
                            // The surface is a leading-aligned stack; without
                            // a full-width frame the empty state hugs its own
                            // widest line and sits left of the card's center.
                            .frame(maxWidth: .infinity)
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
                        SettingSwitchRow(title: "Ignore concealed clipboard content", isOn: $settings.ignoreConcealed)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Pesty-Alvie also respects the standard macOS concealed-clipboard marker used by password managers.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 8)
                    }
                }

                SettingsFormGroup("Sleep & Lid") {
                    SettingsSurface {
                        SettingSwitchRow(title: "Pause clipboard capture while the Mac sleeps",
                                         isOn: $settings.pauseClipboardCaptureDuringSleep)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("When enabled, clipboard changes made while the Mac is asleep are not added to history. Closing a Mac laptop’s lid usually puts it to sleep.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 8)
                    }
                }
            }
            .frame(maxWidth: 548, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
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
        panel.title = "Exclude Apps from Pesty-Alvie"
        panel.message = "Pesty-Alvie will ignore copied content from the apps you choose."
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

    private func applicationName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url) else { return bundleID }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundleID
    }
}

private struct ShortcutsSettings: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsFormGroup("Open Pesty-Alvie") {
                    SettingsSurface {
                        LabeledContent("Show the Pesty-Alvie bar") {
                            HotkeyRecorderView(keyCode: $settings.hotkeyKeyCode,
                                               modifiers: $settings.hotkeyModifiers)
                        }
                        .font(.system(size: 14))
                        .padding(.vertical, 9)
                    }
                }

                SettingsFormGroup("Quick Paste") {
                    SettingsSurface {
                        VStack(spacing: 0) {
                            LabeledContent("Paste items 1–9") {
                                HStack(spacing: 6) {
                                    ShortcutModifierPicker(selection: $settings.quickPasteModifier)
                                    Text("+ 1…9").foregroundStyle(.secondary)
                                }
                            }
                            .font(.system(size: 14))
                            .padding(.vertical, 10)
                            Divider()
                            LabeledContent("Paste as plain text") {
                                ShortcutModifierPicker(selection: $settings.plainTextModifier)
                            }
                            .font(.system(size: 14))
                            .padding(.vertical, 10)
                        }
                        Text("Hold the plain-text modifier while using Quick Paste to remove formatting. With the defaults, ⌘⇧1 pastes the first item as plain text.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.bottom, 8)
                    }
                }

                SettingsFormGroup("Paste Stack") {
                    SettingsSurface {
                        SettingSwitchRow(title: "Enable Paste Stacks", isOn: $settings.pasteStacksEnabled)
                            .padding(.vertical, 10)
                        if settings.pasteStacksEnabled {
                            Divider()
                            LabeledContent("Paste next stack item") {
                                HotkeyRecorderView(keyCode: $settings.sequenceHotkeyKeyCode,
                                                   modifiers: $settings.sequenceHotkeyModifiers)
                            }
                            .font(.system(size: 14))
                            .padding(.vertical, 9)
                            Divider()
                            SettingSwitchRow(title: "Paste newest stack item first", isOn: $settings.stackPasteInReverse)
                                .padding(.vertical, 10)
                            Divider()
                            SettingSwitchRow(title: "Keep pasted items in the stack", isOn: $settings.keepPastedStackItems)
                                .padding(.vertical, 10)
                            Divider()
                            SettingSwitchRow(title: "Remove saved stacks with clipboard history", isOn: $settings.pasteStacksFollowHistory)
                                .padding(.vertical, 10)
                            Text("Start a Paste Stack, then copy clips in any app to add them automatically. Keep pasted items enabled to re-add completed clips later.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 5)
                                .padding(.bottom, 8)
                        } else {
                            Text("Paste Stack tabs, cards, collection, and its global shortcut are off. Existing stacks are kept and return if you enable the feature again.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 5)
                                .padding(.bottom, 8)
                        }
                    }
                }

            }
            .frame(maxWidth: 548, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

private struct ExtensionsSettings: View {
    @Bindable private var catalog = ExtensionCatalog.shared
    @State private var source = ""
    @State private var installError: String?
    @State private var uninstallCandidate: InstalledExtension?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsFormGroup("About Extensions") {
                    SettingsSurface {
                        Text("Extensions are JavaScript snippets that decorate clip cards and can add explicit transformed-paste actions. While enabled, they run inside Pesty-Alvie and receive only the type and text of clips.")
                            .font(.system(size: 13))
                            .padding(.vertical, 10)
                        Divider()
                        Label("No network or file access", systemImage: "lock.shield")
                            .font(.caption.weight(.medium))
                            .padding(.top, 9)
                        Text("Extensions are off by default. Install scripts only from sources you trust.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 5)
                            .padding(.bottom, 9)
                    }
                }

                SettingsFormGroup("Installed") {
                    SettingsSurface {
                        if catalog.extensions.isEmpty {
                            ContentUnavailableView(
                                "No extensions installed",
                                systemImage: "puzzlepiece.extension",
                                description: Text("Paste an extension script below to install it.")
                            )
                            .font(.system(size: 12))
                            .padding(.vertical, 18)
                            .frame(maxWidth: .infinity)
                        } else {
                            ForEach(catalog.extensions) { installedExtension in
                                if installedExtension.id != catalog.extensions.first?.id {
                                    Divider()
                                }
                                extensionRow(installedExtension)
                            }
                        }
                    }
                }

                SettingsFormGroup("Install Extension") {
                    SettingsSurface {
                        TextEditor(text: $source)
                            .font(.system(size: 12, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 120)
                            .padding(8)
                            .background(
                                Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(.primary.opacity(0.12))
                            }
                            .padding(.top, 12)
                            .accessibilityLabel("Extension JavaScript")
                            .onChange(of: source) { _, _ in installError = nil }

                        Text("Installation runs the script once to validate it, with a strict time limit.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)

                        if let installError {
                            Label(installError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.top, 7)
                        }

                        HStack {
                            Spacer()
                            Button("Install Extension") { install() }
                                .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(.vertical, 10)
                    }
                }
            }
            .frame(maxWidth: 548, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .confirmationDialog(
            "Uninstall \(uninstallCandidate?.manifest.name ?? "extension")?",
            isPresented: Binding(
                get: { uninstallCandidate != nil },
                set: { if !$0 { uninstallCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let uninstallCandidate {
                Button("Uninstall", role: .destructive) {
                    catalog.uninstall(id: uninstallCandidate.id)
                    self.uninstallCandidate = nil
                }
            }
            Button("Cancel", role: .cancel) { uninstallCandidate = nil }
        } message: {
            Text("The extension and its script will be removed. The script text is lost unless you kept a copy.")
        }
    }

    private func extensionRow(_ installedExtension: InstalledExtension) -> some View {
        let isQuarantined = catalog.isQuarantined(installedExtension.id)
        let showsQuarantineWarning = isQuarantined || installedExtension.autoDisabledAt != nil

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(installedExtension.manifest.name)
                        .font(.system(size: 13, weight: .medium))
                    Text("Version \(installedExtension.manifest.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if installedExtension.isBundled {
                        Text("Bundled")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.primary.opacity(0.06), in: Capsule())
                    }
                }
                Text(installedExtension.id)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(installedExtension.manifest.effectiveHooks, id: \.self) { hook in
                        Text(hook.capitalized)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.primary.opacity(0.06), in: Capsule())
                            .accessibilityLabel("\(hook) hook")
                    }
                }
                .padding(.top, 2)
                if showsQuarantineWarning {
                    Label(
                        "Turned off after repeated failures or a timeout",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 8) {
                Toggle(
                    "Enable \(installedExtension.manifest.name)",
                    isOn: Binding(
                        get: { installedExtension.enabled },
                        set: { catalog.setEnabled($0, id: installedExtension.id) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Enable \(installedExtension.manifest.name)")

                Button("Uninstall", role: .destructive) {
                    uninstallCandidate = installedExtension
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func install() {
        switch catalog.install(source: source) {
        case .success:
            source = ""
            installError = nil
        case .failure(let error):
            installError = error.userDescription
        }
    }
}

private struct SyncSettings: View {
    @Bindable private var settings = Settings.shared
    #if MAS
    @Bindable private var cloudSync = CloudSyncService.shared
    @State private var isConfirmingAccountChange = false
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                #if MAS
                SettingsFormGroup("iCloud") {
                    SettingsSurface {
                        SettingSwitchRow(title: "Sync with iPhone, iPad, and Mac", isOn: Binding(
                            get: { settings.cloudKitSync },
                            set: { _ in AppController.shared.toggleCloudKitSync() }))
                            .padding(.vertical, 10)
                        Divider()
                        HStack {
                            Label(cloudSync.status, systemImage: "icloud")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Sync Now") { cloudSync.refreshNow() }
                                .disabled(!settings.cloudKitSync)
                        }
                        .padding(.vertical, 10)
                        Text("Uses your private iCloud database. Pesty-Alvie never places clipboard content in the public database or application logs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 8)
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Existing Mac Library")
                                Text("Merge history from the direct-download Mac app without replacing newer items.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Import…") {
                                AppController.shared.importExistingLibraryAndSync()
                            }
                        }
                        .padding(.vertical, 10)
                        if cloudSync.requiresAccountConfirmation {
                            Divider()
                            Button("Use Current iCloud Account…") {
                                isConfirmingAccountChange = true
                            }
                            .padding(.vertical, 10)
                        }
                    }
                }
                #else
                SettingsFormGroup("iCloud Drive") {
                    SettingsSurface {
                    SettingSwitchRow(title: "Sync clipboard via iCloud Drive", isOn: Binding(
                            get: { settings.iCloudSync },
                            set: { _ in AppController.shared.toggleICloudSync() }))
                        .padding(.vertical, 10)
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
            .frame(maxWidth: 548, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        #if MAS
        .confirmationDialog(
            "Use the current iCloud account?",
            isPresented: $isConfirmingAccountChange,
            titleVisibility: .visible
        ) {
            Button("Use Account and Upload Local Library") {
                cloudSync.confirmAccountChangeKeepingLocalLibrary()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current local Pesty-Alvie library will be uploaded to this iCloud account. Nothing from the previous account is fetched or changed.")
        }
        #endif
    }
}

private struct SettingsFormGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 16, weight: .semibold))
            content
        }
    }
}

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

private struct ShortcutModifierPicker: View {
    @Binding var selection: Int

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(ShortcutModifier.allCases) { modifier in
                Text("\(modifier.symbol) \(modifier.title)").tag(modifier.carbonValue)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 118)
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable().frame(width: 88, height: 88)
            Text("Pesty-Alvie").font(.system(size: 26, weight: .bold))
            Text("Version \(Bundle.main.appVersion)")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("A free, open-source clipboard manager for macOS.\nInspired by Paste.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            HStack(spacing: 16) {
                Link("Fork on GitHub", destination: URL(string: "https://github.com/momenbasel/pesty")!)
                Link("Report an Issue", destination: URL(string: "https://github.com/momenbasel/pesty/issues")!)
            }
            .padding(.top, 4)
            Button("Quit Pesty-Alvie", role: .destructive) {
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

/// A switch row whose label text is as clickable as the switch itself.
private struct SettingSwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { isOn.toggle() }
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}
