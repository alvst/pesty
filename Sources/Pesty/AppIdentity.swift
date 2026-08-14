import Foundation

/// Stable identity for Alvie's personal build. Keep these values distinct from
/// upstream Pesty so both applications can be installed and run side by side.
enum AppIdentity {
    static let displayName = "Pesty-Alvie"
    static let bundleIdentifier = "com.alvst.pesty-alvie"
    static let storageDirectoryName = "Pesty-Alvie"
    static let quickLookDirectoryName = "Pesty-Alvie-QuickLook"
    static let externalPreviewDirectoryName = "Pesty-Alvie-Open"
}
