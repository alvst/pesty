import Foundation
import Observation

@Observable
@MainActor
final class ExtensionCatalog {
    static let sharedHost = ExtensionHost()
    static let shared = ExtensionCatalog(
        directory: ClipboardStore.localBase.appendingPathComponent("extensions", isDirectory: true),
        host: sharedHost
    )

    private(set) var extensions: [InstalledExtension] = []
    @ObservationIgnored var onExtensionInvalidated: ((String) -> Void)?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let storeURL: URL
    @ObservationIgnored private let host: ExtensionHost

    init(directory: URL, host: ExtensionHost = ExtensionHost()) {
        self.directory = directory
        self.storeURL = directory.appendingPathComponent("extensions.json")
        self.host = host

        prepareDirectory()
        if FileManager.default.fileExists(atPath: storeURL.path) {
            load()
        } else {
            seedBundledExtensions()
            saveNow()
        }

        host.onQuarantine = { [weak self] id in
            self?.autoDisableQuarantinedExtension(id: id)
        }
    }

    var enabledExtensions: [InstalledExtension] {
        extensions.filter { $0.enabled && !host.isQuarantined($0.id) }
    }

    func isQuarantined(_ id: String) -> Bool {
        host.isQuarantined(id)
    }

    func install(source: String) -> Result<ExtensionManifest, ExtensionError> {
        switch host.validate(source: source) {
        case .failure(let error):
            return .failure(error)
        case .success(let manifest):
            let replaced: Bool
            if let index = extensions.firstIndex(where: { $0.id == manifest.id }) {
                extensions[index].manifest = manifest
                extensions[index].source = source
                replaced = true
            } else {
                extensions.append(
                    InstalledExtension(
                        manifest: manifest,
                        source: source,
                        enabled: false,
                        isBundled: false,
                        installedAt: .now
                    )
                )
                replaced = false
            }
            sortExtensions()
            saveNow()
            if replaced { onExtensionInvalidated?(manifest.id) }
            return .success(manifest)
        }
    }

    func uninstall(id: String) {
        let oldCount = extensions.count
        extensions.removeAll { $0.id == id }
        guard extensions.count != oldCount else { return }
        // Bundled extensions are seeded only when no catalog file exists.
        saveNow()
        onExtensionInvalidated?(id)
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard let index = extensions.firstIndex(where: { $0.id == id }) else { return }

        let enabledChanged = extensions[index].enabled != enabled
        let clearsAutoDisable = enabled && extensions[index].autoDisabledAt != nil
        if enabled {
            host.liftQuarantine(id)
            extensions[index].autoDisabledAt = nil
        }
        let persistsAutoDisable = !enabled && extensions[index].autoDisabledAt != nil
        guard enabledChanged || clearsAutoDisable || persistsAutoDisable else { return }

        extensions[index].enabled = enabled
        saveNow()
        if !enabled { onExtensionInvalidated?(id) }
    }

    private func autoDisableQuarantinedExtension(id: String) {
        guard let index = extensions.firstIndex(where: { $0.id == id }) else { return }
        extensions[index].autoDisabledAt = .now
        setEnabled(false, id: id)
    }

    private func prepareDirectory() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([InstalledExtension].self, from: data) else {
            extensions = []
            return
        }
        extensions = decoded
        sortExtensions()
    }

    private func seedBundledExtensions() {
        guard case .success(let manifest) = host.validate(source: BundledExtensions.tokenCount) else {
            return
        }
        extensions = [
            InstalledExtension(
                manifest: manifest,
                source: BundledExtensions.tokenCount,
                enabled: false,
                isBundled: true,
                installedAt: .now
            )
        ]
    }

    private func sortExtensions() {
        extensions.sort {
            if $0.installedAt == $1.installedAt {
                return $0.id < $1.id
            }
            return $0.installedAt < $1.installedAt
        }
    }

    private func saveNow() {
        guard let data = try? JSONEncoder().encode(extensions) else { return }
        do {
            try data.write(to: storeURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storeURL.path
            )
        } catch {
            return
        }
    }
}
