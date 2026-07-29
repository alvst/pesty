import AppKit
import Carbon.HIToolbox
import Observation

enum ClipPreviewStyle: Int, CaseIterable, Identifiable {
    case nativeQuickLook
    case inlinePesty

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .nativeQuickLook: "Native Quick Look"
        case .inlinePesty: "Inline Pesty preview"
        }
    }

    var detail: String {
        switch self {
        case .nativeQuickLook: "Open a macOS Quick Look panel with Space."
        case .inlinePesty: "Show a rich preview with link titles and favicons inside Pesty."
        }
    }
}

enum PreviewOpenTarget: CaseIterable, Identifiable {
    case text
    case image
    case link

    var id: Self { self }

    var title: String {
        switch self {
        case .text: "Text & rich text"
        case .image: "Images"
        case .link: "Links"
        }
    }

    var defaultApplicationBundleID: String {
        switch self {
        case .text: "com.apple.TextEdit"
        case .image: "com.apple.Preview"
        case .link: "com.apple.Safari"
        }
    }
}

enum SelectedClipPosition: Int, CaseIterable, Identifiable {
    case center
    case rightEdge

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .center: "Center"
        case .rightEdge: "Right edge"
        }
    }

    var detail: String {
        switch self {
        case .center: "Keep the selected clip centered with surrounding context visible."
        case .rightEdge: "Place the selected clip at the far right, like Paste."
        }
    }
}

enum ClipColorTheme: Int, CaseIterable, Identifiable {
    case `default`
    case vibrant
    case accentShades

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .default: "Default"
        case .vibrant: "Vibrant"
        case .accentShades: "Accent shades"
        }
    }

    var detail: String {
        switch self {
        case .default:
            "Use Pesty’s familiar, deterministic mix of card colors."
        case .vibrant:
            "Match each clip to the dominant color in its source app’s icon."
        case .accentShades:
            "Give each source app a stable lighter or darker shade of one color."
        }
    }
}
enum HistoryRetention: Int, CaseIterable, Identifiable {
    case day
    case week
    case month
    case year
    case forever
    case twoWeeks
    case threeWeeks
    case twoMonths
    case threeMonths
    case sixMonths

    // Preserve the original raw values so a saved selection remains valid as
    // additional intervals are introduced.
    static let allCases: [HistoryRetention] = [
        .day, .week, .twoWeeks, .threeWeeks, .month,
        .twoMonths, .threeMonths, .sixMonths, .year, .forever
    ]

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .day: "1 Day"
        case .week: "1 Week"
        case .twoWeeks: "2 Weeks"
        case .threeWeeks: "3 Weeks"
        case .month: "1 Month"
        case .twoMonths: "2 Months"
        case .threeMonths: "3 Months"
        case .sixMonths: "6 Months"
        case .year: "1 Year"
        case .forever: "Forever"
        }
    }

    var description: String {
        switch self {
        case .day: "Clips are kept for 24 hours."
        case .week: "Clips are kept for 7 days."
        case .twoWeeks: "Clips are kept for 2 weeks."
        case .threeWeeks: "Clips are kept for 3 weeks."
        case .month: "Clips are kept for 1 month."
        case .twoMonths: "Clips are kept for 2 months."
        case .threeMonths: "Clips are kept for 3 months."
        case .sixMonths: "Clips are kept for 6 months."
        case .year: "Clips are kept for 1 year."
        case .forever: "Clips are kept until you erase them."
        }
    }

    var cutoffDate: Date? {
        let calendar = Calendar.current
        switch self {
        case .day: return calendar.date(byAdding: .day, value: -1, to: .now)
        case .week: return calendar.date(byAdding: .day, value: -7, to: .now)
        case .twoWeeks: return calendar.date(byAdding: .day, value: -14, to: .now)
        case .threeWeeks: return calendar.date(byAdding: .day, value: -21, to: .now)
        case .month: return calendar.date(byAdding: .month, value: -1, to: .now)
        case .twoMonths: return calendar.date(byAdding: .month, value: -2, to: .now)
        case .threeMonths: return calendar.date(byAdding: .month, value: -3, to: .now)
        case .sixMonths: return calendar.date(byAdding: .month, value: -6, to: .now)
        case .year: return calendar.date(byAdding: .year, value: -1, to: .now)
        case .forever: return nil
        }
    }

    var sliderIndex: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0)
    }

    var shortSliderTitle: String {
        switch self {
        case .day: "1d"
        case .week: "1w"
        case .twoWeeks: "2w"
        case .threeWeeks: "3w"
        case .month: "1m"
        case .twoMonths: "2m"
        case .threeMonths: "3m"
        case .sixMonths: "6m"
        case .year: "1y"
        case .forever: "∞"
        }
    }

    init(sliderIndex: Double) {
        let index = min(Self.allCases.count - 1, max(0, Int(sliderIndex.rounded())))
        self = Self.allCases[index]
    }
}

