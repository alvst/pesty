import Foundation
import Carbon.HIToolbox

struct AppLaunchIntent: Equatable {
    enum Mode: Equatable {
        case standard
        case demo(featureLabRoot: String?, allowsClipboardMonitoring: Bool)
    }

    let mode: Mode

    static func parse(arguments: [String], environment: [String: String]) -> AppLaunchIntent {
        guard arguments.contains("--demo") else {
            return AppLaunchIntent(mode: .standard)
        }

        let argumentRoot = optionValue(named: "--feature-lab-root", in: arguments)
        let candidate = argumentRoot ?? environment["PESTY_FEATURE_LAB_ROOT"]
        let safeRoot: String? = candidate.flatMap { path -> String? in
            guard !path.isEmpty, NSString(string: path).isAbsolutePath else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        }
        return AppLaunchIntent(mode: .demo(
            featureLabRoot: safeRoot,
            allowsClipboardMonitoring: arguments.contains("--feature-lab-monitor")))
    }

    private static func optionValue(named name: String, in arguments: [String]) -> String? {
        if let assignment = arguments.first(where: { $0.hasPrefix("\(name)=") }) {
            return String(assignment.dropFirst(name.count + 1))
        }
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

@MainActor
protocol SettingsDefaultsStore: AnyObject {
    func register(defaults registrationDictionary: [String: Any])
    func set(_ value: Any?, forKey defaultName: String)
    func object(forKey defaultName: String) -> Any?
    func integer(forKey defaultName: String) -> Int
    func bool(forKey defaultName: String) -> Bool
    func double(forKey defaultName: String) -> Double
    func string(forKey defaultName: String) -> String?
    func stringArray(forKey defaultName: String) -> [String]?
    func dictionary(forKey defaultName: String) -> [String: Any]?
}

extension UserDefaults: SettingsDefaultsStore {}

@MainActor
final class InMemorySettingsDefaults: SettingsDefaultsStore {
    private var values: [String: Any]

    init(seed: [String: Any] = [:]) {
        values = seed
    }

    func register(defaults registrationDictionary: [String: Any]) {
        for (key, value) in registrationDictionary where values[key] == nil {
            values[key] = value
        }
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    func object(forKey defaultName: String) -> Any? { values[defaultName] }

    func integer(forKey defaultName: String) -> Int {
        (values[defaultName] as? NSNumber)?.intValue ?? 0
    }

    func bool(forKey defaultName: String) -> Bool {
        (values[defaultName] as? NSNumber)?.boolValue ?? false
    }

    func double(forKey defaultName: String) -> Double {
        (values[defaultName] as? NSNumber)?.doubleValue ?? 0
    }

    func string(forKey defaultName: String) -> String? { values[defaultName] as? String }

    func stringArray(forKey defaultName: String) -> [String]? { values[defaultName] as? [String] }

    func dictionary(forKey defaultName: String) -> [String: Any]? {
        values[defaultName] as? [String: Any]
    }
}

/// A preferences store whose entire domain lives inside one explicit feature-lab root.
/// Registered defaults remain fallback values, matching `UserDefaults` semantics, while
/// values selected in Settings are written atomically for the next launch of that lab.
@MainActor
final class FeatureLabSettingsDefaults: SettingsDefaultsStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private var values: [String: Any]
    private var registeredDefaults: [String: Any] = [:]

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        values = Self.loadValues(from: fileURL)
    }

    func register(defaults registrationDictionary: [String: Any]) {
        for (key, value) in registrationDictionary where registeredDefaults[key] == nil {
            registeredDefaults[key] = value
        }
    }

    func set(_ value: Any?, forKey defaultName: String) {
        if let value {
            values[defaultName] = value
        } else {
            values.removeValue(forKey: defaultName)
        }
        persist()
    }

    /// Reasserts non-negotiable lab protections without disturbing feature preferences.
    func enforce(_ enforcedValues: [String: Any]) {
        for (key, value) in enforcedValues {
            values[key] = value
        }
        persist()
    }

    func object(forKey defaultName: String) -> Any? { value(forKey: defaultName) }

    func integer(forKey defaultName: String) -> Int {
        (value(forKey: defaultName) as? NSNumber)?.intValue ?? 0
    }

    func bool(forKey defaultName: String) -> Bool {
        (value(forKey: defaultName) as? NSNumber)?.boolValue ?? false
    }

    func double(forKey defaultName: String) -> Double {
        (value(forKey: defaultName) as? NSNumber)?.doubleValue ?? 0
    }

    func string(forKey defaultName: String) -> String? {
        value(forKey: defaultName) as? String
    }

    func stringArray(forKey defaultName: String) -> [String]? {
        value(forKey: defaultName) as? [String]
    }

    func dictionary(forKey defaultName: String) -> [String: Any]? {
        value(forKey: defaultName) as? [String: Any]
    }

    private func value(forKey key: String) -> Any? {
        values[key] ?? registeredDefaults[key]
    }

    private func persist() {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: values,
            format: .binary,
            options: 0)
        else { return }

        let parentDirectory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: parentDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: parentDirectory.path)
            try data.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path)
        } catch {
            // An unwritable lab root must not redirect preferences to a live domain.
            // The in-process values remain usable and safety enforcement remains active.
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private static func loadValues(from fileURL: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: fileURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil),
              let values = propertyList as? [String: Any]
        else { return [:] }
        return values
    }
}

