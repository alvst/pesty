import ImageIO
import SwiftUI
import UIKit

/// Content-first previews shared by the library cards and clip details.
struct RichClipPreview: View {
    let clip: PestyClip
    var compact = true

    var body: some View {
        // Image and file previews already render their own asset. Adding an
        // attachment above a file preview displayed every screenshot twice.
        if clip.kind != .image, clip.kind != .file,
           LocalAssetPersistence.url(for: clip.imageAssetID) != nil {
            VStack(alignment: .leading, spacing: 0) {
                CachedAssetImage(clip: clip, compact: compact,
                                 height: compact ? 96 : 420,
                                 label: "Attached image")
                clipContent
            }
        } else {
            clipContent
        }
    }

    @ViewBuilder
    private var clipContent: some View {
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
            if compact,
               clip.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                // The generated title is the beginning of this same text.
                // Show it once, giving the card room for more of the clip.
                Text(String((clip.previewText ?? clip.displayTitle).prefix(2_048)))
                    .font(looksLikeCode ? .system(.subheadline, design: .monospaced) : .subheadline)
                    .foregroundStyle(PestyPalette.textPrimary)
                    .lineLimit(7)
            } else {
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
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(13)
    }
}

private struct ImageRichPreview: View {
    let clip: PestyClip
    let compact: Bool

    var body: some View {
        if LocalAssetPersistence.url(for: clip.imageAssetID) != nil {
            CachedAssetImage(clip: clip, compact: compact,
                             height: compact ? 168 : 520,
                             label: clip.displayTitle)
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
        .frame(height: compact ? 168 : 220)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Color \(clip.colorHex ?? clip.displayTitle)")
    }
}

private struct FileRichPreview: View {
    let clip: PestyClip
    let compact: Bool

    /// A copied image file (a Mac screenshot, typically) syncs its pixels
    /// along with its name, so it can be shown rather than described.
    var body: some View {
        if LocalAssetPersistence.url(for: clip.imageAssetID) != nil {
            VStack(spacing: 0) {
                CachedAssetImage(clip: clip, compact: compact,
                                 height: compact ? 136 : 520,
                                 label: clip.displayTitle)
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
    @State private var attributedText: AttributedString?

    private var cacheKey: NSString {
        "\(clip.id.uuidString):\(clip.updatedAt.timeIntervalSinceReferenceDate):\(compact)" as NSString
    }

    var body: some View {
        Group {
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
        .task(id: cacheKey) {
            attributedText = nil
            guard let data = clip.richTextData,
                  !compact || data.count <= 64 * 1_024 else { return }
            if let cached = RTFPreviewCache.shared.object(forKey: cacheKey) {
                attributedText = cached.text
                return
            }
            let parsed = await Task.detached(priority: .utility) { () -> ParsedRTFPreview? in
                guard let full = try? NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil
                ) else { return nil }
                let preview = compact && full.length > 2_048
                    ? full.attributedSubstring(from: NSRange(location: 0, length: 2_048))
                    : full
                return ParsedRTFPreview(text: AttributedString(preview), cost: preview.length * 4)
            }.value
            guard !Task.isCancelled, let parsed else { return }
            RTFPreviewCache.shared.setObject(
                CachedRTFPreview(parsed.text), forKey: cacheKey, cost: parsed.cost
            )
            attributedText = parsed.text
        }
    }
}

private struct ParsedRTFPreview: Sendable {
    let text: AttributedString
    let cost: Int
}

private final class CachedRTFPreview: NSObject {
    let text: AttributedString

    init(_ text: AttributedString) { self.text = text }
}

private enum RTFPreviewCache {
    static let shared: NSCache<NSString, CachedRTFPreview> = {
        let cache = NSCache<NSString, CachedRTFPreview>()
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()
}

private struct CachedAssetImage: View {
    let clip: PestyClip
    let compact: Bool
    let height: CGFloat
    let label: String
    @State private var thumbnail: UIImage?

    private var maxPixels: Int { compact ? 640 : 1_400 }
    private var cacheKey: NSString {
        let version = clip.imageHash ?? String(clip.updatedAt.timeIntervalSinceReferenceDate)
        return "\(clip.imageAssetID ?? ""):\(version):\(maxPixels)" as NSString
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                PestyPalette.imageBackground
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFit()
                        .frame(width: max(0, geometry.size.width - 16),
                               height: max(0, geometry.size.height - 16))
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(PestyPalette.textTertiary)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: height)
        .clipped()
        .accessibilityLabel(label)
        .task(id: cacheKey) {
            thumbnail = nil
            if let cached = AssetThumbnailCache.shared.object(forKey: cacheKey) {
                thumbnail = cached
                return
            }
            guard let url = LocalAssetPersistence.url(for: clip.imageAssetID) else { return }
            let pixels = maxPixels
            let cgImage = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels
                ]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }.value
            guard !Task.isCancelled, let cgImage else { return }
            let image = UIImage(cgImage: cgImage)
            AssetThumbnailCache.shared.setObject(image, forKey: cacheKey,
                                                 cost: cgImage.bytesPerRow * cgImage.height)
            thumbnail = image
        }
    }
}

private enum AssetThumbnailCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()
}

private struct LinkRichPreview: View {
    let url: URL
    let compact: Bool

    var body: some View {
        // A copied link may contain a one-time login or reset token. Build
        // the preview locally so rendering a card never requests that URL.
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
        .frame(maxWidth: .infinity)
        .frame(height: compact ? 165 : 250)
        .clipped()
        .background(PestyPalette.cardBody)
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
