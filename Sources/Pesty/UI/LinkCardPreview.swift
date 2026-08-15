import SwiftUI

/// Rich link preview shown on a `.link` clip's card: a fetched thumbnail,
/// favicon, and page title in place of a plain URL string. Falls back to a
/// generic link glyph and the host name until `LinkPreviewStore` finishes
/// fetching (or if fetching fails).
struct LinkCardPreview: View {
    let text: String
    let titleOverride: String?
    private let previews = LinkPreviewStore.shared

    init(text: String, titleOverride: String? = nil) {
        self.text = text
        self.titleOverride = titleOverride
    }

    private var url: URL? { URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var preview: LinkPreview? { previews.preview(for: url) }
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
        .onAppear { previews.load(for: url) }
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
                    .foregroundStyle(Theme.cardTextPrimary)
                    .lineLimit(2)
            }
        }
    }

    private var compactPreview: some View {
        HStack(spacing: 9) {
            previewIcon(size: 36, cornerRadius: 9)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.cardTextPrimary)
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

/// Compact horizontal variant used in the standalone preview window.
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
