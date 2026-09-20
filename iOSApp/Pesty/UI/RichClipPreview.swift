import LinkPresentation
import SwiftUI
import UIKit

/// Content-first previews shared by the library cards and clip details.
struct RichClipPreview: View {
    let clip: PestyClip
    var compact = true

    var body: some View {
        switch clip.kind {
        case .link:
            if let url = clip.webURL {
                LinkRichPreview(url: url, compact: compact)
            } else {
                TextPreview(clip: clip, compact: compact)
            }
        case .image:
            ImageRichPreview(clip: clip, compact: compact)
        case .color:
            ColorRichPreview(clip: clip, compact: compact)
        case .file:
            FileRichPreview(clip: clip, compact: compact)
        case .richText:
            RTFPreview(clip: clip, compact: compact)
        case .text:
            TextPreview(clip: clip, compact: compact)
        }
    }
}

private struct TextPreview: View {
    let clip: PestyClip
    let compact: Bool

    private var looksLikeCode: Bool {
        let text = String((clip.text ?? "").prefix(4_096))
        let markers = ["func ", "let ", "var ", "class ", "struct ", "enum ", "import ", "{", "};"]
        return markers.filter(text.contains).count >= 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(clip.displayTitle)
                .font(.headline)
                .foregroundStyle(PestyPalette.textPrimary)
                .lineLimit(compact ? 2 : nil)
            if let preview = clip.previewText, preview != clip.displayTitle {
                Text(compact ? String(preview.prefix(2_048)) : preview)
                    .font(looksLikeCode ? .system(.subheadline, design: .monospaced) : .subheadline)
                    .foregroundStyle(PestyPalette.textSecondary)
                    .lineLimit(compact ? 5 : nil)
                    .pestyTextSelection(enabled: !compact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(13)
    }
}

private struct ImageRichPreview: View {
    let clip: PestyClip
    let compact: Bool

    var body: some View {
        if let url = LocalAssetPersistence.url(for: clip.imageAssetID),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.medium)
                .scaledToFit()
                .frame(maxWidth: .infinity, minHeight: compact ? 130 : 180, maxHeight: compact ? 235 : 520)
                .background(Checkerboard())
                .accessibilityLabel(clip.displayTitle)
        } else {
            UnavailableRichPreview(
                symbol: "photo",
                title: "Image",
                detail: "The image asset is not on this device yet.",
                compact: compact
            )
        }
    }
}

private struct ColorRichPreview: View {
    let clip: PestyClip
    let compact: Bool

    var body: some View {
        let color = Color(hex: clip.colorHex ?? "") ?? clip.kind.tint
        ZStack {
            color
            Text(clip.colorHex ?? clip.displayTitle)
                .font(compact ? .headline.monospaced().weight(.bold) : .title2.monospaced().weight(.bold))
                .foregroundStyle(color.isPerceptuallyLight ? .black.opacity(0.78) : .white)
                .padding()
        }
        .frame(minHeight: compact ? 145 : 220)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Color \(clip.colorHex ?? clip.displayTitle)")
    }
}

private struct FileRichPreview: View {
    let clip: PestyClip
    let compact: Bool

