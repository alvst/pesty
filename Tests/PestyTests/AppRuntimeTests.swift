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
    func testDemoConfigurationUsesNestedStorageAndMemoryDefaults() {
        let intent = AppLaunchIntent(mode: .demo(
            featureLabRoot: "/tmp/build-03",
            allowsClipboardMonitoring: false))
        let runtime = AppRuntimeConfiguration.make(
            for: intent,
            temporaryDirectory: URL(fileURLWithPath: "/unused"),
            uniqueProfileID: "unused")

        XCTAssertTrue(runtime.isDemo)
        XCTAssertEqual(
            runtime.storageBaseURL?.path,
            "/tmp/build-03/Pesty-FeatureLab/Library/Application Support/Pesty")
        XCTAssertFalse(runtime.allowsClipboardMonitoring)
        XCTAssertTrue(runtime.allowsGlobalHotKey)
        XCTAssertFalse(runtime.allowsCloudSync)
        XCTAssertFalse(runtime.allowsLaunchAtLogin)
        XCTAssertFalse(runtime.settingsDefaults.bool(forKey: "iCloudSync"))
        XCTAssertFalse(runtime.settingsDefaults.bool(forKey: "cloudKitSync"))
        XCTAssertTrue(runtime.settingsDefaults.bool(forKey: "onboarded"))
        XCTAssertEqual(runtime.settingsDefaults.integer(forKey: "hotkeyKeyCode"), 9)
        XCTAssertEqual(runtime.settingsDefaults.integer(forKey: "hotkeyModifiers"), 4_864)
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
