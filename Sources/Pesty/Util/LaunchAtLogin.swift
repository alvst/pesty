import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLogin {
    static func set(enabled: Bool) {
        guard AppRuntime.current.allowsLaunchAtLogin else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("Pesty: LaunchAtLogin toggle failed: \(error.localizedDescription)")
        }
    }

    static var isEnabled: Bool {
        guard AppRuntime.current.allowsLaunchAtLogin else { return false }
        return SMAppService.mainApp.status == .enabled
    }
}
