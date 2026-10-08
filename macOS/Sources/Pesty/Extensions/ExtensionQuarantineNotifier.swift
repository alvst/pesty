import Foundation
@preconcurrency import UserNotifications

extension Notification.Name {
    static let pestyShowExtensionSettings = Notification.Name(
        "PestyShowExtensionSettings"
    )
}

@MainActor
protocol QuarantineAlerting: AnyObject {
    func postQuarantineAlert(
        extensionID: String,
        extensionName: String,
        reason: ExtensionQuarantineReason
    )
}

/// The production local-notification bridge. Tests inject `QuarantineAlerting`
/// spies into their catalogs, so constructing a test catalog never asks the
/// app-only UserNotifications service for its current notification center.
@MainActor
final class ExtensionQuarantineNotifier: NSObject, QuarantineAlerting {
    private enum AuthorizationState {
        case notRequested
        case requesting
        case authorized
        case denied
    }

    private struct PendingAlert {
        let extensionID: String
        let extensionName: String
        let reason: ExtensionQuarantineReason
    }

    private let center: UNUserNotificationCenter
    private var authorizationState: AuthorizationState = .notRequested
    private var pendingAlerts: [String: PendingAlert] = [:]

    override init() {
        // This initializer is used only by ExtensionCatalog.shared. Unit-test
        // catalogs default to a nil alerting seam and never touch this API.
        center = UNUserNotificationCenter.current()
        super.init()
        center.delegate = self
    }

    func postQuarantineAlert(
        extensionID: String,
        extensionName: String,
        reason: ExtensionQuarantineReason
    ) {
        let alert = PendingAlert(
            extensionID: extensionID,
            extensionName: extensionName,
            reason: reason
        )

        switch authorizationState {
        case .authorized:
            schedule(alert)
        case .denied:
            break
        case .requesting:
            pendingAlerts[extensionID] = alert
        case .notRequested:
            pendingAlerts[extensionID] = alert
            authorizationState = .requesting
            center.requestAuthorization(options: [.alert]) { [weak self] granted, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.authorizationState = granted ? .authorized : .denied
                    let pending = Array(self.pendingAlerts.values)
                    self.pendingAlerts.removeAll()
                    guard granted else { return }
                    pending.forEach(self.schedule)
                }
            }
        }
    }

    private func schedule(_ alert: PendingAlert) {
        let content = UNMutableNotificationContent()
        content.title = "Extension turned off"
        switch alert.reason {
        case .timedOut:
            content.body = "\"\(alert.extensionName)\" was turned off after a timeout. "
                + "Re-enable it in Settings → Extensions."
        case .repeatedExceptions:
            content.body = "\"\(alert.extensionName)\" was turned off after repeated failures. "
                + "Re-enable it in Settings → Extensions."
        }

        // A stable extension identifier keeps a later quarantine from leaving
        // duplicate pending or delivered alerts for the same extension.
        center.removePendingNotificationRequests(withIdentifiers: [alert.extensionID])
        center.removeDeliveredNotifications(withIdentifiers: [alert.extensionID])
        center.add(
            UNNotificationRequest(
                identifier: alert.extensionID,
                content: content,
                trigger: nil
            )
        )
    }
}

extension ExtensionQuarantineNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (
            UNNotificationPresentationOptions
        ) -> Void
    ) {
        completionHandler([.banner])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .pestyShowExtensionSettings, object: nil)
            }
        }
        completionHandler()
    }
}
