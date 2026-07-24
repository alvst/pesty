import AppKit
import Carbon.HIToolbox
import Observation

enum ShortcutModifier: CaseIterable, Identifiable {
    case command, option, control, shift
    var id: Int { carbonValue }
    var carbonValue: Int {
        switch self { case .command: cmdKey; case .option: optionKey; case .control: controlKey; case .shift: shiftKey }
    }
    var title: String {
        switch self { case .command: "Command"; case .option: "Option"; case .control: "Control"; case .shift: "Shift" }
    }
    var symbol: String {
        switch self { case .command: "⌘"; case .option: "⌥"; case .control: "⌃"; case .shift: "⇧" }
    }
    init?(carbonValue: Int) {
        self = Self.allCases.first(where: { $0.carbonValue == carbonValue }) ?? .command
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

    // Keep the original raw values intact for existing installations, but expose
    // the periods in a natural order for the discrete retention slider.
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
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let sequenceHotkeyKeyCode = "sequenceHotkeyKeyCode"
        static let sequenceHotkeyModifiers = "sequenceHotkeyModifiers"
        static let stackPasteInReverse = "stackPasteInReverse"
        static let keepPastedStackItems = "keepPastedStackItems"
        static let pasteStacksFollowHistory = "pasteStacksFollowHistory"
        static let quickPasteModifier = "quickPasteModifier"
        static let plainTextModifier = "plainTextModifier"
        static let launchAtLogin = "launchAtLogin"
        static let hideOnClickOutside = "hideOnClickOutside"
        static let pasteDirectly = "pasteDirectly"
        static let playSound = "playSound"
        static let ignoreConcealed = "ignoreConcealed"
        static let ignoredSourceAppBundleIDs = "ignoredSourceAppBundleIDs"
        static let barHeight = "barHeight"
        static let showBarResizeHandle = "showBarResizeHandle"
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

    var hotkeyKeyCode: Int {
        didSet { guard isLoaded else { return }
            d.set(hotkeyKeyCode, forKey: Keys.hotkeyKeyCode); HotKeyCenter.shared.reload() }
    }

    var hotkeyModifiers: Int {
        didSet { guard isLoaded else { return }
            d.set(hotkeyModifiers, forKey: Keys.hotkeyModifiers); HotKeyCenter.shared.reload() }
    }

    var sequenceHotkeyKeyCode: Int {
        didSet { guard isLoaded else { return }
            d.set(sequenceHotkeyKeyCode, forKey: Keys.sequenceHotkeyKeyCode); HotKeyCenter.shared.reload() }
    }

    var sequenceHotkeyModifiers: Int {
        didSet { guard isLoaded else { return }
            d.set(sequenceHotkeyModifiers, forKey: Keys.sequenceHotkeyModifiers); HotKeyCenter.shared.reload() }
    }

    var stackPasteInReverse: Bool {
        didSet { guard isLoaded else { return }; d.set(stackPasteInReverse, forKey: Keys.stackPasteInReverse) }
    }

    var keepPastedStackItems: Bool {
        didSet { guard isLoaded else { return }; d.set(keepPastedStackItems, forKey: Keys.keepPastedStackItems) }
    }

    /// When enabled, removing clipboard history also removes those clips from
    /// saved Paste Stacks. The default keeps stacks until the user deletes them.
    var pasteStacksFollowHistory: Bool {
        didSet { guard isLoaded else { return }; d.set(pasteStacksFollowHistory, forKey: Keys.pasteStacksFollowHistory) }
    }

    var quickPasteModifier: Int {
        didSet { guard isLoaded else { return }; d.set(quickPasteModifier, forKey: Keys.quickPasteModifier) }
    }

    var plainTextModifier: Int {
        didSet { guard isLoaded else { return }; d.set(plainTextModifier, forKey: Keys.plainTextModifier) }
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
            Keys.hotkeyKeyCode: kVK_ANSI_V,
            Keys.hotkeyModifiers: cmdKey | shiftKey,
            Keys.sequenceHotkeyKeyCode: kVK_ANSI_V,
            Keys.sequenceHotkeyModifiers: cmdKey | optionKey,
            Keys.stackPasteInReverse: false,
            Keys.keepPastedStackItems: true,
            Keys.pasteStacksFollowHistory: false,
            Keys.quickPasteModifier: ShortcutModifier.command.carbonValue,
            Keys.plainTextModifier: ShortcutModifier.shift.carbonValue,
            Keys.launchAtLogin: false,
            Keys.hideOnClickOutside: true,
            Keys.pasteDirectly: true,
            Keys.playSound: false,
            Keys.ignoreConcealed: true,
            Keys.ignoredSourceAppBundleIDs: [],
            Keys.barHeight: 430.0,
            Keys.showBarResizeHandle: false,
            Keys.showMenuBarIcon: true,
            Keys.onboarded: false,
            Keys.iCloudSync: false
        ])
        historyLimit = d.integer(forKey: Keys.historyLimit)
        historyRetentionMode = HistoryRetentionMode(rawValue: d.integer(forKey: Keys.historyRetentionMode)) ?? .itemCount
        historyRetention = HistoryRetention(rawValue: d.integer(forKey: Keys.historyRetention)) ?? .month
        hotkeyKeyCode = d.integer(forKey: Keys.hotkeyKeyCode)
        hotkeyModifiers = d.integer(forKey: Keys.hotkeyModifiers)
        sequenceHotkeyKeyCode = d.integer(forKey: Keys.sequenceHotkeyKeyCode)
        sequenceHotkeyModifiers = d.integer(forKey: Keys.sequenceHotkeyModifiers)
        stackPasteInReverse = d.bool(forKey: Keys.stackPasteInReverse)
        keepPastedStackItems = d.bool(forKey: Keys.keepPastedStackItems)
        pasteStacksFollowHistory = d.bool(forKey: Keys.pasteStacksFollowHistory)
        quickPasteModifier = d.integer(forKey: Keys.quickPasteModifier)
        plainTextModifier = d.integer(forKey: Keys.plainTextModifier)
        launchAtLogin = d.bool(forKey: Keys.launchAtLogin)
        hideOnClickOutside = d.bool(forKey: Keys.hideOnClickOutside)
        pasteDirectly = d.bool(forKey: Keys.pasteDirectly)
        playSound = d.bool(forKey: Keys.playSound)
        ignoreConcealed = d.bool(forKey: Keys.ignoreConcealed)
        ignoredSourceAppBundleIDs = (d.stringArray(forKey: Keys.ignoredSourceAppBundleIDs) ?? [])
            .filter { !$0.isEmpty }
        barHeight = d.double(forKey: Keys.barHeight)
        showBarResizeHandle = d.bool(forKey: Keys.showBarResizeHandle)
        showMenuBarIcon = d.bool(forKey: Keys.showMenuBarIcon)
        onboarded = d.bool(forKey: Keys.onboarded)
        iCloudSync = d.bool(forKey: Keys.iCloudSync)
        isLoaded = true
    }

    var hotkeyDisplay: String {
        HotKeyCenter.describe(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)
    }

    var sequenceHotkeyDisplay: String {
        HotKeyCenter.describe(keyCode: sequenceHotkeyKeyCode, modifiers: sequenceHotkeyModifiers)
    }

    var quickPasteModifierDisplay: String {
        ShortcutModifier(carbonValue: quickPasteModifier)?.symbol ?? "⌘"
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
