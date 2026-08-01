import AppKit
import SwiftUI

/// A compact representation of the active Paste Stack in the Clipboard strip.
/// The card opens the focused stack tab rather than behaving like a history
/// clip, which keeps collection and sequential paste actions unambiguous.
struct PasteStackDeckCard: View {
    // The full preview needs room for the header and footer as well as the
    // next clip. In a short bar, show one compact row instead of allowing the
    // preview and title to fight for the remaining vertical space.
    private static let compactLayoutThreshold: CGFloat = 300

    private var stack: PasteSequence { AppController.shared.pasteSequence }

    private var nextEntry: PasteStackEntry? {
        stack.displayEntries.first(where: { !$0.isPasted })
    }

    var body: some View {
        Button { AppController.shared.showPasteStackTab() } label: {
            ZStack(alignment: .topLeading) {
                if stack.pendingCount > 2 { deckLayer(offset: 12, opacity: 0.20) }
                if stack.pendingCount > 1 { deckLayer(offset: 6, opacity: 0.34) }
                frontCard
            }
            .frame(width: Theme.cardWidth + 12, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .help("Open Paste Stack")
    }

    private func deckLayer(offset: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
            .fill(Theme.selection.opacity(opacity))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                    .strokeBorder(Theme.selection.opacity(0.25))
            }
            .offset(x: offset, y: offset)
            .padding(.trailing, 12)
            .padding(.bottom, 12)
    }

    private var frontCard: some View {
        GeometryReader { geometry in
            cardContent(compact: geometry.size.height < Self.compactLayoutThreshold)
        }
        .frame(width: Theme.cardWidth)
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(Theme.selection.opacity(0.7), lineWidth: 2)
        }
        .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
    }

    private func cardContent(compact: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 16, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Paste Stack")
                        .font(.system(size: 15, weight: .bold))
                    Text(stack.isCollecting ? "Collecting clips" : "Ready to paste")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.headerSubText)
                }
                Spacer(minLength: 4)
                Text("\(stack.pendingCount)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.18), in: Capsule())
            }
            .foregroundStyle(Theme.headerText)
            .padding(.horizontal, 13)
            .frame(height: Theme.headerHeight)
            .background(Theme.selection)

            VStack(spacing: compact ? 7 : 10) {
                if let entry = nextEntry {
                    if compact {
                        compactEntrySummary(entry)
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(entry.item.type.accent.opacity(0.18))
                            .frame(width: 50, height: 50)
                            .overlay {
                                Image(systemName: entry.item.type.symbol)
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(entry.item.type.accent)
                            }
                        Text(entry.item.displayTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(3)
                            .multilineTextAlignment(.center)
                        Text("Next clip")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: compact ? 28 : 34, weight: .light))
                        .foregroundStyle(Theme.selection)
                    Text("Stack complete")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(compact ? 10 : 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.cardBody)

            HStack {
                Text("\(stack.pendingCount) queued")
                Spacer()
                Text("Open stack")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(Theme.cardBody)
        }
    }

    private func compactEntrySummary(_ entry: PasteStackEntry) -> some View {
        HStack(spacing: 9) {
            compactEntryThumbnail(entry)
            Text(entry.item.displayTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func compactEntryThumbnail(_ entry: PasteStackEntry) -> some View {
        if let image = previewImage(for: entry) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .scaledToFill()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(entry.item.type.accent.opacity(0.16))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: entry.item.type.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(entry.item.type.accent)
                }
        }
    }

    private func previewImage(for entry: PasteStackEntry) -> NSImage? {
        if entry.item.type == .image { return entry.imagePreview }
        guard entry.item.type == .file,
              entry.item.fileURLs.count == 1,
              let urlString = entry.item.fileURLs.first,
              let url = URL(string: urlString),
              url.isFileURL else { return nil }
        return NSImage(contentsOf: url)
    }
}
