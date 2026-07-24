import SwiftUI
import AppKit

struct SettingsView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case general
        case privacy
        case about

        var id: Self { self }

        var title: String {
            switch self {
            case .general: "General"
            case .privacy: "Privacy"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .privacy: "hand.raised"
            case .about: "info.circle"
            }
        }
    }

    @State private var section: Section = .general

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable()
                        .frame(width: 30, height: 30)
                    Text("Pesty")
                        .font(.headline)
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 14)

                ForEach(Section.allCases) { item in
                    Button {
                        section = item
                    } label: {
                        Label(item.title, systemImage: item.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(section == item ? .primary : .secondary)
                    .background {
                        if section == item {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.quaternary)
                        }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(width: 180)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Group {
                switch section {
                case .general:
                    GeneralSettings()
                case .privacy:
                    PrivacySettings()
                case .about:
                    AboutView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 680, height: 560)
    }
}

private struct PrivacySettings: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        Form {
            Section("Excluded Apps") {
                Text("Pesty will not save anything copied while one of these apps is active. This is useful for password managers such as 1Password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.ignoredSourceAppBundleIDs.isEmpty {
                    ContentUnavailableView("No apps excluded",
                                           systemImage: "hand.raised",
                                           description: Text("Add an app to keep its copied content out of Pesty."))
                        .padding(.vertical, 12)
                } else {
                    ForEach(settings.ignoredSourceAppBundleIDs, id: \.self) { bundleID in
                        ignoredAppRow(bundleID)
                    }
                }

                Button { chooseApps() } label: {
                    Label("Add App…", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
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
        .padding(.vertical, 4)
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

private struct GeneralSettings: View {
    @Bindable private var settings = Settings.shared
    #if !MAS
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var requestedGrant = false

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    #endif

    var body: some View {
        Form {
            Section("Activation") {
                LabeledContent("Show Pesty") { HotkeyRecorderView() }
            }

            Section("History") {
                Picker("Keep history by", selection: $settings.historyRetentionMode) {
                    ForEach(HistoryRetentionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if settings.historyRetentionMode == .itemCount {
                    Stepper(value: $settings.historyLimit, in: 50...5000, step: 50) {
                        LabeledContent("Number of clips", value: "\(settings.historyLimit) items")
                    }
                    Text("Pesty keeps the most recent \(settings.historyLimit) clips.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text("Keep clips for")
                            Spacer()
                            Text(settings.historyRetention.title)
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.accentColor)
                        }
                        Slider(value: retentionSliderValue,
                               in: 0...Double(HistoryRetention.allCases.count - 1),
                               step: 1)
                        HStack(spacing: 0) {
                            ForEach(HistoryRetention.allCases) { retention in
                                Text(retention.shortSliderTitle)
                                    .font(.caption2.weight(retention == settings.historyRetention ? .bold : .medium))
                                    .foregroundStyle(retention == settings.historyRetention ? Color.accentColor : .secondary)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    Text(settings.historyRetention.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Quick Paste") {
                LabeledContent("Paste items 1–9") {
                    HStack(spacing: 6) {
                        modifierPicker(selection: $settings.quickPasteModifier)
                        Text("+ 1…9").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Paste as plain text") {
                    modifierPicker(selection: $settings.plainTextModifier)
                }
                Text("Hold the plain-text modifier while using Quick Paste to remove formatting. For example, ⌘⇧1 pastes the first item as plain text with the default shortcuts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Behavior") {
                #if !MAS
                Toggle("Paste directly into the active app", isOn: $settings.pasteDirectly)
                    .toggleStyle(.switch)
                #endif
                Toggle("Ignore passwords (concealed clips)", isOn: $settings.ignoreConcealed)
                    .toggleStyle(.switch)
                Toggle("Play sound on paste", isOn: $settings.playSound)
                    .toggleStyle(.switch)
                Toggle("Hide Pesty when clicking outside", isOn: $settings.hideOnClickOutside)
                    .toggleStyle(.switch)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    .toggleStyle(.switch)
                Toggle("Show resize handle on the Pesty bar", isOn: $settings.showBarResizeHandle)
                    .toggleStyle(.switch)
                Toggle("Show Pesty in the menu bar", isOn: $settings.showMenuBarIcon)
                    .toggleStyle(.switch)
                VStack(alignment: .leading) {
                    LabeledContent("Bar height", value: "\(Int(settings.barHeight)) px")
                    Slider(value: $settings.barHeight, in: 300...720, step: 10)
                }
                #if MAS
                Text("Select a clip to copy it, then press ⌘V to paste it into your app.")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
            }

            Section("Clip previews") {
                Picker("Preview style", selection: $settings.clipPreviewStyle) {
                    ForEach(ClipPreviewStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                Text(settings.clipPreviewStyle.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sync") {
                Toggle("Sync clipboard via iCloud Drive", isOn: Binding(
                    get: { settings.iCloudSync },
                    set: { _ in AppController.shared.toggleICloudSync() }))
                    .toggleStyle(.switch)
                Text(ClipboardStore.shared.iCloudAvailable
                     ? "Keeps your history and pinboards in sync across your Macs through iCloud Drive."
                     : "Sign in to iCloud and enable iCloud Drive to use sync.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            #if !MAS
            Section("Permissions") {
                HStack(spacing: 10) {
                    Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(accessibilityGranted ? .green : .orange)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility")
                        Text(accessibilityGranted
                             ? "Granted — direct paste is enabled."
                             : (requestedGrant
                                ? "Waiting… toggle Pesty on in System Settings."
                                : "Required to paste directly into other apps."))
                            .font(.caption)
                            .foregroundStyle(accessibilityGranted ? .green : .secondary)
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
            #endif

            Section("Data") {
                Button("Clear Clipboard History", role: .destructive) {
                    ClipboardStore.shared.clearHistory()
                }
            }
        }
        .formStyle(.grouped)
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

    private var retentionSliderValue: Binding<Double> {
        Binding(
            get: { settings.historyRetention.sliderIndex },
            set: { settings.historyRetention = HistoryRetention(sliderIndex: $0) }
        )
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
