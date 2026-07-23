import SwiftUI

struct PasteStackView: View {
    @Bindable private var settings = Settings.shared
    private var stack: PasteSequence { AppController.shared.pasteSequence }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            controls
            Divider().opacity(0.45)
            entries
            Divider().opacity(0.45)
            footer
        }
        .frame(width: 318, height: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.28))
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "rectangle.stack.fill")
                .foregroundStyle(Theme.selection)
            VStack(alignment: .leading, spacing: 1) {
                Text("Paste Stack")
                    .font(.system(size: 15, weight: .bold))
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { AppController.shared.hidePasteStack() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide Paste Stack")
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                settings.stackPasteInReverse.toggle()
            } label: {
                Label(settings.stackPasteInReverse ? "Last to first" : "First to last",
                      systemImage: settings.stackPasteInReverse ? "arrow.down.to.line.compact" : "arrow.up.to.line.compact")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Change the order used when pasting stack items")

            Spacer()

            Button("New Stack") { AppController.shared.newPasteStack() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Clear this stack and start collecting a new one")
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var entries: some View {
        if stack.entries.isEmpty {
            VStack(spacing: 9) {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.selection)
                Text("Select a clip in Pesty, then press ⌘C to add it here")
                    .font(.system(size: 12, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 190)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: -5) {
                    ForEach(Array(stack.entries.enumerated()), id: \.element.id) { index, entry in
                        PasteStackEntryView(entry: entry, index: index + 1)
                            .zIndex(Double(stack.entries.count - index))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if stack.pendingCount > 0 {
                Button {
                    AppController.shared.pasteNextInSequence()
                } label: {
                    Label("Paste Next", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Text(Settings.shared.sequenceHotkeyDisplay)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if stack.hasEntries {
                Button("Paste Stack Again") {
                    AppController.shared.resetPasteStackProgress()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Text("All pasted")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("Stack is ready for clips")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if stack.hasEntries {
                Button { AppController.shared.pasteSequence.cancel() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear Paste Stack")
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 52)
    }

    private var summary: String {
        guard stack.hasEntries else { return "Collect clips from the bar" }
        if stack.pastedCount == 0 { return "(stack.pendingCount) ready to paste" }
        return "(stack.pendingCount) ready · (stack.pastedCount) pasted"
    }
}

private struct PasteStackEntryView: View {
    let entry: PasteStackEntry
    let index: Int

    var body: some View {
        Button {
            if entry.isPasted {
                AppController.shared.reAddPasteStackEntry(entry)
            } else {
                AppController.shared.removePasteStackEntry(entry)
            }
        } label: {
            HStack(spacing: 10) {
                preview
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("\(index)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(entry.item.type.accent)
                        Text(entry.item.type.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.item.displayTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: entry.isPasted ? "arrow.uturn.backward.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(entry.isPasted ? Theme.selection : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if entry.isPasted {
                    Text("PASTED")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(entry.isPasted ? 0.42 : 1)
        .help(entry.isPasted ? "Add this clip to the end of the stack again" : "Remove from Paste Stack")
    }

    @ViewBuilder
    private var preview: some View {
        if entry.item.type == .image, let image = entry.imagePreview {
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
}
