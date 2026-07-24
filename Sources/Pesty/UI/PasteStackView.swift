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
                AppController.shared.showPasteStackTab()
            } label: {
                Image(systemName: "rectangle.stack.fill")
                    .foregroundStyle(Theme.selection)
            }
            .buttonStyle(.plain)
            .help("Open Paste Stack in Pesty")
            Button {
                if stack.isCollecting {
                    AppController.shared.pausePasteSequence()
                } else {
                    AppController.shared.beginPasteSequence()
                }
            } label: {
                Image(systemName: stack.isCollecting ? "pause.circle.fill" : "play.circle.fill")
                    .foregroundStyle(stack.isCollecting ? .orange : Theme.selection)
            }
            .buttonStyle(.plain)
            .help(stack.isCollecting ? "Pause collecting clips" : "Resume collecting clips")
            Button {
                AppController.shared.hidePasteStack()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide Paste Stack")
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
                    ForEach(Array(stack.displayEntries.enumerated()), id: \.element.id) { index, entry in
                        PasteStackEntryRow(entry: entry,
                                           index: index + 1,
                                           selected: stack.selectedEntryID == entry.id,
                                           showsPasteAction: false)
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
            .disabled(stack.pendingCount == 0)

            Text(Settings.shared.sequenceHotkeyDisplay)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            if stack.hasEntries {
                Button("Save") { AppController.shared.savePasteStack() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Save Paste Stack as a Pinboard")
                Button { AppController.shared.clearPasteStack() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear Paste Stack")
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 52)
    }

    private var summary: String {
        if stack.isCollecting {
            return stack.hasEntries ? "\(stack.pendingCount) collected - copy more" : "Copy clips in another app"
        }
        if stack.pendingCount > 0 { return "\(stack.pendingCount) ready to paste" }
        return stack.hasEntries ? "Stack complete" : "Collection paused"
    }
}

private struct PasteStackEntryRow: View {
    let entry: PasteStackEntry
    let index: Int
    let selected: Bool
    let showsPasteAction: Bool

    private var stack: PasteSequence { AppController.shared.pasteSequence }

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
            VStack(alignment: .trailing, spacing: 6) {
                if showsPasteAction {
                    if entry.isPasted {
                        Button("Re-add") { AppController.shared.reAddPasteStackEntry(entry) }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    } else {
                        Button("Paste") { AppController.shared.pasteStackEntry(entry) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                    }
                }
                HStack(spacing: 7) {
                    sourceAppIcon
                    Button { AppController.shared.removePasteStackEntry(entry) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove from Paste Stack")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Theme.selection : .clear, lineWidth: selected ? 2 : 0)
        }
        .opacity(entry.isPasted ? 0.52 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { stack.select(entry) }
        .help(entry.isPasted ? "Pasted clip" : "Select this stack clip")
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
        if entry.item.type == .image {
            return entry.imagePreview ?? ClipboardStore.shared.loadImage(for: entry.item)
        }
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

    private var rowBackground: Color {
        selected ? Theme.selection.opacity(0.13) : Color.white.opacity(0.10)
    }
}

/// The full Paste Stack tab in Pesty. It exposes the active deck without
/// turning its entries into ordinary clipboard-history cards.
struct PasteStackContentView: View {
    private var stack: PasteSequence { AppController.shared.pasteSequence }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            entries
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Paste Stack")
                    .font(.system(size: 16, weight: .bold))
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            if savedStacks.count > 1 {
                Menu {
                    ForEach(savedStacks) { saved in
                        Button(stackLabel(for: saved)) {
                            stack.selectStack(saved.id)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Choose a saved Paste Stack")
            }
            Spacer()

            Button {
                if stack.isCollecting {
                    AppController.shared.pausePasteSequence()
                } else {
                    AppController.shared.beginPasteSequence()
                }
            } label: {
                Label(stack.isCollecting ? "Pause" : "Collect",
                      systemImage: stack.isCollecting ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(stack.isCollecting ? .orange : Theme.selection)

            if stack.pendingCount > 0 {
                Button("Paste Next") { AppController.shared.pasteNextInSequence() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            if stack.pastedCount > 0 {
                Button("Reset") { AppController.shared.resetPasteStackProgress() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Make every Paste Stack clip ready again")
            }

            if stack.hasEntries {
                Button("Save Stack…") { AppController.shared.savePasteStack() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Save Paste Stack as a Pinboard")
            }

            Button("New Stack") { AppController.shared.newPasteStack() }
                .buttonStyle(.bordered)
                .controlSize(.small)

            if stack.hasEntries {
                Button(role: .destructive) { AppController.shared.clearPasteStack() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Clear Paste Stack")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private var entries: some View {
        if stack.entries.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.selection)
                Text("Start collecting clips")
                    .font(.system(size: 15, weight: .semibold))
                Text("Choose Collect, then copy text, images, or files in any app.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    ForEach(Array(stack.displayEntries.enumerated()), id: \.element.id) { index, entry in
                        PasteStackEntryRow(entry: entry,
                                           index: index + 1,
                                           selected: stack.selectedEntryID == entry.id,
                                           showsPasteAction: true)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
    }

    private var summary: String {
        if stack.isCollecting { return "Collecting clips from other apps" }
        if stack.pendingCount > 0 { return "\(stack.pendingCount) clips ready to paste" }
        return stack.hasEntries ? "All clips pasted" : "Collection paused"
    }

    private var savedStacks: [SavedPasteStack] {
        stack.savedStacks.filter(\.hasEntries)
    }

    private func stackLabel(for saved: SavedPasteStack) -> String {
        let state = saved.pendingCount > 0 ? "\(saved.pendingCount) ready" : "completed"
        return "\(saved.createdAt.clipRelativeLong) · \(state)"
    }
}