@MainActor
struct AppRuntimeConfiguration {
    let isDemo: Bool
    let settingsDefaults: any SettingsDefaultsStore
    let storageBaseURL: URL?
    let allowsClipboardMonitoring: Bool
    let allowsGlobalHotKey: Bool
    let allowsCloudSync: Bool
    let allowsLaunchAtLogin: Bool

    static var production: AppRuntimeConfiguration {
        AppRuntimeConfiguration(
            isDemo: false,
            settingsDefaults: UserDefaults.standard,
            storageBaseURL: nil,
            allowsClipboardMonitoring: true,
            allowsGlobalHotKey: true,
            allowsCloudSync: true,
            allowsLaunchAtLogin: true)
    }

    static func make(
        for intent: AppLaunchIntent,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        uniqueProfileID: @autoclosure () -> String = UUID().uuidString
    ) -> AppRuntimeConfiguration {
        guard case .demo(let requestedRoot, let allowsClipboardMonitoring) = intent.mode else {
            return .production
        }

        let profileRoot: URL
        if let requestedRoot {
            profileRoot = URL(fileURLWithPath: requestedRoot, isDirectory: true)
                .appendingPathComponent("Pesty-FeatureLab", isDirectory: true)
        } else {
            profileRoot = temporaryDirectory
                .appendingPathComponent("Pesty-FeatureLab", isDirectory: true)
                .appendingPathComponent(uniqueProfileID(), isDirectory: true)
        }
        let storageBase = profileRoot
            .appendingPathComponent("Library/Application Support/Pesty", isDirectory: true)
        let enforcedSafetyValues: [String: Any] = [
            "launchAtLogin": false,
            "iCloudSync": false,
            "cloudKitSync": false,
            "onboarded": true,
            "hotkeyKeyCode": kVK_ANSI_V,
            "hotkeyModifiers": cmdKey | shiftKey | controlKey
        ]
        let defaults: any SettingsDefaultsStore
        if requestedRoot != nil {
            let persistentDefaults = FeatureLabSettingsDefaults(
                fileURL: profileRoot
                    .appendingPathComponent("Library/Preferences", isDirectory: true)
                    .appendingPathComponent("FeatureLabSettings.plist"))
            persistentDefaults.enforce(enforcedSafetyValues)
            defaults = persistentDefaults
        } else {
            defaults = InMemorySettingsDefaults(seed: enforcedSafetyValues)
        }
        return AppRuntimeConfiguration(
            isDemo: true,
            settingsDefaults: defaults,
            storageBaseURL: storageBase,
            allowsClipboardMonitoring: allowsClipboardMonitoring,
            allowsGlobalHotKey: true,
            allowsCloudSync: false,
            allowsLaunchAtLogin: false)
    }
}

@MainActor
enum AppRuntime {
    private static var installedConfiguration: AppRuntimeConfiguration?

    static var current: AppRuntimeConfiguration {
        installedConfiguration ?? .production
    }

    static func install(_ configuration: AppRuntimeConfiguration) {
        precondition(installedConfiguration == nil, "AppRuntime must be installed exactly once")
        installedConfiguration = configuration
    }
}
