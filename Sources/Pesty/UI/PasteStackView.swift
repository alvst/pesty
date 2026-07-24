import SwiftUI

struct PasteStackView: View {
    @Bindable private var stack = PasteSequence.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            entries
            Divider()
            footer
        }
        .frame(width: 320, height: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.25))
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "rectangle.stack.fill")
                .foregroundStyle(Theme.selection)
            VStack(alignment: .leading, spacing: 2) {
                Text("Paste Stack")
                    .font(.system(size: 15, weight: .bold))
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                AppController.shared.cancelPasteSequence()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel Paste Stack")
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var entries: some View {
        if stack.entries.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.selection)
                Text(stack.isCollecting
                     ? "Copy text, images, or files in another app to collect them here."
                     : "Start a new Paste Stack from the strip.")
                    .font(.system(size: 12, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 210)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 7) {
                    ForEach(Array(stack.entries.enumerated()), id: \.element.id) { index, entry in
                        PasteStackEntryRow(entry: entry, index: index + 1)
                    }
                }
                .padding(12)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                AppController.shared.pasteNextInSequence()
            } label: {
                Label("Paste Next", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!stack.hasEntries)

            Text(Settings.shared.sequenceHotkeyDisplay)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 15)
        .frame(height: 52)
    }

    private var summary: String {
        if stack.isCollecting {
            return stack.hasEntries ? "\(stack.pendingCount) collected - copy more" : "Copy clips in another app"
        }
        return stack.hasEntries ? "\(stack.pendingCount) ready to paste" : "Stack complete"
    }
}

private struct PasteStackEntryRow: View {
    let entry: PasteStackEntry
    let index: Int

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index)")
                .font(.caption.weight(.bold))
                .foregroundStyle(entry.item.type.accent)
                .frame(width: 18)
            preview
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.item.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(entry.item.type.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            sourceAppIcon
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var preview: some View {
        if let image = previewImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .scaledToFill()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(entry.item.type.accent.opacity(0.18))
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: entry.item.type.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(entry.item.type.accent)
                }
        }
    }

    private var previewImage: NSImage? {
        if entry.item.type == .image { return entry.imagePreview }
        guard entry.item.type == .file,
              entry.item.fileURLs.count == 1,
              let urlString = entry.item.fileURLs.first,
              let url = URL(string: urlString),
              url.isFileURL else { return nil }
        return NSImage(contentsOf: url)
    }

    private var sourceAppIcon: some View {
        Image(nsImage: AppIconProvider.icon(forBundleID: entry.item.sourceBundleID))
            .resizable()
            .interpolation(.high)
            .frame(width: 19, height: 19)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .help(entry.item.sourceAppName ?? "Source app")
    }
}