enum HistoryRetentionMode: Int, CaseIterable, Identifiable {
    case itemCount
    case timePeriod

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .itemCount: "Number"
        case .timePeriod: "Time"
        }
    }
}

enum ShortcutModifier: CaseIterable, Identifiable {
    case command
    case option
    case control
    case shift

    var id: Int { carbonValue }

    var carbonValue: Int {
        switch self {
        case .command: return cmdKey
        case .option: return optionKey
        case .control: return controlKey
        case .shift: return shiftKey
        }
    }

    var title: String {
        switch self {
        case .command: return "Command"
        case .option: return "Option"
        case .control: return "Control"
        case .shift: return "Shift"
        }
    }

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        }
    }

    init?(carbonValue: Int) {
        guard let modifier = Self.allCases.first(where: { $0.carbonValue == carbonValue }) else {
            return nil
        }
        self = modifier
    }
}
@Observable
@MainActor
final class Settings {
    static let shared = Settings()

    @ObservationIgnored private let d = UserDefaults.standard
    @ObservationIgnored private var isLoaded = false

    enum Keys {
        static let historyLimit = "historyLimit"
        static let historyRetentionMode = "historyRetentionMode"
        static let historyRetention = "historyRetention"
        static let pasteStacksFollowHistory = "pasteStacksFollowHistory"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let quickPasteModifier = "quickPasteModifier"
        static let plainTextModifier = "plainTextModifier"
        static let sequenceHotkeyKeyCode = "sequenceHotkeyKeyCode"
        static let sequenceHotkeyModifiers = "sequenceHotkeyModifiers"
        static let launchAtLogin = "launchAtLogin"
        static let hideOnClickOutside = "hideOnClickOutside"
        static let pasteDirectly = "pasteDirectly"
        static let playSound = "playSound"
        static let ignoreConcealed = "ignoreConcealed"
        static let ignoredSourceAppBundleIDs = "ignoredSourceAppBundleIDs"
        static let barHeight = "barHeight"
        static let showBarResizeHandle = "showBarResizeHandle"
        static let clipPreviewStyle = "clipPreviewStyle"
        static let previewTextApplicationBundleID = "previewTextApplicationBundleID"
        static let previewImageApplicationBundleID = "previewImageApplicationBundleID"
        static let previewLinkApplicationBundleID = "previewLinkApplicationBundleID"
        static let selectedClipPosition = "selectedClipPosition"
        static let clipColorTheme = "clipColorTheme"
        static let clipColorAccentHex = "clipColorAccentHex"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let onboarded = "onboarded"
        static let iCloudSync = "iCloudSync"
    }

    var historyLimit: Int {
        didSet {
            guard isLoaded else { return }
            if historyLimit < 20 { historyLimit = 20; return }
            d.set(historyLimit, forKey: Keys.historyLimit)
            ClipboardStore.shared.applyHistoryPolicy()
        }
    }

    var historyRetentionMode: HistoryRetentionMode {
        didSet {
            guard isLoaded else { return }
            d.set(historyRetentionMode.rawValue, forKey: Keys.historyRetentionMode)
            ClipboardStore.shared.applyHistoryPolicy()
        }
    }

    var historyRetention: HistoryRetention {
        didSet {
            guard isLoaded else { return }
            d.set(historyRetention.rawValue, forKey: Keys.historyRetention)
            if historyRetentionMode == .timePeriod {
                ClipboardStore.shared.applyHistoryPolicy()
            }
        }
    }

