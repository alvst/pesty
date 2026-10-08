import AppKit
import UniformTypeIdentifiers

/// Opens preview clips in a chosen native app without exposing Pesty's
/// managed history files to edits made by that app.
@MainActor
enum InlinePreviewExternalOpener {
    struct RecommendedApplication: Identifiable {
        let url: URL
        let bundleIdentifier: String
        let name: String
        let icon: NSImage

        var id: String { bundleIdentifier }

        init?(url: URL) {
            guard let bundle = Bundle(url: url),
                  let bundleIdentifier = bundle.bundleIdentifier else { return nil }
            self.url = url
            self.bundleIdentifier = bundleIdentifier
            name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            icon = NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    private static let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(AppIdentity.externalPreviewDirectoryName, isDirectory: true)
    private static let maximumRecommendedApplications = 10

    static func primaryActionTitle(for item: ClipItem) -> String? {
        guard let target = target(for: item),
              let application = primaryApplication(for: target) else { return nil }
        return "Open in \(applicationName(for: application))"
    }

    static func openPrimary(_ item: ClipItem) {
        guard let target = target(for: item),
              let application = primaryApplication(for: target),
              let contentURL = exportedURL(for: item) else { return }
        open(contentURL, withApplication: application)
    }

    /// A short, useful subset of the system's compatible handlers. The full
    /// chooser remains available below it so this menu does not become a long
    /// generic app launcher.
    static func recommendedApplications(for item: ClipItem) -> [RecommendedApplication] {
        guard let target = target(for: item) else { return [] }

        let applicationURLs: [URL]
        switch target {
        case .link:
            guard let url = linkURL(for: item) else { return [] }
            applicationURLs = NSWorkspace.shared.urlsForApplications(toOpen: url)
        case .text:
            let type: UTType = item.type == .richText ? .rtf : .plainText
            applicationURLs = NSWorkspace.shared.urlsForApplications(toOpen: type)
        case .image:
            guard let imageURL = imageFileURL(for: item) else { return [] }
            let type = UTType(filenameExtension: imageURL.pathExtension) ?? .image
            applicationURLs = NSWorkspace.shared.urlsForApplications(toOpen: type)
        }

        var excludedBundleIDs = [Settings.shared.previewApplicationBundleID(for: target)]
        if let primary = primaryApplication(for: target),
           let bundleID = Bundle(url: primary)?.bundleIdentifier {
            excludedBundleIDs.append(bundleID)
        }

        var seen = Set<String>()
        return applicationURLs.compactMap(RecommendedApplication.init(url:))
            .filter { !excludedBundleIDs.contains($0.bundleIdentifier) }
            .filter { seen.insert($0.bundleIdentifier).inserted }
            .prefix(maximumRecommendedApplications)
            .map { $0 }
    }

    static func open(_ item: ClipItem, with application: RecommendedApplication) {
        guard let contentURL = exportedURL(for: item) else { return }
        open(contentURL, withApplication: application.url)
    }

    /// Presents a one-time app chooser. It does not change the default selected
    /// in Settings, so the compact preview menu stays short and predictable.
    static func chooseAnotherAppAndOpen(_ item: ClipItem) {
        guard target(for: item) != nil else { return }

        let panel = NSOpenPanel()
        panel.title = "Open \(item.type.label) With"
        panel.message = "Choose an app for this clip. This will not change your default."
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK,
              let application = panel.url,
              let contentURL = exportedURL(for: item) else { return }
        open(contentURL, withApplication: application)
    }

    private static func target(for item: ClipItem) -> PreviewOpenTarget? {
        switch item.type {
        case .text, .richText:
            return .text
        case .image:
            return imageFileURL(for: item) == nil ? nil : .image
        case .file:
            return imageFileURL(for: item) == nil ? nil : .image
        case .link:
            return linkURL(for: item) == nil ? nil : .link
        case .color:
            return nil
        }
    }

    private static func primaryApplication(for target: PreviewOpenTarget) -> URL? {
        let configuredBundleID = Settings.shared.previewApplicationBundleID(for: target)
        if let configured = NSWorkspace.shared.urlForApplication(withBundleIdentifier: configuredBundleID) {
            return configured
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.defaultApplicationBundleID)
    }

    static func exportedURL(for item: ClipItem, store: ClipboardStore? = nil) -> URL? {
        if item.type == .link { return linkURL(for: item) }
        guard item.type != .color,
              item.type != .file || imageFileURL(for: item, store: store) != nil else { return nil }

        // Share Save's lossless export, including cached screenshots and their
        // actual image formats. External edits only touch this temporary copy.
        let directory = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            guard let export = try ClipPreviewExport.prepare(for: item, store: store ?? .shared).first else {
                return nil
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent(export.suggestedFileName)
            try export.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    private static func linkURL(for item: ClipItem) -> URL? {
        guard item.type == .link,
              let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return nil }
        return url
    }

    private static func imageFileURL(for item: ClipItem, store: ClipboardStore? = nil) -> URL? {
        if item.type == .image {
            guard let url = (store ?? .shared).imageURL(for: item),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }

        guard item.type == .file, item.fileURLs.count == 1 else { return nil }
        if let value = item.fileURLs.first,
           let url = URL(string: value), url.isFileURL,
           UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            return url
        }
        if let cached = (store ?? .shared).imageURL(for: item),
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        return nil
    }

    private static func open(_ contentURL: URL, withApplication applicationURL: URL) {
        AppController.shared.hideBar(immediately: true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.open([contentURL], withApplicationAt: applicationURL, configuration: configuration)
    }

    private static func applicationName(for applicationURL: URL) -> String {
        let bundle = Bundle(url: applicationURL)
        return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? applicationURL.deletingPathExtension().lastPathComponent
    }
}
