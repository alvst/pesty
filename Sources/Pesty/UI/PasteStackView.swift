import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The compact floating collector. It stays available while the user copies
/// clips in another app; the full, browsable queue lives in PasteStackContentView.
struct PasteStackView: View {
    private var stack: PasteSequence { AppController.shared.pasteSequence }
    @State private var draggedEntryID: UUID?
    @State private var dropTargetEntryID: UUID?

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
            Button {
                if stack.isCollecting {
                    AppController.shared.pausePasteSequence()
                } else {
                    AppController.shared.beginPasteSequence()
                }
            } label: {
                Image(systemName: stack.isCollecting ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(stack.isCollecting ? .orange : Theme.selection)
            }
            .buttonStyle(.plain)
            .help(stack.isCollecting ? "Pause collecting clips" : "Resume collecting clips")
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

    private var settings: Settings { Settings.shared }

    @ViewBuilder
    private var entries: some View {
        if stack.entries.isEmpty {
            emptyState
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(Array(stack.displayEntries.enumerated()), id: \.element.id) { index, entry in
                        PasteStackEntryRow(entry: entry,
                                           index: index + 1,
                                           selected: stack.selectedEntryID == entry.id,
                                           showsPasteAction: false)
                            .modifier(PasteStackEntryReorderModifier(
                                entry: entry,
                                draggedEntryID: $draggedEntryID,
                                dropTargetEntryID: $dropTargetEntryID
                            ))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.selection)
            Text("Copy text, images, or files in any app to add them here")
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 190)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Button("Save") { AppController.shared.savePasteStack() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Save Paste Stack as a Pinboard")
                Button { AppController.shared.clearPasteStack() } label: {
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
        guard stack.hasEntries else {
            return stack.isCollecting ? "Collecting clips from any app" : "Collection paused"
        }
        if stack.isCollecting {
            return "\(stack.pendingCount) collected · Copy more in any app"
        }
        if stack.pastedCount == 0 { return "\(stack.pendingCount) ready to paste" }
        return "\(stack.pendingCount) ready · \(stack.pastedCount) pasted"
    }
}

/// The dedicated Paste Stack tab deliberately uses the same card strip as
/// Clipboard. It is a focused view of the most recent stack—not another list.
struct PasteStackContentView: View {
    private static let stripStartID = "pesty.paste-stack.strip.start"
    private var stack: PasteSequence { AppController.shared.pasteSequence }
    private var settings: Settings { Settings.shared }

    var body: some View {
        VStack(spacing: 0) {
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
                    settings.stackPasteInReverse.toggle()
                } label: {
                    Image(systemName: settings.stackPasteInReverse
                          ? "arrow.down.to.line.compact"
                          : "arrow.up.to.line.compact")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(settings.stackPasteInReverse ? "Paste last clip first" : "Paste first clip first")
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
                if stack.hasEntries {
                    Button("Save Stack…") { AppController.shared.savePasteStack() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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
            Divider()

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
                cardStrip
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cardStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Theme.cardSpacing) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .id(Self.stripStartID)

                    ForEach(Array(stack.displayEntries.enumerated()), id: \.element.id) { index, entry in
                        ClipCardView(item: entry.item,
                                     index: index,
                                     selected: stack.selectedEntryID == entry.id,
                                     pasteStackEntry: entry)
                            .id(entry.id)
                            .opacity(entry.isPasted ? 0.58 : 1)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.92).combined(with: .opacity),
                                removal: .opacity))
                    }
                }
                .padding(.trailing, 28)
                .padding(.top, 16)
                .padding(.bottom, 26)
                .animation(.spring(response: 0.34, dampingFraction: 0.8), value: stack.displayEntries.map(\.id))
            }
            .scrollClipDisabled()
            .onAppear {
                guard let id = stack.selectedEntryID else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(id, anchor: .leading)
                }
            }
            .onChange(of: stack.selectedEntryID) { _, id in
                guard let id else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var summary: String {
        if stack.isCollecting { return "Collecting external copies" }
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

private struct PasteStackEntryRow: View {
    let entry: PasteStackEntry
    let index: Int
    let selected: Bool
    let showsPasteAction: Bool

    private var stack: PasteSequence { AppController.shared.pasteSequence }

    var body: some View {
        HStack(spacing: 11) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text("\(index)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(entry.item.type.accent)
                    Text(entry.item.type.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if entry.isPasted {
                        Text("PASTED")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(entry.item.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 6)
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
                    if !entry.isPasted {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .help("Drag to reorder Paste Stack")
                    }
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
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(selected ? Theme.selection : .clear, lineWidth: selected ? 2 : 0)
        }
        .opacity(entry.isPasted ? 0.48 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture { stack.select(entry) }
        .help(entry.isPasted ? "Pasted clip" : "Select this stack clip")
    }

    private var rowBackground: Color {
        selected ? Theme.selection.opacity(0.11) : Color.white.opacity(0.12)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = previewImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .scaledToFill()
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(entry.item.type.accent.opacity(0.18))
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: entry.item.type.symbol)
                        .font(.system(size: 16, weight: .medium))
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

private enum PasteStackEntryDrag {
    static let entryType = UTType(exportedAs: "com.greycorelabs.pesty.paste-stack-entry")

    static func provider(for id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: entryType.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(id.uuidString.data(using: .utf8), nil)
            return nil
        }
        return provider
    }
}

private struct PasteStackEntryReorderModifier: ViewModifier {
    let entry: PasteStackEntry
    @Binding var draggedEntryID: UUID?
    @Binding var dropTargetEntryID: UUID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if entry.isPasted {
            content
        } else {
            content
                .onDrag {
                    draggedEntryID = entry.id
                    return PasteStackEntryDrag.provider(for: entry.id)
                }
                .onDrop(of: [PasteStackEntryDrag.entryType], isTargeted: isDropTarget) { _ in
                    guard let draggedEntryID, draggedEntryID != entry.id else {
                        clearDragState()
                        return false
                    }
                    PasteSequence.shared.movePendingEntry(draggedEntryID, before: entry.id)
                    clearDragState()
                    return true
                }
                .overlay(alignment: .top) {
                    if dropTargetEntryID == entry.id, draggedEntryID != entry.id {
                        Capsule()
                            .fill(Theme.selection)
                            .frame(height: 3)
                            .padding(.horizontal, 10)
                            .offset(y: -3)
                    }
                }
        }
    }

    private var isDropTarget: Binding<Bool> {
        Binding(
            get: { dropTargetEntryID == entry.id },
            set: { isTargeted in
                if isTargeted {
                    dropTargetEntryID = entry.id
                } else if dropTargetEntryID == entry.id {
                    dropTargetEntryID = nil
                }
            }
        )
    }

    private func clearDragState() {
        draggedEntryID = nil
        dropTargetEntryID = nil
    }
}