    /// When enabled, removing clipboard history also removes those clips from
    /// saved Paste Stacks. The default keeps stacks until the user deletes them.
    var pasteStacksFollowHistory: Bool {
        didSet { guard isLoaded else { return }; d.set(pasteStacksFollowHistory, forKey: Keys.pasteStacksFollowHistory) }
    }

    var hotkeyKeyCode: Int {
        didSet { guard isLoaded else { return }
            d.set(hotkeyKeyCode, forKey: Keys.hotkeyKeyCode); HotKeyCenter.shared.reload() }
    }

    var hotkeyModifiers: Int {
        didSet { guard isLoaded else { return }
            d.set(hotkeyModifiers, forKey: Keys.hotkeyModifiers); HotKeyCenter.shared.reload() }
    }

    var quickPasteModifier: Int {
        didSet { guard isLoaded else { return }; d.set(quickPasteModifier, forKey: Keys.quickPasteModifier) }
    }

    var plainTextModifier: Int {
        didSet { guard isLoaded else { return }; d.set(plainTextModifier, forKey: Keys.plainTextModifier) }
    }

    var sequenceHotkeyKeyCode: Int {
        didSet { guard isLoaded else { return }
            d.set(sequenceHotkeyKeyCode, forKey: Keys.sequenceHotkeyKeyCode); HotKeyCenter.shared.reload() }
    }

    var sequenceHotkeyModifiers: Int {
        didSet { guard isLoaded else { return }
            d.set(sequenceHotkeyModifiers, forKey: Keys.sequenceHotkeyModifiers); HotKeyCenter.shared.reload() }
    }

    var launchAtLogin: Bool {
        didSet { guard isLoaded else { return }
            d.set(launchAtLogin, forKey: Keys.launchAtLogin); LaunchAtLogin.set(enabled: launchAtLogin) }
    }

    var hideOnClickOutside: Bool {
        didSet { guard isLoaded else { return }; d.set(hideOnClickOutside, forKey: Keys.hideOnClickOutside) }
    }

    var pasteDirectly: Bool {
        didSet { guard isLoaded else { return }; d.set(pasteDirectly, forKey: Keys.pasteDirectly) }
    }

    var playSound: Bool {
        didSet { guard isLoaded else { return }; d.set(playSound, forKey: Keys.playSound) }
    }

    var ignoreConcealed: Bool {
        didSet { guard isLoaded else { return }; d.set(ignoreConcealed, forKey: Keys.ignoreConcealed) }
    }

    /// Applications whose copied content should never be recorded in history.
    /// Store bundle identifiers rather than paths so the choice continues to work
    /// when an app is updated or moved.
    private(set) var ignoredSourceAppBundleIDs: [String] {
        didSet { guard isLoaded else { return }; d.set(ignoredSourceAppBundleIDs, forKey: Keys.ignoredSourceAppBundleIDs) }
    }

    var barHeight: Double {
        didSet {
            guard isLoaded else { return }
            let clamped = min(720, max(240, barHeight))
            if clamped != barHeight { barHeight = clamped; return }
            d.set(barHeight, forKey: Keys.barHeight)
            AppController.shared.resizeVisibleBar(to: barHeight)
        }
    }

    var showBarResizeHandle: Bool {
        didSet { guard isLoaded else { return }; d.set(showBarResizeHandle, forKey: Keys.showBarResizeHandle) }
    }

    var clipPreviewStyle: ClipPreviewStyle {
        didSet {
            guard isLoaded else { return }
            d.set(clipPreviewStyle.rawValue, forKey: Keys.clipPreviewStyle)
            if clipPreviewStyle != .inlinePesty {
                ClipboardStore.shared.inlinePreviewVisible = false
            }
        }
    }

    var previewTextApplicationBundleID: String {
        didSet { guard isLoaded else { return }; d.set(previewTextApplicationBundleID, forKey: Keys.previewTextApplicationBundleID) }
    }

    var previewImageApplicationBundleID: String {
        didSet { guard isLoaded else { return }; d.set(previewImageApplicationBundleID, forKey: Keys.previewImageApplicationBundleID) }
    }

