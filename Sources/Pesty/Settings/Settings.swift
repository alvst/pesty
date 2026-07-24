import AppKit
import Carbon.HIToolbox
import Observation

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
        static let launchAtLogin = "launchAtLogin"
        static let pasteDirectly = "pasteDirectly"
        static let playSound = "playSound"
        static let ignoreConcealed = "ignoreConcealed"
        static let barHeight = "barHeight"
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

    var launchAtLogin: Bool {
        didSet { guard isLoaded else { return }
            d.set(launchAtLogin, forKey: Keys.launchAtLogin); LaunchAtLogin.set(enabled: launchAtLogin) }
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
            Keys.launchAtLogin: false,
            Keys.pasteDirectly: true,
            Keys.playSound: false,
            Keys.ignoreConcealed: true,
            Keys.barHeight: 430.0,
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
        launchAtLogin = d.bool(forKey: Keys.launchAtLogin)
        pasteDirectly = d.bool(forKey: Keys.pasteDirectly)
        playSound = d.bool(forKey: Keys.playSound)
        ignoreConcealed = d.bool(forKey: Keys.ignoreConcealed)
        barHeight = d.double(forKey: Keys.barHeight)
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
}
