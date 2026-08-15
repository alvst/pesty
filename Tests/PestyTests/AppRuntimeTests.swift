import XCTest
@testable import Pesty

final class AppRuntimeTests: XCTestCase {
    func testStandardLaunchIgnoresFeatureLabRoot() {
        let intent = AppLaunchIntent.parse(
            arguments: ["Pesty", "--feature-lab-root", "/tmp/ignored"],
            environment: ["PESTY_FEATURE_LAB_ROOT": "/tmp/also-ignored"])

        XCTAssertEqual(intent.mode, .standard)
    }

    func testDemoCommandLineRootOverridesEnvironmentAndIsStandardized() {
        let intent = AppLaunchIntent.parse(
            arguments: ["Pesty", "--demo", "--feature-lab-root=/tmp/a/../candidate"],
            environment: ["PESTY_FEATURE_LAB_ROOT": "/tmp/environment"])

        XCTAssertEqual(intent.mode, .demo(
            featureLabRoot: "/tmp/candidate",
            allowsClipboardMonitoring: false))
    }

    func testDemoRejectsRelativeFeatureLabRoot() {
        let intent = AppLaunchIntent.parse(
            arguments: ["Pesty", "--demo"],
            environment: ["PESTY_FEATURE_LAB_ROOT": "relative/profile"])

        XCTAssertEqual(intent.mode, .demo(featureLabRoot: nil, allowsClipboardMonitoring: false))
    }

    @MainActor
    func testRootedDemoUsesNestedStorageAndPersistentLabDefaults() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pesty-AppRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let intent = AppLaunchIntent(mode: .demo(
            featureLabRoot: root.path,
            allowsClipboardMonitoring: false))
        let runtime = AppRuntimeConfiguration.make(
            for: intent,
            temporaryDirectory: URL(fileURLWithPath: "/unused"),
            uniqueProfileID: "unused")

