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
            Image(systemName: entry.item.type.symbol)
                .foregroundStyle(entry.item.type.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.item.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(entry.item.type.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
