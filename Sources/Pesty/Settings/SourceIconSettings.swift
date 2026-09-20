import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Optional, local-only source icon overrides. Keeping the files outside the
/// clipboard library makes this experiment independent from history and sync.
@Observable
@MainActor
final class SourceIconOverrides {
    static let shared = SourceIconOverrides()

    private let defaultsKey = "sourceIconOverrideFiles"
    private let directory = ClipboardStore.localBase.appendingPathComponent("source-icons", isDirectory: true)
    private(set) var files: [String: String]
    @ObservationIgnored private var imageCache: [String: NSImage] = [:]

    private init() {
        files = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    var bundleIDs: [String] {
        Set(files.keys.map { $0.split(separator: "|", maxSplits: 1).first.map(String.init) ?? String($0) })
            .sorted()
    }

    func hasOverride(for bundleID: String) -> Bool {
        files[bundleID] != nil || files[fileKey(bundleID, .light)] != nil || files[fileKey(bundleID, .dark)] != nil
    }

    func icon(for bundleID: String, appearance requestedAppearance: IconAppearance? = nil) -> NSImage? {
        let appearance = requestedAppearance ?? currentAppearance
        let file = files[fileKey(bundleID, appearance)]
            ?? files[bundleID] // Legacy single-image override.
        guard let file else { return nil }
        let cacheKey = "\(bundleID)|\(appearance.rawValue)|\(file)"
        if let cached = imageCache[cacheKey] { return cached }
        guard let image = NSImage(contentsOf: directory.appendingPathComponent(file)) else { return nil }
        imageCache[cacheKey] = image
        return image
    }

    func setIcon(from sourceURL: URL, for bundleID: String, appearance: IconAppearance) throws {
        guard NSImage(contentsOf: sourceURL) != nil else { throw IconError.unreadable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
        let file = "\(UUID().uuidString).\(ext)"
        try Data(contentsOf: sourceURL).write(to: directory.appendingPathComponent(file), options: .atomic)
        removeStoredFile(for: bundleID, appearance: appearance)
        files[fileKey(bundleID, appearance)] = file
        persistAndRefresh(bundleID)
    }

    func removeOverride(for bundleID: String) {
        removeStoredFile(for: bundleID)
        files.removeValue(forKey: fileKey(bundleID, .light))
        files.removeValue(forKey: fileKey(bundleID, .dark))
        files.removeValue(forKey: bundleID)
        persistAndRefresh(bundleID)
    }

    private func removeStoredFile(for bundleID: String) {
        for appearance in [IconAppearance.light, .dark] {
            removeStoredFile(for: bundleID, appearance: appearance)
        }
        if let file = files[bundleID] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    private func removeStoredFile(for bundleID: String, appearance: IconAppearance) {
        guard let file = files[fileKey(bundleID, appearance)] else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
    }

    private func fileKey(_ bundleID: String, _ appearance: IconAppearance) -> String {
        "\(bundleID)|\(appearance.rawValue)"
    }

    var currentAppearance: IconAppearance {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    private func persistAndRefresh(_ bundleID: String) {
        UserDefaults.standard.set(files, forKey: defaultsKey)
        imageCache.keys.filter { $0.hasPrefix("\(bundleID)|") }.forEach { imageCache.removeValue(forKey: $0) }
        AppIconProvider.invalidate(bundleID: bundleID)
        SourceColor.invalidate(bundleID: bundleID)
    }

    enum IconError: LocalizedError {
        case unreadable
        var errorDescription: String? { "That file could not be read as an image." }
    }

    enum IconAppearance: String { case light, dark }
}

struct SourceIconSettings: View {
    @Bindable private var overrides = SourceIconOverrides.shared
    @Bindable private var clipboard = ClipboardStore.shared
    @Bindable private var pasteStack = PasteSequence.shared
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                Text("Source App Icons").font(.system(size: 16, weight: .semibold))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Choose the icon Pesty uses on cards from each app. Card colors are sampled from the chosen icon too.")
                        .font(.caption).foregroundStyle(.secondary).padding(.vertical, 10)
                    ForEach(sourceApps) { app in
                        Divider()
                        sourceRow(app)
                    }
                    Divider()
                    Button { addApplication() } label: { Label("Add Source App…", systemImage: "plus") }
                        .padding(.vertical, 10)
                }
                .padding(.horizontal, 16).padding(.vertical, 4)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)) }
            }
            .frame(maxWidth: 548, alignment: .leading).padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .alert("Could Not Set Icon", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "Unknown error") }
    }

    private func sourceRow(_ app: SourceApplication) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIconProvider.icon(forBundleID: app.id))
                .resizable().interpolation(.high).frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.system(size: 13, weight: .medium))
                Text(overrides.hasOverride(for: app.id) ? "Custom icon" : "System app icon")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if overrides.hasOverride(for: app.id) {
                Button("Reset") { overrides.removeOverride(for: app.id) }
            }
            Menu("Choose…") {
                Button("Light Mode…") { chooseIcon(for: app, appearance: .light) }
                Button("Dark Mode…") { chooseIcon(for: app, appearance: .dark) }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 8)
    }

    private var sourceApps: [SourceApplication] {
        let items = clipboard.history
            + clipboard.pinboards.flatMap(\.items)
            + pasteStack.entries.map(\.item)
            + pasteStack.savedStacks.flatMap { $0.entries.map(\.item) }
        // loginwindow can arrive from older/system metadata either as its full
        // bundle ID or as the short executable name. Never expose either form
        // as a configurable source-app icon.
        let hiddenBundleIDs: Set<String> = ["com.apple.loginwindow", "loginwindow"]
        var names = Dictionary(uniqueKeysWithValues: overrides.bundleIDs
            .filter { !hiddenBundleIDs.contains($0.lowercased()) }
            .map { ($0, applicationName($0)) })
        for item in items {
            guard let id = item.sourceBundleID, !id.isEmpty else { continue }
            guard !hiddenBundleIDs.contains(id.lowercased()) else { continue }
            names[id] = item.sourceAppName ?? names[id] ?? applicationName(id)
        }
        return names.map { SourceApplication(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func addApplication() {
        let panel = NSOpenPanel()
        panel.title = "Add Source App"
        panel.prompt = "Add App"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier else { return }
        chooseIcon(for: SourceApplication(id: id, name: applicationName(id)), appearance: .light)
    }

    private func chooseIcon(for app: SourceApplication, appearance: SourceIconOverrides.IconAppearance) {
        let panel = NSOpenPanel()
        panel.title = "Choose \(appearance.rawValue.capitalized) Icon for \(app.name)"
        panel.message = "Choose the image Pesty should use for clips from \(app.name) in \(appearance.rawValue) mode."
        panel.prompt = "Use Icon"
        panel.allowedContentTypes = [.image]
        panel.directoryURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id)
            .flatMap { Bundle(url: $0)?.resourceURL }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try overrides.setIcon(from: url, for: app.id, appearance: appearance) }
        catch { errorMessage = error.localizedDescription }
    }

    private func applicationName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url) else { return bundleID }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? bundleID
    }
}

private struct SourceApplication: Identifiable {
    let id: String
    let name: String

    init(id: String, name: String) { self.id = id; self.name = name }
}
