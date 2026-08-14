import CloudKit
import Foundation

enum SyncStatus: Equatable {
    case checking
    case readyForMacBridge
    case unavailable(String)

    var title: String {
        switch self {
        case .checking: "Checking iCloud"
        case .readyForMacBridge: "Ready for sync"
        case .unavailable: "iCloud unavailable"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            "Confirming your iCloud account."
        case .readyForMacBridge:
            "This companion is ready for the shared Pesty-Alvie CloudKit library. The Mac upload bridge is the remaining piece."
        case .unavailable(let message):
            message
        }
    }

    var symbol: String {
        switch self {
        case .checking: "icloud.and.arrow.down"
        case .readyForMacBridge: "icloud.and.arrow.up"
        case .unavailable: "icloud.slash"
        }
    }
}

protocol LibrarySyncing {
    func checkAvailability() async -> SyncStatus
}

/// This intentionally only verifies the iCloud account and does not create a
/// second, incompatible sync format. The future Mac bridge will own the same
/// CloudKit record schema before live synchronization is enabled.
struct CloudKitReadinessChecker: LibrarySyncing {
    static let containerIdentifier = "iCloud.com.alvst.pesty-alvie"

    func checkAvailability() async -> SyncStatus {
        guard Self.hasCloudKitEntitlement else {
            return .unavailable("CloudKit is not enabled in this build yet. Select a development team and enable the Pesty-Alvie iCloud container before testing sync on a device.")
        }
        let container = CKContainer(identifier: Self.containerIdentifier)
        do {
            switch try await container.pestyAccountStatus() {
            case .available:
                return .readyForMacBridge
            case .noAccount:
                return .unavailable("Sign in to iCloud to prepare Pesty-Alvie sync.")
            case .restricted:
                return .unavailable("iCloud is restricted on this device.")
            case .couldNotDetermine:
                return .unavailable("Pesty-Alvie could not determine your iCloud status. Try again when you are online.")
            case .temporarilyUnavailable:
                return .unavailable("iCloud is temporarily unavailable. Try again in a moment.")
            @unknown default:
                return .unavailable("This iCloud account status is not supported yet.")
            }
        } catch {
            return .unavailable("iCloud setup is incomplete for this build. \(error.localizedDescription)")
        }
    }

    private static var hasCloudKitEntitlement: Bool {
        // Simulator builds created with CODE_SIGNING_ALLOWED=NO omit the
        // entitlement, and CloudKit terminates those processes before it can
        // report a recoverable error. A device build gets the entitlement from
        // Pesty-Alvie.entitlements and its provisioning profile.
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }
}

private extension CKContainer {
    func pestyAccountStatus() async throws -> CKAccountStatus {
        try await withCheckedThrowingContinuation { continuation in
            accountStatus { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }
    }
}
