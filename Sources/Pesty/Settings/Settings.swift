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

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        case .forever: "Forever"
        }
    }

    var description: String {
        switch self {
        case .day: "Clips are kept for 24 hours."
        case .week: "Clips are kept for 7 days."
        case .month: "Clips are kept for 1 month."
        case .year: "Clips are kept for 1 year."
        case .forever: "Clips are kept until you erase them."
        }
    }

    var cutoffDate: Date? {
        let calendar = Calendar.current
        switch self {
        case .day: return calendar.date(byAdding: .day, value: -1, to: .now)
        case .week: return calendar.date(byAdding: .day, value: -7, to: .now)
        case .month: return calendar.date(byAdding: .month, value: -1, to: .now)
        case .year: return calendar.date(byAdding: .year, value: -1, to: .now)
        case .forever: return nil
        }
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
        static let quickPasteModifier = "quickPasteModifier"
        static let plainTextModifier = "plainTextModifier"
        static let launchAtLogin = "launchAtLogin"
        static let hideOnClickOutside = "hideOnClickOutside"
        static let pasteDirectly = "pasteDirectly"
        static let playSound = "playSound"
        static let ignoreConcealed = "ignoreConcealed"
        static let barHeight = "barHeight"
        static let showBarResizeHandle = "showBarResizeHandle"
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

    var barHeight: Double {
        didSet {
            guard isLoaded else { return }
            let clamped = min(720, max(240, barHeight))
            if clamped != barHeight { barHeight = clamped; return }
            d.set(barHeight, forKey: Keys.barHeight)
        }
    }

    var showBarResizeHandle: Bool {
        didSet { guard isLoaded else { return }; d.set(showBarResizeHandle, forKey: Keys.showBarResizeHandle) }
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
            Keys.quickPasteModifier: ShortcutModifier.command.carbonValue,
            Keys.plainTextModifier: ShortcutModifier.shift.carbonValue,
            Keys.launchAtLogin: false,
            Keys.hideOnClickOutside: true,
            Keys.pasteDirectly: true,
            Keys.playSound: false,
            Keys.ignoreConcealed: true,
            Keys.barHeight: 430.0,
            Keys.showBarResizeHandle: false,
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
        quickPasteModifier = d.integer(forKey: Keys.quickPasteModifier)
        plainTextModifier = d.integer(forKey: Keys.plainTextModifier)
        launchAtLogin = d.bool(forKey: Keys.launchAtLogin)
        hideOnClickOutside = d.bool(forKey: Keys.hideOnClickOutside)
        pasteDirectly = d.bool(forKey: Keys.pasteDirectly)
        playSound = d.bool(forKey: Keys.playSound)
        ignoreConcealed = d.bool(forKey: Keys.ignoreConcealed)
        barHeight = d.double(forKey: Keys.barHeight)
        showBarResizeHandle = d.bool(forKey: Keys.showBarResizeHandle)
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
}