    /// A copied image file (a Mac screenshot, typically) syncs its pixels
    /// along with its name, so it can be shown rather than described.
    private var image: UIImage? {
        guard let url = LocalAssetPersistence.url(for: clip.imageAssetID) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    var body: some View {
        if let image {
            VStack(spacing: 0) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, minHeight: compact ? 130 : 180, maxHeight: compact ? 235 : 520)
                    .background(Checkerboard())
                    .accessibilityLabel(clip.displayTitle)
                if let name = clip.fileNames.first {
                    Text(name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PestyPalette.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: clip.fileNames.count > 1 ? "doc.on.doc.fill" : "doc.fill")
                .font(.system(size: compact ? 42 : 58, weight: .light))
                .foregroundStyle(clip.kind.tint)
            VStack(spacing: 3) {
                ForEach(Array(clip.fileNames.prefix(compact ? 3 : 8)), id: \.self) { name in
                    Text(name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PestyPalette.textSecondary)
                        .lineLimit(1)
                }
                if clip.fileNames.count > (compact ? 3 : 8) {
                    Text("+\(clip.fileNames.count - (compact ? 3 : 8)) more")
                        .font(.caption)
                        .foregroundStyle(PestyPalette.textTertiary)
                }
                if clip.fileNames.isEmpty {
                    Text("Available on the source device")
                        .font(.caption)
                        .foregroundStyle(PestyPalette.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 145 : 220)
        .padding(13)
    }
}

private struct RTFPreview: View {
    let clip: PestyClip
    let compact: Bool

    private var attributedText: AttributedString? {
        guard let data = clip.richTextData,
              let value = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
              ) else { return nil }
        return AttributedString(value)
    }

    var body: some View {
        if let attributedText {
            Text(attributedText)
                .lineLimit(compact ? 7 : nil)
                .foregroundStyle(PestyPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(13)
                .pestyTextSelection(enabled: !compact)
        } else {
            TextPreview(clip: clip, compact: compact)
        }
    }
}

private struct LinkRichPreview: View {
    let url: URL
    let compact: Bool
    @State private var metadata: LPLinkMetadata?

    var body: some View {
        Group {
            if let metadata {
                LinkView(metadata: metadata)
                    .allowsHitTesting(false)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    Image(systemName: "link")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(PestyPalette.selection)
                    Text(url.host(percentEncoded: false) ?? url.absoluteString)
                        .font(.headline)
                        .foregroundStyle(PestyPalette.textPrimary)
                        .lineLimit(2)
                    Text(url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(PestyPalette.textSecondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: compact ? 165 : 250)
        .clipped()
        .background(Color.white)
        .task(id: url.absoluteString) {
            metadata = await LinkMetadataCache.shared.metadata(for: url)
        }
    }
}

private struct LinkView: UIViewRepresentable {
    let metadata: LPLinkMetadata

    func makeUIView(context: Context) -> FittedLinkView {
        let view = FittedLinkView(metadata: metadata)
        view.isUserInteractionEnabled = false
        view.clipsToBounds = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: FittedLinkView, context: Context) {
        view.metadata = metadata
    }

    /// The card decides the size; the link view fills it.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: FittedLinkView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// `LPLinkView` reports its natural size — title, summary, and hero image at
/// full width — as its intrinsic content size, and SwiftUI honours it: link
/// cards grew far past their grid cell and drew over their neighbours. With
/// no intrinsic size, the view is exactly as large as the card makes it.
private final class FittedLinkView: LPLinkView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }
}

@MainActor
private final class LinkMetadataCache {
    static let shared = LinkMetadataCache()

    private var cache: [URL: LPLinkMetadata] = [:]
    private var unavailable: Set<URL> = []

    func metadata(for url: URL) async -> LPLinkMetadata? {
        if let cached = cache[url] { return cached }
        guard !unavailable.contains(url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        let provider = LPMetadataProvider()
        provider.timeout = 8
        do {
            let metadata = try await provider.startFetchingMetadata(for: url)
            cache[url] = metadata
            return metadata
        } catch {
            unavailable.insert(url)
            return nil
        }
    }
}

private struct UnavailableRichPreview: View {
    let symbol: String
    let title: String
    let detail: String
    let compact: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 34 : 46, weight: .light))
            Text(title).font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(PestyPalette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(PestyPalette.textTertiary)
        .frame(maxWidth: .infinity, minHeight: compact ? 145 : 220)
        .padding(13)
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let side: CGFloat = 10
            let columns = Int(ceil(size.width / side))
            let rows = Int(ceil(size.height / side))
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    context.fill(
                        Path(CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side)),
                        with: .color(.black.opacity(0.055))
                    )
                }
            }
        }
        .background(Color.white)
    }
}

private extension PestyClip {
    var webURL: URL? {
        guard kind == .link,
              let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

private extension Color {
    var isPerceptuallyLight: Bool {
        guard let components = UIColor(self).cgColor.components else { return false }
        let red = components.count > 2 ? components[0] : components[0]
        let green = components.count > 2 ? components[1] : components[0]
        let blue = components.count > 2 ? components[2] : components[0]
        return (0.299 * red + 0.587 * green + 0.114 * blue) > 0.65
    }
}

private extension View {
    @ViewBuilder
    func pestyTextSelection(enabled: Bool) -> some View {
        if enabled {
            textSelection(.enabled)
        } else {
            textSelection(.disabled)
        }
    }
}
