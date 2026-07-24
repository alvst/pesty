import AppKit
import SwiftUI
import WebKit

struct RichTextContent: View {
    let rtfData: Data?
    let fallback: String
    var font: Font = .system(size: 13)
    var lineLimit: Int? = nil

    var body: some View {
        Group {
            if let richText {
                Text(richText)
            } else {
                Text(fallback)
            }
        }
        .font(font)
        .lineLimit(lineLimit)
        .multilineTextAlignment(.leading)
    }

    private var richText: AttributedString? {
        guard let rtfData,
              let value = try? NSAttributedString(data: rtfData,
                                                  options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                  documentAttributes: nil) else { return nil }
        return AttributedString(value)
    }
}

struct LinkPreviewContent: View {
    let text: String
    let compact: Bool
    private let previews = LinkPreviewStore.shared

    private var url: URL? { URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var preview: LinkPreview? { previews.preview(for: url) }
    private var host: String { url?.host ?? text }

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            icon
            VStack(alignment: .leading, spacing: compact ? 2 : 5) {
                Text(preview?.title ?? host)
                    .font(.system(size: compact ? 12 : 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(compact ? 2 : 3)
                Text(host)
                    .font(.system(size: compact ? 10 : 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .onAppear { previews.load(for: url) }
    }

    @ViewBuilder
    private var icon: some View {
        if let image = preview?.icon {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: compact ? 28 : 42, height: compact ? 28 : 42)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 10, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: compact ? 6 : 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
                .frame(width: compact ? 28 : 42, height: compact ? 28 : 42)
                .overlay {
                    Image(systemName: "link")
                        .font(.system(size: compact ? 12 : 17, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
        }
    }
}

struct LinkCardPreview: View {
    let text: String
    private let previews = LinkPreviewStore.shared

    private var url: URL? { URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var preview: LinkPreview? { previews.preview(for: url) }
    private var host: String { url?.host ?? text }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let image = preview?.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                        .overlay {
                            Image(systemName: "link")
                                .font(.system(size: 26, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 7) {
                if let icon = preview?.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Image(systemName: "link")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 16, height: 16)
                }
                Text(preview?.title ?? host)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
            }
        }
        .onAppear { previews.load(for: url) }
    }
}

struct PestyPreviewPopover: View {
    let item: ClipItem
    let pointerOffset: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @State private var hasAppeared = false

    private var url: URL? {
        guard item.type == .link else { return nil }
        return URL(string: (item.text ?? item.displayTitle).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var surfaceColor: Color { Color(nsColor: .windowBackgroundColor) }
    private var documentColor: Color { Color(nsColor: .textBackgroundColor) }
    private var chromeBorder: Color {
        colorScheme == .dark ? .white.opacity(0.16) : .black.opacity(0.13)
    }

    var body: some View {
        VStack(spacing: 0) {
            previewPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(surfaceColor, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(chromeBorder)
                }
            PreviewPointer()
                .fill(surfaceColor)
                .frame(width: 26, height: 12)
                .offset(x: pointerOffset)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.84, anchor: .bottom)
        .offset(y: hasAppeared ? 0 : 24)
        .onAppear {
            withAnimation(.spring(response: 0.44, dampingFraction: 0.62, blendDuration: 0.12)) {
                hasAppeared = true
            }
        }
        .allowsHitTesting(true)
    }

    private var previewPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Button { AppController.shared.hideInlinePreview() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Text(item.presentationType.label)
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                Menu {
                    Button("Copy") { AppController.shared.copyItem(item) }
                    Button("Paste") { AppController.shared.pasteItem(item) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                if let url {
                    Button("Open in Safari") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 56)

            Divider().overlay(chromeBorder)

            Group {
                if let url {
                    WebLinkPreview(url: url)
                } else {
                    SelectedClipPreviewView(item: item)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(documentColor, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 12)

            PreviewMetadataFooter(item: item)
                .padding(.horizontal, 22)
                .frame(height: 42)
        }
    }
}

private struct PreviewMetadataFooter: View {
    let item: ClipItem

    private var metrics: [String] {
        if item.isImageFile {
            return ["Image", item.createdAt.clipRelativeLong]
        }
        switch item.type {
        case .text, .richText, .link:
            let text = item.text ?? ""
            let characters = text.count
            let words = text.split { $0.isWhitespace || $0.isNewline }.count
            let lines = max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)
            return [
                "\(characters) character\(characters == 1 ? "" : "s")",
                "\(words) word\(words == 1 ? "" : "s")",
                "\(lines) line\(lines == 1 ? "" : "s")"
            ]
        case .image:
            return ["Image", item.createdAt.clipRelativeLong]
        case .file:
            return ["\(item.fileURLs.count) file\(item.fileURLs.count == 1 ? "" : "s")", item.createdAt.clipRelativeLong]
        case .color:
            return [item.colorHex ?? "Color", item.createdAt.clipRelativeLong]
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(metrics.enumerated()), id: \.offset) { index, metric in
                if index > 0 {
                    Text("·")
                        .foregroundStyle(.tertiary)
                }
                Text(metric)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

private struct WebLinkPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}

private struct PreviewPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct SelectedClipPreviewView: View {
    let item: ClipItem
    private var store: ClipboardStore { ClipboardStore.shared }

    var body: some View {
        previewContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var previewContent: some View {
        switch item.type {
        case .image:
            if let image = store.loadImage(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(14)
            } else { missingPreview("photo") }
        case .richText:
            ScrollView {
                RichTextContent(rtfData: item.rtfData, fallback: item.text ?? "", font: .system(size: 26))
                    .foregroundStyle(Color.primary)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(28)
            }
        case .link:
            LinkPreviewContent(text: item.text ?? item.displayTitle, compact: false)
                .padding(28)
        case .file:
            if let image = filePreviewImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(14)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(item.type.accent)
                    Text(item.displayTitle)
                        .font(.system(size: 18, weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.primary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .color:
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(hex: item.colorHex ?? "#000") ?? .black)
                .overlay {
                    Text(item.colorHex ?? "")
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
                .padding(22)
        case .text:
            ScrollView {
                Text(item.text ?? "")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(Color.primary)
                    .lineSpacing(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(28)
            }
        }
    }

    private func missingPreview(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 44, weight: .light))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filePreviewImage: NSImage? {
        guard item.fileURLs.count == 1,
              let value = item.fileURLs.first,
              let url = URL(string: value),
              url.isFileURL else { return nil }
        return NSImage(contentsOf: url)
    }
}
