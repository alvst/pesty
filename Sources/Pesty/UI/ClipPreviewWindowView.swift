import SwiftUI

/// The full-size counterpart to Pesty's compact inline preview. Context-menu
/// Preview always opens this independently focusable, read-only surface.
struct ClipPreviewWindowView: View {
    let item: ClipItem
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
                    Text(item.type.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(item.createdAt.clipRelativeLong)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            ScrollView {
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 280)
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
                .foregroundStyle(Theme.textPrimary)
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
        guard item.fileURLs.count == 1,
              let value = item.fileURLs.first,
              let url = URL(string: value),
              url.isFileURL else { return nil }
        return NSImage(contentsOf: url)
    }
}
