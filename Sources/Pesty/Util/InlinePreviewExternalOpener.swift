import AppKit
import UniformTypeIdentifiers

/// Opens inline-preview clips in a chosen native app without exposing Pesty's
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
        .appendingPathComponent("Pesty-Open", isDirectory: true)
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
            .filter { application in
                switch target {
                case .link: declaresWebURLSupport(in: application.url)
                case .text, .image: true
                }
            }
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

    /// Launch Services can report generic document utilities as handlers for a
    /// web URL. The compact link menu should only surface apps that explicitly
    /// declare HTTP or HTTPS URL handling; the full app chooser remains
    /// available for an intentional one-off override.
    private static func declaresWebURLSupport(in applicationURL: URL) -> Bool {
        guard let types = Bundle(url: applicationURL)?
            .object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else { return false }
        return types
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
            .contains { scheme in
                let normalized = scheme.lowercased()
                return normalized == "http" || normalized == "https"
            }
    }

    private static func exportedURL(for item: ClipItem) -> URL? {
        switch item.type {
        case .link:
            return linkURL(for: item)
        case .image:
            guard let source = ClipboardStore.shared.imageURL(for: item) else { return nil }
            return copyToTemporaryLocation(source, named: item.displayTitle)
        case .file:
            guard let source = imageFileURL(for: item) else { return nil }
            return copyToTemporaryLocation(source, named: item.displayTitle)
        case .richText:
            guard let data = item.rtfData else { return nil }
            return write(data, named: item.displayTitle, fileExtension: "rtf")
        case .text:
            return write(Data((item.text ?? "").utf8), named: item.displayTitle, fileExtension: "txt")
        case .color:
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

    private static func imageFileURL(for item: ClipItem) -> URL? {
        if item.type == .image {
            guard let url = ClipboardStore.shared.imageURL(for: item),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }

        guard item.type == .file,
              item.fileURLs.count == 1,
              let value = item.fileURLs.first,
              let url = URL(string: value),
              url.isFileURL,
              UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return nil }
        return url
    }

    private static func copyToTemporaryLocation(_ source: URL, named title: String) -> URL? {
        guard let data = try? Data(contentsOf: source) else { return nil }
        let fileExtension = source.pathExtension.isEmpty ? "png" : source.pathExtension
        return write(data, named: title, fileExtension: fileExtension)
    }

    private static func write(_ data: Data, named title: String, fileExtension: String) -> URL? {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: temporaryDirectory,
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }

        let safeTitle = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = safeTitle.isEmpty ? "Clip" : String(safeTitle.prefix(80))
        let url = temporaryDirectory
            .appendingPathComponent("\(baseName)-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        do {
            try data.write(to: url, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
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
