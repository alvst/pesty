import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Observation

struct SettingsView: View {
    @State private var section: SettingsSection
    @State private var settingsSearchText = ""
    @State private var searchTarget: SettingsSearchTarget?
    @FocusState private var settingsSearchFocused: Bool

    init(initialSection: SettingsSection = .general) {
        _section = State(initialValue: initialSection)
    }

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
            .simultaneousGesture(
                TapGesture().onEnded { settingsSearchFocused = false }
            )
        }
        .frame(width: 760, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .pestyShowExtensionSettings)) { _ in
            section = .extensions
        }
        .onAppear {
            DispatchQueue.main.async {
                settingsSearchFocused = false
            }
        }
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

            ZStack(alignment: .trailing) {
                TextField("Search settings", text: $settingsSearchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($settingsSearchFocused)
                    .padding(.trailing, settingsSearchText.isEmpty ? 0 : 20)
                if !settingsSearchText.isEmpty {
                    Button {
                        settingsSearchText = ""
                        searchTarget = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear settings search")
                    .padding(.trailing, 5)
                }
            }
            .padding(.bottom, 8)

            if normalizedSearchQuery.isEmpty {
                ForEach(SettingsSection.allCases) { item in
                    Button {
                        section = item
                        settingsSearchFocused = false
                    } label: {
                        Label(item.title, systemImage: item.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(section == item ? Color.accentColor.opacity(0.16) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            } else if searchResults.isEmpty {
                ContentUnavailableView.search(text: normalizedSearchQuery)
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(searchResults) { result in
                            Button { openSearchResult(result) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(2)
                                    Label(result.section.title, systemImage: result.section.symbol)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Text("Pesty \(Bundle.main.appVersion)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 174)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background {
            Color(nsColor: .controlBackgroundColor)
                .contentShape(Rectangle())
                .onTapGesture { settingsSearchFocused = false }
        }
    }

    private var normalizedSearchQuery: String {
        settingsSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchResults: [SettingsSearchItem] {
        SettingsSearchIndex.results(for: normalizedSearchQuery)
    }

    private func openSearchResult(_ result: SettingsSearchItem) {
        section = result.section
        searchTarget = SettingsSearchTarget(section: result.section, anchor: result.anchor)
        settingsSearchFocused = false
    }

    private func target(for targetSection: SettingsSection) -> SettingsSearchTarget? {
        searchTarget?.section == targetSection ? searchTarget : nil
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .general: GeneralSettings(searchTarget: target(for: .general))
        case .icons: SourceIconSettings()
        case .privacy: PrivacySettings(searchTarget: target(for: .privacy))
        case .shortcuts: ShortcutsSettings(searchTarget: target(for: .shortcuts))
        case .extensions: ExtensionsSettings(searchTarget: target(for: .extensions))
        case .sync: SyncSettings(searchTarget: target(for: .sync))
        case .about: AboutView()
        }
    }
}

enum SettingsSection: CaseIterable, Identifiable {
    case general, icons, privacy, shortcuts, extensions, sync, about
    var id: Self { self }
    var title: String {
        switch self { case .general: "General"; case .icons: "Icons"; case .privacy: "Privacy"; case .shortcuts: "Shortcuts"; case .extensions: "Extensions"; case .sync: "Sync"; case .about: "About" }
    }
    var subtitle: String {
        switch self {
        case .general: "History, behavior, and app preferences"
        case .icons: "Choose the icons used for source applications"
        case .privacy: "Keep clips from selected apps out of Pesty"
        case .shortcuts: "Keyboard controls for Pesty and Paste Stack"
        case .extensions: "Manage scripts that decorate clips and transform paste"
        case .sync: "Keep your clipboard library available across your devices"
        case .about: "Pesty for macOS"
        }
    }
    var symbol: String {
        switch self { case .general: "gearshape"; case .icons: "photo"; case .privacy: "hand.raised"; case .shortcuts: "keyboard"; case .extensions: "puzzlepiece.extension"; case .sync: "icloud"; case .about: "info.circle" }
    }
}

struct SettingsSearchTarget: Equatable {
    let id = UUID()
    let section: SettingsSection
    let anchor: String
}

struct SettingsSearchItem: Identifiable {
    let id: String
    let title: String
    let section: SettingsSection
    let anchor: String
    let keywords: String

    init(_ id: String, _ title: String, section: SettingsSection,
         anchor: String, keywords: String = "") {
        self.id = id
        self.title = title
        self.section = section
        self.anchor = anchor
        self.keywords = keywords
    }

    var searchableText: String {
        "\(title) \(section.title) \(section.subtitle) \(keywords)"
    }
}

enum SettingsSearchIndex {
    static let items: [SettingsSearchItem] = [
        .init("history-mode", "Keep history by number or time", section: .general,
              anchor: "general.history", keywords: "retention clips limit days weeks months forever"),
        .init("history-limit", "Number of clips", section: .general,
              anchor: "general.history", keywords: "history item count maximum stored"),
        .init("history-delete", "Delete permanently", section: .general,
              anchor: "general.history", keywords: "undo recover erase remove history option"),
        .init("history-erase", "Erase saved clips now", section: .general,
              anchor: "general.history", keywords: "clear delete history storage"),
        .init("paste-direct", "Paste directly into the active app", section: .general,
              anchor: "general.pasting", keywords: "accessibility automatic insert"),
        .init("paste-plain", "Always paste as plain text", section: .general,
              anchor: "general.pasting", keywords: "remove formatting unformatted"),
        .init("paste-promote", "Move pasted clips to the top of history", section: .general,
              anchor: "general.pasting", keywords: "recent reorder"),
        .init("paste-sounds", "Play sounds when copying or pasting", section: .general,
              anchor: "general.pasting", keywords: "audio sound copy paste"),
        .init("paste-import", "Import from Paste", section: .general,
              anchor: "general.import", keywords: "library history pinboards images migrate"),
        .init("window-hide", "Hide when clicking outside", section: .general,
              anchor: "general.appearance", keywords: "window dismiss close"),
        .init("window-sharing", "Show during screen sharing", section: .general,
              anchor: "general.appearance", keywords: "recording presentation privacy window"),
        .init("launch-login", "Launch at login", section: .general,
              anchor: "general.appearance", keywords: "startup open automatically"),
        .init("card-style", "Paste-style clip cards", section: .general,
              anchor: "general.appearance", keywords: "appearance design layout"),
        .init("bar-resize", "Show resize handle on the bar", section: .general,
              anchor: "general.appearance", keywords: "window size height drag"),
        .init("menu-bar", "Show Pesty in the menu bar", section: .general,
              anchor: "general.appearance", keywords: "status icon menubar"),
        .init("bar-height", "Bar height", section: .general,
              anchor: "general.appearance", keywords: "window size pixels resize"),
        .init("clip-colors", "Clip color theme", section: .general,
              anchor: "general.colors", keywords: "card colors accent source app shades"),
        .init("clip-base-color", "Base color for accent shades", section: .general,
              anchor: "general.colors", keywords: "color picker card theme"),
        .init("clip-position", "Selected clip position", section: .general,
              anchor: "general.navigation", keywords: "navigation center left selection"),
        .init("preview-style", "Clip preview style", section: .general,
              anchor: "general.previews", keywords: "native inline window quick look rich preview"),
        .init("link-preview", "Generate link previews", section: .general,
              anchor: "general.previews", keywords: "website metadata url network"),
        .init("open-text", "Open text and rich text with", section: .general,
              anchor: "general.open-with", keywords: "textedit preview application default"),
        .init("open-images", "Open images with", section: .general,
              anchor: "general.open-with", keywords: "pictures photos preview application default"),
        .init("open-links", "Open links with", section: .general,
              anchor: "general.open-with", keywords: "browser safari website url application default"),
        .init("open-defaults", "Restore default preview applications", section: .general,
              anchor: "general.open-with", keywords: "apple reset open clips with"),
        .init("accessibility", "Accessibility permission", section: .general,
              anchor: "general.accessibility", keywords: "system settings direct paste approval"),

        .init("source-icons", "Source app icons", section: .icons,
              anchor: "icons.source-apps", keywords: "custom choose reset light dark card colors application"),

        .init("excluded-apps", "Exclude apps from clipboard history", section: .privacy,
              anchor: "privacy.excluded-apps", keywords: "ignore source applications password manager 1password"),
        .init("concealed", "Ignore concealed clipboard content", section: .privacy,
              anchor: "privacy.concealed", keywords: "password passwords secret hidden marker password manager"),
        .init("confidential", "Ignore confidential content", section: .privacy,
              anchor: "privacy.clipboard", keywords: "password passwords secret private pasteboard marker"),
        .init("transient", "Ignore transient content", section: .privacy,
              anchor: "privacy.clipboard", keywords: "temporary app generated pasteboard marker"),
        .init("sleep", "Pause clipboard capture while the Mac sleeps", section: .privacy,
              anchor: "privacy.sleep", keywords: "lid closed wake history"),

        .init("open-shortcut", "Shortcut to show the Pesty bar", section: .shortcuts,
              anchor: "shortcuts.open", keywords: "hotkey keyboard open"),
        .init("quick-paste", "Quick Paste items 1–9", section: .shortcuts,
              anchor: "shortcuts.quick-paste", keywords: "keyboard shortcut hotkey plain text pinboard"),
        .init("paste-stack", "Enable Paste Stacks", section: .shortcuts,
              anchor: "shortcuts.paste-stack", keywords: "sequence queue collection shortcut next newest keep saved"),
        .init("paste-stack-next", "Shortcut to paste the next stack item", section: .shortcuts,
              anchor: "shortcuts.paste-stack", keywords: "sequence queue hotkey keyboard"),
        .init("paste-stack-order", "Paste newest stack item first", section: .shortcuts,
              anchor: "shortcuts.paste-stack", keywords: "reverse order sequence"),
        .init("paste-stack-keep", "Keep pasted items in the stack", section: .shortcuts,
              anchor: "shortcuts.paste-stack", keywords: "retain readd completed clips"),
        .init("paste-stack-history", "Remove saved stacks with clipboard history", section: .shortcuts,
              anchor: "shortcuts.paste-stack", keywords: "delete clear erase clips"),

        .init("extensions-about", "About extensions", section: .extensions,
              anchor: "extensions.about", keywords: "javascript scripts transform paste decorate security network file access"),
        .init("extensions-installed", "Installed extensions", section: .extensions,
              anchor: "extensions.installed", keywords: "enable disable uninstall scripts plugins"),
        .init("extensions-install", "Install an extension", section: .extensions,
              anchor: "extensions.install", keywords: "javascript script add validate"),

        .init("sync", "Sync clipboard library", section: .sync,
              anchor: "sync.icloud", keywords: "icloud drive cloudkit iphone ipad mac history pinboards"),
        .init("sync-now", "Sync now", section: .sync,
              anchor: "sync.icloud", keywords: "refresh upload download cloud"),
        .init("sync-import", "Import existing Mac library", section: .sync,
              anchor: "sync.icloud", keywords: "merge history direct download migrate"),

        .init("about", "About Pesty", section: .about,
              anchor: "about", keywords: "version github issue license quit")
    ]

    static func results(for query: String) -> [SettingsSearchItem] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }
        let queryWords = normalizedQuery.split(separator: " ").map(String.init)
        return items
            .filter { item in
                let words = normalize(item.searchableText).split(separator: " ").map(String.init)
                return queryWords.allSatisfy { queryWord in
                    words.contains { wordMatches(queryWord, candidate: $0) }
                }
            }
            .sorted { score($0, query: normalizedQuery) > score($1, query: normalizedQuery) }
    }

    private static func score(_ item: SettingsSearchItem, query: String) -> Int {
        let title = normalize(item.title)
        let section = normalize(item.section.title)
        if title == query { return 400 }
        if title.hasPrefix(query) { return 300 }
        if title.contains(query) { return 200 }
        if section == query { return 150 }
        return 100
    }

    private static func normalize(_ value: String) -> String {
        let characters = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(characters)
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static func wordMatches(_ query: String, candidate: String) -> Bool {
        if candidate.contains(query) || query.contains(candidate) { return true }
        guard query.count >= 4, abs(query.count - candidate.count) <= 3 else { return false }
        let tolerance = query.count >= 8 ? 4 : (query.count >= 6 ? 2 : 1)
        return editDistance(query, candidate) <= tolerance
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous[right.count]
    }
}

private struct GeneralSettings: View {
    let searchTarget: SettingsSearchTarget?
    @Bindable private var settings = Settings.shared
    #if !MAS
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var requestedGrant = false

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    #endif

    @State private var storageBytes: Int64?
    @State private var pasteImportMessage: String?

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
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Keep history by", selection: $settings.historyRetentionMode) {
                                ForEach(HistoryRetentionMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            Text("Switching between Number and Time does not immediately delete existing clips.")
                                .font(.caption).foregroundStyle(.secondary)
                            if settings.historyRetentionMode == .itemCount {
                                Stepper(value: $settings.historyLimit, in: 10...5000, step: 10) {
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
                                Text("Currently storing")
                                    .font(.system(size: 14))
                                Spacer()
                                Text(storageSummary)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            Divider()
                            SettingSwitchRow(title: "Delete permanently", isOn: $settings.deletePermanently)
                                .padding(.vertical, 4)
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
                            .padding(.top, 6)
                            .padding(.bottom, 14)
                        }
                    }
                }
                .id("general.history")

                settingsGroup("Pasting") {
                    settingCard {
                        VStack(alignment: .leading, spacing: 0) {
                            #if !MAS
                            settingToggle("Paste directly into the active app", isOn: $settings.pasteDirectly)
                            Divider()
                            #endif
                            settingToggle("Always paste as plain text", isOn: $settings.alwaysPastePlainText)
                            Divider()
                            settingToggle("Move pasted clips to the top of history", isOn: $settings.promoteOnPaste)
                            Divider()
                            settingToggle("Play sound on paste", isOn: $settings.playSound)
                            settingToggle("Play sound on copy", isOn: $settings.playSoundOnCopy)
                        }
                    }
                }
                .id("general.pasting")

                settingsGroup("Import") {
                    settingCard {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Import from Paste")
                                    .font(.system(size: 14, weight: .medium))
                                Text("Bring in Paste history, pinboards, and supported images from its local library.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Import…") { importFromPaste() }
                        }
                        .padding(.vertical, 10)
                    }
                }
                .id("general.import")

                settingsGroup("Window & Appearance") {
                    settingCard {
                        VStack(alignment: .leading, spacing: 0) {
                            settingToggle("Hide Pesty when clicking outside", isOn: $settings.hideOnClickOutside)
                            Divider()
                            settingToggle("Show Pesty during screen sharing", isOn: $settings.showDuringScreenSharing)
                            Divider()
                            settingToggle("Launch at login", isOn: $settings.launchAtLogin)
                            Divider()
                            settingToggle("Paste-style clip cards", isOn: $settings.pasteStyleCards)
                            Divider()
                            settingToggle("Show resize handle on the Pesty bar", isOn: $settings.showBarResizeHandle)
                            Divider()
                            settingToggle("Show Pesty in the menu bar", isOn: $settings.showMenuBarIcon)
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
                .id("general.appearance")

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
                .id("general.colors")

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
                .id("general.navigation")

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
                            settingToggle("Generate link previews", isOn: $settings.generateLinkPreviews)
                            Divider()
                            Text(settings.clipPreviewStyle.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 10)
                        }
                    }
                }
                .id("general.previews")

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
                        Text("These set the one-click app in Inline Pesty previews. Use its arrow to choose a different app just once.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.bottom, 8)
                    }
                }
                .id("general.open-with")

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
                .id("general.accessibility")
                #endif
            }
            .frame(maxWidth: 548, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .settingsSearchTarget(searchTarget)
        .background(Color.clear)
        .task { await refreshStorageSize() }
        .alert("Paste Import", isPresented: Binding(get: { pasteImportMessage != nil }, set: { if !$0 { pasteImportMessage = nil } })) {
            Button("OK") { pasteImportMessage = nil }
        } message: { Text(pasteImportMessage ?? "") }
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

    private func importFromPaste() {
        let panel = NSOpenPanel()
        panel.title = "Choose Paste Library"
        panel.message = "Select Paste's db.sqlite file. Pesty reads it without modifying it."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        panel.directoryURL = PasteLibraryImporter.defaultURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: PasteLibraryImporter.defaultURL.path) {
            panel.nameFieldStringValue = PasteLibraryImporter.defaultURL.lastPathComponent
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let summary = try PasteLibraryImporter.importLibrary(from: url)
            pasteImportMessage = "Imported \(summary.history) history clips, \(summary.pinboards) pinboards, and \(summary.images) images."
        } catch {
            pasteImportMessage = error.localizedDescription
        }
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
    let searchTarget: SettingsSearchTarget?
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
                .id("privacy.excluded-apps")

                SettingsFormGroup("Concealed Clips") {
                    SettingsSurface {
                        SettingSwitchRow(title: "Ignore concealed clipboard content", isOn: $settings.ignoreConcealed)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Pesty also respects the standard macOS concealed-clipboard marker used by password managers.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 8)
                    }
                }
                .id("privacy.concealed")

                SettingsFormGroup("Clipboard Privacy") {
                    SettingsSurface {
                        SettingSwitchRow(title: "Ignore confidential content", isOn: $settings.ignoreConfidential)
                            .padding(.vertical, 10)
                        Divider()
                        SettingSwitchRow(title: "Ignore transient content", isOn: $settings.ignoreTransient)
                            .padding(.vertical, 10)
                        Text("Uses standard macOS pasteboard markers to avoid saving passwords, temporary data, and app-generated content.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 8)
                    }
                }
                .id("privacy.clipboard")

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
                .id("privacy.sleep")
            }
            .frame(maxWidth: 548, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .settingsSearchTarget(searchTarget)
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
    let searchTarget: SettingsSearchTarget?
    @Bindable private var settings = Settings.shared
    @Bindable private var hotKeys = HotKeyCenter.shared

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
                .id("shortcuts.open")

                if !hotKeys.isMainHotKeyRegistered {
                    SettingsSurface {
                        Label("The global shortcut is not registered. Choose a different combination and try again.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.system(size: 13))
                            .padding(.vertical, 10)
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
                            Divider()
                            LabeledContent("Open Pinboard 1–9 (while the bar is shown)") {
                                Text("⌘⌥1–9")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 14))
                            .padding(.vertical, 10)
                        }
                        Text("Hold the plain-text modifier while using Quick Paste to remove formatting. With the defaults, ⌘⇧1 pastes the first item as plain text. Quick Paste takes precedence if its configured shortcut is ⌘⌥.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.bottom, 8)
                    }
                }
                .id("shortcuts.quick-paste")

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
                .id("shortcuts.paste-stack")

            }
            .frame(maxWidth: 548, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .settingsSearchTarget(searchTarget)
    }
}

private struct ExtensionsSettings: View {
    let searchTarget: SettingsSearchTarget?
    @Bindable private var catalog = ExtensionCatalog.shared
    @State private var source = ""
    @State private var installError: String?
    @State private var uninstallCandidate: InstalledExtension?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsFormGroup("About Extensions") {
                    SettingsSurface {
                        Text("Extensions are JavaScript snippets that decorate clip cards and can add explicit transformed-paste actions. While enabled, they run inside Pesty and receive only the type and text of clips.")
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
                .id("extensions.about")

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
                .id("extensions.installed")

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
                .id("extensions.install")
            }
            .frame(maxWidth: 548, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .settingsSearchTarget(searchTarget)
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
        let quarantineWarning = switch installedExtension.autoDisableReason {
        case .timedOut:
            "Turned off after a timeout"
        case .repeatedExceptions:
            "Turned off after repeated failures"
        case nil:
            "Turned off after repeated failures or a timeout"
        }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
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
                            quarantineWarning,
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

            if !installedExtension.manifest.config.isEmpty {
                Divider()
                    .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(installedExtension.manifest.config) { field in
                        configRow(field, extensionID: installedExtension.id)
                    }
                }
                .padding(.leading, 2)
                .padding(.trailing, 4)
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func configRow(_ field: ExtensionConfigField, extensionID: String) -> some View {
        HStack(spacing: 12) {
            Text(field.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)

            switch field.type {
            case .boolean:
                Toggle(field.label, isOn: booleanBinding(for: field, extensionID: extensionID))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(field.label)
            case .number:
                TextField(
                    field.label,
                    value: numberBinding(for: field, extensionID: extensionID),
                    format: .number
                )
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 110)
                .accessibilityLabel(field.label)
            case .string:
                TextField(field.label, text: stringBinding(for: field, extensionID: extensionID))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 190)
                    .accessibilityLabel(field.label)
            case .choice:
                Picker(
                    field.label,
                    selection: stringBinding(for: field, extensionID: extensionID)
                ) {
                    ForEach(field.options ?? [], id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150, alignment: .trailing)
                .accessibilityLabel(field.label)
            }
        }
    }

    private func booleanBinding(
        for field: ExtensionConfigField,
        extensionID: String
    ) -> Binding<Bool> {
        Binding(
            get: {
                guard case .boolean(let value) = configValue(for: field, extensionID: extensionID)
                else { return false }
                return value
            },
            set: { catalog.setSetting(.boolean($0), forKey: field.key, id: extensionID) }
        )
    }

    private func numberBinding(
        for field: ExtensionConfigField,
        extensionID: String
    ) -> Binding<Double> {
        Binding(
            get: {
                guard case .number(let value) = configValue(for: field, extensionID: extensionID)
                else { return 0 }
                return value
            },
            set: { catalog.setSetting(.number($0), forKey: field.key, id: extensionID) }
        )
    }

    private func stringBinding(
        for field: ExtensionConfigField,
        extensionID: String
    ) -> Binding<String> {
        Binding(
            get: {
                guard case .string(let value) = configValue(for: field, extensionID: extensionID)
                else { return "" }
                return value
            },
            set: { value in
                let bounded = String(value.prefix(ExtensionConfigField.maximumStringCharacters))
                catalog.setSetting(.string(bounded), forKey: field.key, id: extensionID)
            }
        )
    }

    private func configValue(
        for field: ExtensionConfigField,
        extensionID: String
    ) -> ExtensionConfigValue {
        catalog.effectiveSettings(for: extensionID)[field.key] ?? field.defaultValue
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
    let searchTarget: SettingsSearchTarget?
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
                            .disabled(ClipboardStore.isDemo)
                        Divider()
                        HStack {
                            Label(cloudSync.status, systemImage: "icloud")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Sync Now") { cloudSync.refreshNow() }
                                .disabled(ClipboardStore.isDemo || !settings.cloudKitSync)
                        }
                        .padding(.vertical, 10)
                        Text(ClipboardStore.isDemo
                             ? "Demo mode uses an isolated local library and never connects to iCloud."
                             : "Uses your private iCloud database. Pesty never places clipboard content in the public database or application logs.")
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
                            .disabled(ClipboardStore.isDemo)
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
                        .disabled(ClipboardStore.isDemo)
                        Text(ClipboardStore.isDemo
                             ? "Demo mode uses an isolated local library and never connects to iCloud."
                             : ClipboardStore.shared.iCloudAvailable
                             ? "Keeps your history and pinboards in sync across your Macs through iCloud Drive."
                             : "Sign in to iCloud and enable iCloud Drive to use sync.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 8)
                    }
                }
                #endif
            }
            .id("sync.icloud")
            .frame(maxWidth: 548, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .settingsSearchTarget(searchTarget)
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
            Text("Your current local Pesty library will be uploaded to this iCloud account. Nothing from the previous account is fetched or changed.")
        }
        #endif
    }
}

private struct SettingsSearchScrollModifier: ViewModifier {
    let target: SettingsSearchTarget?

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .onAppear { scroll(to: target, using: proxy) }
                .onChange(of: target) { _, newTarget in
                    scroll(to: newTarget, using: proxy)
                }
        }
    }

    private func scroll(to target: SettingsSearchTarget?, using proxy: ScrollViewProxy) {
        guard let target else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(target.anchor, anchor: .top)
            }
        }
    }
}

private extension View {
    func settingsSearchTarget(_ target: SettingsSearchTarget?) -> some View {
        modifier(SettingsSearchScrollModifier(target: target))
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
                Link("Fork on GitHub", destination: URL(string: "https://github.com/alvst/pesty")!)
                Link("Report an Issue", destination: URL(string: "https://github.com/alvst/pesty/issues")!)
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
