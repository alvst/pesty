import AppKit

@MainActor
enum AppIconProvider {
    private static let pestyBundleID = "com.greycorelabs.pesty"
    private static var cache: [String: NSImage] = [:]

    static func icon(forBundleID bundleID: String?) -> NSImage {
        guard let bundleID else { return generic }
        if let cached = cache[bundleID] { return cached }
        var image = generic
        if bundleID == pestyBundleID || bundleID == Bundle.main.bundleIdentifier {
            image = pestyIcon()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        cache[bundleID] = image
        return image
    }

    private static func pestyIcon() -> NSImage {
        // `NSApp.applicationIconImage` is the generic app-dashed symbol when Pesty
        // is launched with `swift run`. Prefer the bundled icon so copied clips
        // identify Pesty correctly in both the packaged app and development builds.
        if let url = Bundle.main.url(forResource: "Pesty", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            return icon
        }
        // `swift run` launches the bare executable, so it has no application
        // resource bundle. Resolve the packaged asset from this checkout as a
        // development fallback; released copies use the bundle path above.
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let developmentIcon = projectRoot.appending(path: "packaging/Pesty.icns")
        if let icon = NSImage(contentsOf: developmentIcon) {
            return icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pestyBundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSApp.applicationIconImage ?? generic
    }

    static let generic: NSImage =
        NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        ?? NSImage()
}
