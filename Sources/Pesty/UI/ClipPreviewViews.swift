import AppKit
import SwiftUI
import WebKit

/// Display-only color correction. Never write this attributed string back to
/// the clip: its original colors still belong on the pasteboard and in RTF.
enum RichTextPreview {
    enum Surface {
        case card
        case inline
        case window

        var background: NSColor {
            switch self {
            // These are the darkest possible composites of each white fill,
            // even over a black desktop. Readable dark ink also works over
            // every lighter backdrop without having to sample the screen.
            case .card: NSColor(srgbRed: 0.94, green: 0.94, blue: 0.94, alpha: 1)
            case .inline: NSColor(srgbRed: 0.58, green: 0.58, blue: 0.58, alpha: 1)
            case .window: .windowBackgroundColor
            }
        }
    }

    static func readable(_ source: NSAttributedString,
                         on background: NSColor,
                         appearance: NSAppearance) -> NSAttributedString {
        let preview = NSMutableAttributedString(attributedString: source)
        appearance.performAsCurrentDrawingAppearance {
            let surface = Color(nsColor: background)
            source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
                let runSurface: Color
                if let highlight = attributes[.backgroundColor] as? NSColor {
                    runSurface = Contrast.composite(Color(nsColor: highlight), over: surface)
                    // Flatten translucent highlights so the corrected ink and
                    // the highlight are measured against the same background.
                    preview.addAttribute(.backgroundColor, value: NSColor(runSurface), range: range)
                } else {
                    runSurface = surface
                }
                let original = (attributes[.foregroundColor] as? NSColor)
                    .map { Color(nsColor: $0) }
                    ?? Contrast.foreground(on: runSurface)
                let ink = readableColor(original, on: runSurface)
                preview.addAttribute(.foregroundColor, value: NSColor(ink), range: range)
                // Explicit decoration colors can disappear independently of
                // the text. Missing colors naturally follow the corrected ink.
                for key: NSAttributedString.Key in [.underlineColor, .strikethroughColor, .strokeColor] {
                    if let color = attributes[key] as? NSColor {
                        preview.addAttribute(key,
                                             value: NSColor(readableColor(Color(nsColor: color), on: runSurface)),
                                             range: range)
                    }
                }
            }
        }
        return preview
    }

    private static func readableColor(_ original: Color, on surface: Color) -> Color {
        if Contrast.meets(Contrast.aaText, original, on: surface, over: surface) { return original }
        // Increasing alpha may be necessary before changing a faint color's
        // brightness; Contrast.adjust intentionally preserves its input alpha.
        let opaque = Color(nsColor: NSColor(original).withAlphaComponent(1))
        let adjusted = Contrast.adjust(opaque, on: surface, over: surface)
        if Contrast.meets(Contrast.aaText, adjusted, on: surface, over: surface) { return adjusted }
        // Mid-gray surfaces may leave too little room in one direction. Pick
        // the better extreme rather than returning a still-illegible color.
        return Contrast.foreground(on: surface, light: .white, dark: .black)
    }
}

struct RichTextContent: View {
    @Environment(\.colorScheme) private var colorScheme
    let rtfData: Data?
    let fallback: String
    var font: Font = .system(size: 13)
    var lineLimit: Int? = nil
    var surface: RichTextPreview.Surface = .window

    var body: some View {
        Group {
            if let richText {
                Text(richText)
            } else {
                Text(fallback)
                    .foregroundStyle(surface == .window ? Color.primary : Theme.textPrimary)
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
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!
        return AttributedString(RichTextPreview.readable(value, on: surface.background, appearance: appearance))
    }
}

struct LinkPreviewContent: View {
    let text: String
    let compact: Bool
    @Bindable private var settings = Settings.shared
    private let previews = LinkPreviewStore.shared

    private var url: URL? { URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var preview: LinkPreview? { settings.generateLinkPreviews ? previews.preview(for: url) : nil }
    private var host: String { url?.host ?? text }

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            icon
            VStack(alignment: .leading, spacing: compact ? 2 : 5) {
                Text(preview?.title ?? host)
                    .font(.system(size: compact ? 12 : 15, weight: .semibold))
                    .foregroundStyle(Theme.chromeText)
                    .lineLimit(compact ? 2 : 3)
                Text(host)
                    .font(.system(size: compact ? 10 : 12))
                    .foregroundStyle(Theme.chromeTextMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .onAppear {
            if settings.generateLinkPreviews { previews.load(for: url) }
        }
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
    let titleOverride: String?
    @Bindable private var settings = Settings.shared
    private let previews = LinkPreviewStore.shared

    init(text: String, titleOverride: String? = nil) {
        self.text = text
        self.titleOverride = titleOverride
    }

    private var url: URL? { URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var preview: LinkPreview? { settings.generateLinkPreviews ? previews.preview(for: url) : nil }
    private var host: String { url?.host ?? text }
    private var title: String {
        if let titleOverride = titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !titleOverride.isEmpty {
            return titleOverride
        }
        return preview?.title ?? host
    }

    var body: some View {
        // Rich artwork is useful in a tall bar, but its fixed thumbnail used
        // to force link cards below the shared strip height in a short bar.
        // Prefer a compact card when the full layout does not fit.
        ViewThatFits(in: .vertical) {
            richPreview
            compactPreview
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            if settings.generateLinkPreviews { previews.load(for: url) }
        }
    }

    private var richPreview: some View {
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
                previewIcon(size: 16, cornerRadius: 4)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
            }
        }
    }

    private var compactPreview: some View {
        HStack(spacing: 9) {
            previewIcon(size: 36, cornerRadius: 9)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func previewIcon(size: CGFloat, cornerRadius: CGFloat) -> some View {
        if let icon = preview?.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(0.16))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "link")
                        .font(.system(size: size * 0.44, weight: .semibold))
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
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(item.createdAt.clipRelativeLong)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Text(item.displayTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
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
                RichTextContent(rtfData: item.rtfData, fallback: item.text ?? "",
                                font: .system(size: 15), surface: .inline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        case .link:
            VStack(spacing: 14) {
                LinkPreviewContent(text: item.text ?? item.displayTitle, compact: false)
                Text(item.text ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.chromeTextMuted)
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
                        .foregroundStyle(Theme.chromeText)
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
                    .foregroundStyle(Theme.chromeText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private func missingPreview(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 38, weight: .light))
            .foregroundStyle(Theme.chromeTextFaint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filePreviewImage: NSImage? {
        store.loadPreviewImage(for: item)
    }
}
