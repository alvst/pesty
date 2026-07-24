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
        case .shortcuts: "Keyboard controls for Pesty and Paste Stack"
        case .sync: "Keep your clipboard history available on every Mac"
        case .about: "Pesty for macOS"
        }
    }
    var symbol: String {
        switch self { case .general: "gearshape"; case .privacy: "hand.raised"; case .shortcuts: "keyboard"; case .sync: "icloud"; case .about: "info.circle" }
    }
}

private struct GeneralSettings: View {
    @Bindable private var settings = Settings.shared
    #if !MAS
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var requestedGrant = false

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    #endif

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
                                Text("Pesty keeps the most recent \(settings.historyLimit) clips.")
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

                settingsGroup("Behavior") {
                    settingCard {
                        VStack(alignment: .leading, spacing: 0) {
                            #if !MAS
                            settingToggle("Paste directly into the active app", isOn: $settings.pasteDirectly)
                            Divider()
                            #endif
                            settingToggle("Play sound on paste", isOn: $settings.playSound)
                            Divider()
                            settingToggle("Hide Pesty when clicking outside", isOn: $settings.hideOnClickOutside)
                            Divider()
                            settingToggle("Launch at login", isOn: $settings.launchAtLogin)
                            Divider()
                            settingToggle("Show resize handle on the Pesty bar", isOn: $settings.showBarResizeHandle)
                            Divider()
                            settingToggle("Show Pesty in the menu bar", isOn: $settings.showMenuBarIcon)
                            Divider()
                            VStack(alignment: .leading, spacing: 8) {
                                LabeledContent("Bar height", value: "\(Int(settings.barHeight)) px")
                                    .font(.system(size: 14))
                                Slider(value: $settings.barHeight, in: 300...720, step: 10)
                            }
                            .padding(.vertical, 12)
                        }
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
                                Button("Restart Pesty") { AppController.restart() }
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
                        Text("Pesty will not save anything copied while one of these apps is the source. This is useful for password managers such as 1Password.")
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
                        Toggle("Ignore concealed clipboard content", isOn: $settings.ignoreConcealed)
                            .font(.system(size: 14))
                            .toggleStyle(.switch)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Pesty also respects the standard macOS concealed-clipboard marker used by password managers.")
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
                SettingsFormGroup("Open Pesty") {
                    SettingsSurface {
                        LabeledContent("Show the Pesty bar") {
                            HotkeyRecorderView(keyCode: $settings.hotkeyKeyCode,
                                               modifiers: $settings.hotkeyModifiers)
                        }
                        .font(.system(size: 14))
                        .padding(.vertical, 9)
                    }
                }

                SettingsFormGroup("Paste Stack") {
                    SettingsSurface {
                        LabeledContent("Paste next stack item") {
                            HotkeyRecorderView(keyCode: $settings.sequenceHotkeyKeyCode,
                                               modifiers: $settings.sequenceHotkeyModifiers)
                        }
                        .font(.system(size: 14))
                        .padding(.vertical, 9)
                        Divider()
                        Toggle("Paste newest stack item first", isOn: $settings.stackPasteInReverse)
                            .font(.system(size: 14))
                            .toggleStyle(.switch)
                            .padding(.vertical, 10)
                        Divider()
                        Toggle("Keep pasted items in the stack", isOn: $settings.keepPastedStackItems)
                            .font(.system(size: 14))
                            .toggleStyle(.switch)
                            .padding(.vertical, 10)
                        Divider()
                        Toggle("Remove saved stacks with clipboard history", isOn: $settings.pasteStacksFollowHistory)
                            .font(.system(size: 14))
                            .toggleStyle(.switch)
                            .padding(.vertical, 10)
                        Text("Start a Paste Stack, then copy clips in any app to add them automatically. Keep pasted items enabled to re-add completed clips later.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 5)
                            .padding(.bottom, 8)
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
            }
            .frame(maxWidth: 548, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

private struct SyncSettings: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsFormGroup("iCloud Drive") {
                    SettingsSurface {
                    Toggle("Sync clipboard via iCloud Drive", isOn: Binding(
                            get: { settings.iCloudSync },
                            set: { _ in AppController.shared.toggleICloudSync() }))
                        .font(.system(size: 14))
                        .toggleStyle(.switch)
                        .padding(.vertical, 10)
                        Text(ClipboardStore.shared.iCloudAvailable
                             ? "Keeps your history and pinboards in sync across your Macs through iCloud Drive."
                             : "Sign in to iCloud and enable iCloud Drive to use sync.")
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
