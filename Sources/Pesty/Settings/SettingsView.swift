import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 620, height: 720)
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
                settingsGroup("Activation") {
                    settingCard {
                        settingRow("Show Pesty") { HotkeyRecorderView() }
                    }
                }

                settingsGroup("Keep History") {
                    settingCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Picker("Keep history", selection: $settings.historyRetention) {
                                ForEach(HistoryRetention.allCases) { retention in
                                    Text(retention.title).tag(retention)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            Text(settings.historyRetention.description)
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

                settingsGroup("Quick Paste") {
                    settingCard {
                        VStack(spacing: 0) {
                            settingRow("Paste items 1–9") {
                                HStack(spacing: 6) {
                                    modifierPicker(selection: $settings.quickPasteModifier)
                                    Text("+ 1…9").foregroundStyle(.secondary)
                                }
                            }
                            Divider()
                            settingRow("Paste as plain text") {
                                modifierPicker(selection: $settings.plainTextModifier)
                            }
                        }
                        Text("Hold the plain-text modifier while using Quick Paste to remove formatting. With the defaults, ⌘⇧1 pastes the first item as plain text.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.top, 12)
                    }
                }

                settingsGroup("Behavior") {
                    settingCard {
                        VStack(spacing: 0) {
                            #if !MAS
                            settingToggle("Paste directly into the active app", isOn: $settings.pasteDirectly)
                            Divider()
                            #endif
                            settingToggle("Ignore passwords", isOn: $settings.ignoreConcealed)
                            Divider()
                            settingToggle("Play sound on paste", isOn: $settings.playSound)
                            Divider()
                            settingToggle("Hide Pesty when clicking outside", isOn: $settings.hideOnClickOutside)
                            Divider()
                            settingToggle("Launch at login", isOn: $settings.launchAtLogin)
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

                settingsGroup("Sync") {
                    settingCard {
                        Toggle("Sync clipboard via iCloud Drive", isOn: Binding(
                            get: { settings.iCloudSync },
                            set: { _ in AppController.shared.toggleICloudSync() }))
                        Text(ClipboardStore.shared.iCloudAvailable
                             ? "Keeps your history and pinboards in sync across your Macs through iCloud Drive."
                             : "Sign in to iCloud and enable iCloud Drive to use sync.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.top, 8)
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
            .padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    private func modifierPicker(selection: Binding<Int>) -> some View {
        Picker("", selection: selection) {
            ForEach(ShortcutModifier.allCases) { modifier in
                Text("\(modifier.symbol) \(modifier.title)").tag(modifier.carbonValue)
            }
        }
        .labelsHidden().pickerStyle(.menu).frame(minWidth: 118)
    }

    private func settingToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .font(.system(size: 14))
            .padding(.vertical, 10)
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
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
