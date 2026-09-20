import UIKit
import UniformTypeIdentifiers
import WidgetKit

final class ShareViewController: UIViewController {
    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()
    private let cancelButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        Task { await importSharedItems() }
    }

    private func configureView() {
        view.backgroundColor = .systemGroupedBackground
        spinner.startAnimating()

        statusLabel.text = "Saving to Pesty…"
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [spinner, statusLabel, cancelButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28)
        ])
    }

    @objc private func cancel() {
        extensionContext?.cancelRequest(withError: CancellationError())
    }

    @MainActor
    private func importSharedItems() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .compactMap(\.attachments)
            .flatMap { $0 }
        do {
            var clips: [PestyClip] = []
            for provider in providers.prefix(20) {
                if let clip = try await clip(from: provider) { clips.append(clip) }
            }
            guard !clips.isEmpty else { throw ShareError.unsupported }
            try LocalLibraryPersistence.update { library in
                clips.forEach { library.upsert($0) }
            }
            WidgetCenter.shared.reloadAllTimelines()
            spinner.stopAnimating()
            spinner.isHidden = true
            statusLabel.text = clips.count == 1 ? "Saved to Pesty" : "Saved \(clips.count) clips to Pesty"
            cancelButton.setTitle("Done", for: .normal)
            cancelButton.removeTarget(self, action: #selector(cancel), for: .touchUpInside)
            cancelButton.addTarget(self, action: #selector(done), for: .touchUpInside)
        } catch {
            spinner.stopAnimating()
            spinner.isHidden = true
            statusLabel.text = error.localizedDescription
            cancelButton.setTitle("Close", for: .normal)
        }
    }

    @objc private func done() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func clip(from provider: NSItemProvider) async throws -> PestyClip? {
        let now = Date.now
        let sourceDevice = UIDevice.current.name

        if provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier),
           let richText = try? await loadData(from: provider, type: .rtf) {
            let plainText = (try? await loadString(from: provider))
                ?? (try? NSAttributedString(
                    data: richText,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil
                ).string)
            return PestyClip(
                kind: .richText,
                text: plainText,
                richTextData: richText,
                sourceAppName: "Share Sheet",
                sourceDeviceName: sourceDevice,
                capturedAt: now,
                updatedAt: now
            )
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = try? await loadData(from: provider, type: .image) {
            let stored = try LocalAssetPersistence.storeImageData(data)
            return PestyClip(
                kind: .image,
                imageAssetID: stored.name,
                imageHash: stored.hash,
                sourceAppName: "Share Sheet",
                sourceDeviceName: sourceDevice,
                capturedAt: now,
                updatedAt: now
            )
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = try? await loadURL(from: provider, type: .fileURL) {
            return PestyClip(
                kind: .file,
                fileNames: [url.lastPathComponent],
                sourceAppName: "Share Sheet",
                sourceDeviceName: sourceDevice,
                sourceFileURLs: [url.absoluteString],
                capturedAt: now,
                updatedAt: now
            )
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = try? await loadURL(from: provider, type: .url) {
            return PestyClip(
                kind: url.isFileURL ? .file : .link,
                text: url.isFileURL ? nil : url.absoluteString,
                fileNames: url.isFileURL ? [url.lastPathComponent] : [],
                sourceAppName: "Share Sheet",
                sourceDeviceName: sourceDevice,
                sourceFileURLs: url.isFileURL ? [url.absoluteString] : nil,
                capturedAt: now,
                updatedAt: now
            )
        }

        if let text = try? await loadString(from: provider) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(string: trimmed)
            let isWebURL = ["http", "https"].contains(url?.scheme?.lowercased() ?? "")
            let isColor = trimmed.range(of: #"^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$"#, options: .regularExpression) != nil
            return PestyClip(
                kind: isColor ? .color : (isWebURL ? .link : .text),
                text: isColor ? nil : text,
                colorHex: isColor ? trimmed.uppercased() : nil,
                sourceAppName: "Share Sheet",
                sourceDeviceName: sourceDevice,
                capturedAt: now,
                updatedAt: now
            )
        }

        return nil
    }

    private func loadData(from provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? ShareError.unavailable) }
            }
        }
    }

    private func loadURL(from provider: NSItemProvider, type: UTType) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier) { item, error in
                if let url = item as? URL { continuation.resume(returning: url) }
                else if let url = item as? NSURL { continuation.resume(returning: url as URL) }
                else if let data = item as? Data,
                        let value = String(data: data, encoding: .utf8),
                        let url = URL(string: value) { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? ShareError.unavailable) }
            }
        }
    }

    private func loadString(from provider: NSItemProvider) async throws -> String {
        let type = provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier)
            ? UTType.utf8PlainText
            : .plainText
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier) { item, error in
                if let string = item as? String { continuation.resume(returning: string) }
                else if let string = item as? NSString { continuation.resume(returning: string as String) }
                else if let data = item as? Data,
                        let string = String(data: data, encoding: .utf8) { continuation.resume(returning: string) }
                else { continuation.resume(throwing: error ?? ShareError.unavailable) }
            }
        }
    }
}

private enum ShareError: LocalizedError {
    case unavailable
    case unsupported

    var errorDescription: String? {
        switch self {
        case .unavailable: "The shared item is no longer available."
        case .unsupported: "Pesty could not find text, a link, an image, or a file to save."
        }
    }
}
