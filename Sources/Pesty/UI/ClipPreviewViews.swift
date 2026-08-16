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

/// Compact horizontal favicon/title/host row, used both here and (in a
/// separate PR) on link clip cards. Kept self-contained so this file doesn't
/// depend on that other branch landing first.
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
                    .foregroundStyle(Theme.cardTextPrimary)
                    .lineLimit(compact ? 2 : 3)
                Text(host)
                    .font(.system(size: compact ? 10 : 12))
                    .foregroundStyle(Theme.cardTextSecondary)
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

struct PestyPreviewPopover: View {
    let item: ClipItem
    let pointerOffset: CGFloat

    private var url: URL? {
        guard item.type == .link else { return nil }
        return URL(string: (item.text ?? item.displayTitle).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        VStack(spacing: 0) {
            previewPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.22))
                }
            PreviewPointer()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: 22, height: 11)
                .offset(x: pointerOffset)
        }
        .padding(8)
        .allowsHitTesting(true)
    }

    private var previewPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { AppController.shared.hideInlinePreview() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Text(item.type.label)
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                externalOpenControl
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            Divider()

            Group {
                if let url {
                    WebLinkPreview(url: url)
                } else {
                    SelectedClipPreviewView(item: item)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .padding(12)
        }
    }

    @ViewBuilder
    private var externalOpenControl: some View {
        if let title = InlinePreviewExternalOpener.primaryActionTitle(for: item) {
            let recommendations = InlinePreviewExternalOpener.recommendedApplications(for: item)
            Menu(title) {
                if !recommendations.isEmpty {
                    Section("Suggested Apps") {
                        ForEach(recommendations) { application in
                            Button {
                                InlinePreviewExternalOpener.open(item, with: application)
                            } label: {
                                Label {
                                    Text(application.name)
                                } icon: {
                                    Image(nsImage: application.icon)
                                        .resizable()
                                        .interpolation(.high)
                                        .frame(width: 16, height: 16)
                                }
                            }
                        }
                    }
                    Divider()
                }
                Button("Choose Another App…") {
                    InlinePreviewExternalOpener.chooseAnotherAppAndOpen(item)
                }
            } primaryAction: {
                InlinePreviewExternalOpener.openPrimary(item)
            }
            // SwiftUI can retain the backing NSMenu when this popover changes
            // cards. Key it to the clip so image handlers never leak into a
            // subsequently selected link (and vice versa).
            .id(item.id)
            .menuStyle(.borderedButton)
            .controlSize(.small)
        }
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: item.type.symbol)
                    .foregroundStyle(item.type.accent)
                Text(item.type.label)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.cardTextSecondary)
                Spacer()
                Text(item.createdAt.clipRelativeLong)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.cardTextTertiary)
            }
            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Text(item.displayTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.cardTextSecondary)
                .lineLimit(2)
        }
        .padding(16)
        .frame(width: 340)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.58))
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
            } else { missingPreview("photo") }
        case .richText:
            ScrollView {
                RichTextContent(rtfData: item.rtfData, fallback: item.text ?? "", font: .system(size: 15))
                    .foregroundStyle(Theme.cardTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        case .link:
            VStack(spacing: 14) {
                LinkPreviewContent(text: item.text ?? item.displayTitle, compact: false)
                Text(item.text ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.cardTextSecondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                Spacer()
            }
        case .file:
            if let image = filePreviewImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(item.type.accent)
                    Text(item.displayTitle)
                        .font(.system(size: 14, weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.cardTextPrimary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        case .color:
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(hex: item.colorHex ?? "#000") ?? .black)
                .overlay {
                    Text(item.colorHex ?? "")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
        case .text:
            ScrollView {
                Text(item.text ?? "")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.cardTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private func missingPreview(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 38, weight: .light))
            .foregroundStyle(Theme.cardTextTertiary)
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
