import SwiftUI
import AppKit

struct SettingsView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case general
        case about

        var id: Self { self }

        var title: String {
            switch self {
            case .general: "General"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
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
                case .about:
                    AboutView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 680, height: 560)
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

            Section("Behavior") {
                #if !MAS
                Toggle("Paste directly into the active app", isOn: $settings.pasteDirectly)
                #endif
                Toggle("Ignore passwords (concealed clips)", isOn: $settings.ignoreConcealed)
                Toggle("Play sound on paste", isOn: $settings.playSound)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Show resize handle on the Pesty bar", isOn: $settings.showBarResizeHandle)
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
            Spacer()
            Text("MIT Licensed · Made with SwiftUI")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