        XCTAssertTrue(runtime.isDemo)
        XCTAssertEqual(
            runtime.storageBaseURL?.path,
            root
                .appendingPathComponent("Pesty-FeatureLab/Library/Application Support/Pesty")
                .path)
        XCTAssertFalse(runtime.allowsClipboardMonitoring)
        XCTAssertTrue(runtime.allowsGlobalHotKey)
        XCTAssertFalse(runtime.allowsCloudSync)
        XCTAssertFalse(runtime.allowsLaunchAtLogin)
        XCTAssertFalse(runtime.settingsDefaults.bool(forKey: "iCloudSync"))
        XCTAssertFalse(runtime.settingsDefaults.bool(forKey: "cloudKitSync"))
        XCTAssertTrue(runtime.settingsDefaults.bool(forKey: "onboarded"))
        XCTAssertEqual(runtime.settingsDefaults.integer(forKey: "hotkeyKeyCode"), 9)
        XCTAssertEqual(runtime.settingsDefaults.integer(forKey: "hotkeyModifiers"), 4_864)
        XCTAssertTrue(runtime.settingsDefaults is FeatureLabSettingsDefaults)
    }

    @MainActor
    func testRootedDemoPersistsFeatureSettingsAndReassertsSafetySettings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pesty-AppRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let intent = AppLaunchIntent(mode: .demo(
            featureLabRoot: root.path,
            allowsClipboardMonitoring: false))

        let firstLaunch = AppRuntimeConfiguration.make(for: intent)
        firstLaunch.settingsDefaults.set(612.0, forKey: "barHeight")
        firstLaunch.settingsDefaults.set(false, forKey: "hideOnClickOutside")
        firstLaunch.settingsDefaults.set(true, forKey: "launchAtLogin")
        firstLaunch.settingsDefaults.set(true, forKey: "iCloudSync")
        firstLaunch.settingsDefaults.set(true, forKey: "cloudKitSync")
        firstLaunch.settingsDefaults.set(false, forKey: "onboarded")
        firstLaunch.settingsDefaults.set(0, forKey: "hotkeyKeyCode")
        firstLaunch.settingsDefaults.set(0, forKey: "hotkeyModifiers")

        let secondLaunch = AppRuntimeConfiguration.make(for: intent)

        XCTAssertEqual(secondLaunch.settingsDefaults.double(forKey: "barHeight"), 612)
        XCTAssertFalse(secondLaunch.settingsDefaults.bool(forKey: "hideOnClickOutside"))
        XCTAssertFalse(secondLaunch.settingsDefaults.bool(forKey: "launchAtLogin"))
        XCTAssertFalse(secondLaunch.settingsDefaults.bool(forKey: "iCloudSync"))
        XCTAssertFalse(secondLaunch.settingsDefaults.bool(forKey: "cloudKitSync"))
        XCTAssertTrue(secondLaunch.settingsDefaults.bool(forKey: "onboarded"))
        XCTAssertEqual(secondLaunch.settingsDefaults.integer(forKey: "hotkeyKeyCode"), 9)
        XCTAssertEqual(secondLaunch.settingsDefaults.integer(forKey: "hotkeyModifiers"), 4_864)

        let preferencesDirectory = root
            .appendingPathComponent("Pesty-FeatureLab/Library/Preferences", isDirectory: true)
        let preferencesFile = preferencesDirectory.appendingPathComponent("FeatureLabSettings.plist")
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: preferencesDirectory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: preferencesFile.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    @MainActor
    func testRootedDemoRegistrationDoesNotOverwritePersistedSetting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pesty-AppRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Settings.plist")
        let firstLaunch = FeatureLabSettingsDefaults(fileURL: fileURL)
        firstLaunch.set(612.0, forKey: "barHeight")

        let secondLaunch = FeatureLabSettingsDefaults(fileURL: fileURL)
        secondLaunch.register(defaults: ["barHeight": 430.0, "historyLimit": 500])

        XCTAssertEqual(secondLaunch.double(forKey: "barHeight"), 612)
        XCTAssertEqual(secondLaunch.integer(forKey: "historyLimit"), 500)
    }

    @MainActor
    func testBareDemoKeepsSettingsEphemeral() {
        let intent = AppLaunchIntent(mode: .demo(
            featureLabRoot: nil,
            allowsClipboardMonitoring: false))
        let firstLaunch = AppRuntimeConfiguration.make(for: intent, uniqueProfileID: "first")
        firstLaunch.settingsDefaults.set(612.0, forKey: "barHeight")

        let secondLaunch = AppRuntimeConfiguration.make(for: intent, uniqueProfileID: "second")

        XCTAssertTrue(firstLaunch.settingsDefaults is InMemorySettingsDefaults)
        XCTAssertTrue(secondLaunch.settingsDefaults is InMemorySettingsDefaults)
        XCTAssertNil(secondLaunch.settingsDefaults.object(forKey: "barHeight"))
    }

    @MainActor
    func testDemoClipboardMonitoringRequiresExplicitOptIn() {
        let intent = AppLaunchIntent.parse(
            arguments: ["Pesty", "--demo", "--feature-lab-monitor"],
            environment: [:])
        let runtime = AppRuntimeConfiguration.make(for: intent, uniqueProfileID: "capture")

        XCTAssertEqual(intent.mode, .demo(
            featureLabRoot: nil,
            allowsClipboardMonitoring: true))
        XCTAssertTrue(runtime.allowsClipboardMonitoring)
        XCTAssertFalse(runtime.allowsCloudSync)
        XCTAssertFalse(runtime.allowsLaunchAtLogin)
    }

    @MainActor
    func testInMemoryDefaultsRegisterWithoutOverwritingSeed() {
        let defaults = InMemorySettingsDefaults(seed: ["enabled": true])
        defaults.register(defaults: ["enabled": false, "limit": 500])
        defaults.set(720.0, forKey: "height")

        XCTAssertTrue(defaults.bool(forKey: "enabled"))
        XCTAssertEqual(defaults.integer(forKey: "limit"), 500)
        XCTAssertEqual(defaults.double(forKey: "height"), 720)
    }

    @MainActor
    func testMonitorWithNoPasteboardCannotStart() {
        let monitor = ClipboardMonitor(pasteboard: nil)

        monitor.start()

        XCTAssertFalse(monitor.isRunning)
    }
}