    var previewLinkApplicationBundleID: String {
        didSet { guard isLoaded else { return }; d.set(previewLinkApplicationBundleID, forKey: Keys.previewLinkApplicationBundleID) }
    }

    var selectedClipPosition: SelectedClipPosition {
        didSet { guard isLoaded else { return }; d.set(selectedClipPosition.rawValue, forKey: Keys.selectedClipPosition) }
    }

    var clipColorTheme: ClipColorTheme {
        didSet { guard isLoaded else { return }; d.set(clipColorTheme.rawValue, forKey: Keys.clipColorTheme) }
    }

    var clipColorAccentHex: String {
        didSet { guard isLoaded else { return }; d.set(clipColorAccentHex, forKey: Keys.clipColorAccentHex) }
    }

    var showMenuBarIcon: Bool {
        didSet {
            guard isLoaded else { return }
            d.set(showMenuBarIcon, forKey: Keys.showMenuBarIcon)
            AppController.shared.setMenuBarIconVisible(showMenuBarIcon)
        }
    }

    var onboarded: Bool {
        didSet { guard isLoaded else { return }; d.set(onboarded, forKey: Keys.onboarded) }
    }

    var iCloudSync: Bool {
        didSet { guard isLoaded else { return }; d.set(iCloudSync, forKey: Keys.iCloudSync) }
    }

    private init() {
        d.register(defaults: [
            Keys.historyLimit: 500,
            Keys.historyRetentionMode: HistoryRetentionMode.itemCount.rawValue,
            Keys.historyRetention: HistoryRetention.month.rawValue,
            Keys.pasteStacksFollowHistory: false,
            Keys.hotkeyKeyCode: kVK_ANSI_V,
            Keys.hotkeyModifiers: cmdKey | shiftKey,
            Keys.quickPasteModifier: ShortcutModifier.command.carbonValue,
            Keys.plainTextModifier: ShortcutModifier.shift.carbonValue,
            Keys.sequenceHotkeyKeyCode: kVK_ANSI_V,
            Keys.sequenceHotkeyModifiers: cmdKey | optionKey,
            Keys.launchAtLogin: false,
            Keys.hideOnClickOutside: true,
            Keys.pasteDirectly: true,
            Keys.playSound: false,
            Keys.ignoreConcealed: true,
            Keys.ignoredSourceAppBundleIDs: [],
            Keys.barHeight: 430.0,
            Keys.showBarResizeHandle: false,
            Keys.clipPreviewStyle: ClipPreviewStyle.nativeQuickLook.rawValue,
            Keys.previewTextApplicationBundleID: PreviewOpenTarget.text.defaultApplicationBundleID,
            Keys.previewImageApplicationBundleID: PreviewOpenTarget.image.defaultApplicationBundleID,
            Keys.previewLinkApplicationBundleID: PreviewOpenTarget.link.defaultApplicationBundleID,
            Keys.selectedClipPosition: SelectedClipPosition.center.rawValue,
            Keys.clipColorTheme: ClipColorTheme.default.rawValue,
            Keys.clipColorAccentHex: "#FF5A9F",
            Keys.showMenuBarIcon: true,
            Keys.onboarded: false,
            Keys.iCloudSync: false
        ])
        historyLimit = d.integer(forKey: Keys.historyLimit)
        historyRetentionMode = HistoryRetentionMode(rawValue: d.integer(forKey: Keys.historyRetentionMode)) ?? .itemCount
        historyRetention = HistoryRetention(rawValue: d.integer(forKey: Keys.historyRetention)) ?? .month
        pasteStacksFollowHistory = d.bool(forKey: Keys.pasteStacksFollowHistory)
        hotkeyKeyCode = d.integer(forKey: Keys.hotkeyKeyCode)
        hotkeyModifiers = d.integer(forKey: Keys.hotkeyModifiers)
        quickPasteModifier = d.integer(forKey: Keys.quickPasteModifier)
        plainTextModifier = d.integer(forKey: Keys.plainTextModifier)
        sequenceHotkeyKeyCode = d.integer(forKey: Keys.sequenceHotkeyKeyCode)
        sequenceHotkeyModifiers = d.integer(forKey: Keys.sequenceHotkeyModifiers)
        launchAtLogin = d.bool(forKey: Keys.launchAtLogin)
        hideOnClickOutside = d.bool(forKey: Keys.hideOnClickOutside)
        pasteDirectly = d.bool(forKey: Keys.pasteDirectly)
        playSound = d.bool(forKey: Keys.playSound)
        ignoreConcealed = d.bool(forKey: Keys.ignoreConcealed)
        ignoredSourceAppBundleIDs = (d.stringArray(forKey: Keys.ignoredSourceAppBundleIDs) ?? [])
            .filter { !$0.isEmpty }
        barHeight = d.double(forKey: Keys.barHeight)
        showBarResizeHandle = d.bool(forKey: Keys.showBarResizeHandle)
        clipPreviewStyle = ClipPreviewStyle(rawValue: d.integer(forKey: Keys.clipPreviewStyle)) ?? .nativeQuickLook
        previewTextApplicationBundleID = d.string(forKey: Keys.previewTextApplicationBundleID)
            ?? PreviewOpenTarget.text.defaultApplicationBundleID
        previewImageApplicationBundleID = d.string(forKey: Keys.previewImageApplicationBundleID)
            ?? PreviewOpenTarget.image.defaultApplicationBundleID
        previewLinkApplicationBundleID = d.string(forKey: Keys.previewLinkApplicationBundleID)
            ?? PreviewOpenTarget.link.defaultApplicationBundleID
        selectedClipPosition = SelectedClipPosition(rawValue: d.integer(forKey: Keys.selectedClipPosition)) ?? .center
        clipColorTheme = ClipColorTheme(rawValue: d.integer(forKey: Keys.clipColorTheme)) ?? .default
        clipColorAccentHex = d.string(forKey: Keys.clipColorAccentHex) ?? "#FF5A9F"
        showMenuBarIcon = d.bool(forKey: Keys.showMenuBarIcon)
        onboarded = d.bool(forKey: Keys.onboarded)
        iCloudSync = d.bool(forKey: Keys.iCloudSync)
        isLoaded = true
    }

