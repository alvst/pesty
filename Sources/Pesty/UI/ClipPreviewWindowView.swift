import SwiftUI

/// The full-size counterpart to Pesty's compact inline preview. Context-menu
/// Preview always opens this independently focusable, read-only surface.
struct ClipPreviewWindowView: View {
    let item: ClipItem
    let onSave: () -> Void
    private var store: ClipboardStore { ClipboardStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: item.type.symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(item.type.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle)
                        .font(.headline)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(item.type.label)
                        Text("·")
                        Text(item.createdAt.clipRelativeLong)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if let openTitle = InlinePreviewExternalOpener.primaryActionTitle(for: item) {
                    Button {
                        InlinePreviewExternalOpener.openPrimary(item)
                    } label: {
                        Label("Open", systemImage: "arrow.up.forward.square")
                    }
                    .keyboardShortcut("o", modifiers: .command)
                    .help("\(openTitle) (⌘O)")
                    .accessibilityLabel(openTitle)
                    .fixedSize()
                }
                Button(action: onSave) {
                    Label("Save…", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("s", modifiers: .command)
                .help("Save a copy to a file (⌘S)")
                .fixedSize()
            }

            Divider()

            ScrollView {
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 280)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var preview: some View {
        switch item.type {
        case .image:
            if let image = store.loadImage(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                unavailable("The original image is no longer available.")
            }
        case .color:
            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(hex: item.colorHex ?? "#000000") ?? .black)
                    .frame(height: 180)
                Text(item.colorHex ?? "Color")
                    .font(.system(.title3, design: .monospaced))
                    .textSelection(.enabled)
            }
        case .file:
            if let image = filePreviewImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(item.fileURLs, id: \.self) { value in
                        let url = URL(string: value)
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "doc")
                                .foregroundStyle(.secondary)
                            Text(url?.path ?? value)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        case .richText:
            RichTextContent(rtfData: item.rtfData, fallback: item.text ?? "", font: .system(size: 15))
                .textSelection(.enabled)
        case .link:
            VStack(alignment: .leading, spacing: 14) {
                LinkPreviewContent(text: item.text ?? item.displayTitle, compact: false)
                Text(item.text ?? "")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .text:
            if let text = item.text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                unavailable("This clip has no text to preview.")
            }
        }
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView("Preview Unavailable",
                               systemImage: "eye.slash",
                               description: Text(message))
    }

    private var filePreviewImage: NSImage? {
        store.loadPreviewImage(for: item)
    }
}

/// Presents save sheets on the preview that owns the action, even if another
/// Pesty window has since taken keyboard focus.
@MainActor
enum ClipPreviewSaver {
    static func save(_ item: ClipItem, in window: NSWindow, store: ClipboardStore) {
        guard window.attachedSheet == nil else { return }
        do {
            let exports = try ClipPreviewExport.prepare(for: item, store: store)
            NSApp.activate(ignoringOtherApps: true)
            save(exports[...], in: window)
        } catch {
            show(error, in: window)
        }
    }

    private static func save(_ exports: ArraySlice<ClipPreviewExport>, in window: NSWindow) {
        guard let export = exports.first else { return }
        let panel = NSSavePanel()
        panel.title = "Save a Copy"
        panel.nameFieldStringValue = export.suggestedFileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if exports.count > 1 {
            panel.message = "Choose where to save “\(export.suggestedFileName)”. Each file will be saved separately."
        }
        if let type = export.contentType {
            panel.allowedContentTypes = [type]
            panel.allowsOtherFileTypes = false
        }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = panel.url else { return }
            let accessed = destination.startAccessingSecurityScopedResource()
            defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
            do {
                try export.write(to: destination)
                // Let the completed sheet leave the window before presenting
                // the next one for a clip containing several files.
                DispatchQueue.main.async {
                    save(exports.dropFirst(), in: window)
                }
            } catch {
                DispatchQueue.main.async { show(error, in: window) }
            }
        }
    }

    private static func show(_ error: Error, in window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t Save Clip"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}