    var hotkeyDisplay: String {
        HotKeyCenter.describe(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)
    }

    var quickPasteModifierDisplay: String {
        ShortcutModifier(carbonValue: quickPasteModifier)?.symbol ?? "⌘"
    }

    var sequenceHotkeyDisplay: String {
        HotKeyCenter.describe(keyCode: sequenceHotkeyKeyCode, modifiers: sequenceHotkeyModifiers)
    }

    func previewApplicationBundleID(for target: PreviewOpenTarget) -> String {
        switch target {
        case .text: previewTextApplicationBundleID
        case .image: previewImageApplicationBundleID
        case .link: previewLinkApplicationBundleID
        }
    }

    func setPreviewApplicationBundleID(_ bundleID: String, for target: PreviewOpenTarget) {
        guard !bundleID.isEmpty else { return }
        switch target {
        case .text: previewTextApplicationBundleID = bundleID
        case .image: previewImageApplicationBundleID = bundleID
        case .link: previewLinkApplicationBundleID = bundleID
        }
    }

    func restorePreviewApplicationDefaults() {
        previewTextApplicationBundleID = PreviewOpenTarget.text.defaultApplicationBundleID
        previewImageApplicationBundleID = PreviewOpenTarget.image.defaultApplicationBundleID
        previewLinkApplicationBundleID = PreviewOpenTarget.link.defaultApplicationBundleID
    }

    func isIgnoringSourceApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return ignoredSourceAppBundleIDs.contains(bundleID)
    }

    func addIgnoredSourceApp(_ bundleID: String) {
        guard !bundleID.isEmpty, !ignoredSourceAppBundleIDs.contains(bundleID) else { return }
        ignoredSourceAppBundleIDs.append(bundleID)
        ignoredSourceAppBundleIDs.sort()
    }

    func removeIgnoredSourceApp(_ bundleID: String) {
        ignoredSourceAppBundleIDs.removeAll { $0 == bundleID }
    }
}
