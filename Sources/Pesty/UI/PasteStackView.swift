import AppKit
import SwiftUI

/// The floating Paste Stack panel: shows the queue as browsable cards while
/// the user copies elsewhere, and lets them jump the queue, search it, drag
/// an entry to reorder it, or drop an entry, all without leaving whatever
/// app they're currently working in.
struct PasteStackView: View {
    @Bindable private var stack = PasteSequence.shared
    private var settings: Settings { Settings.shared }
    /// Vertical gap between entry rows - shared with `PasteStackInsertionCaret`'s
    /// offset so the drag caret always centers in the actual gap between rows.
    fileprivate static let entryRowSpacing: CGFloat = 6

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            deckStrip
            Divider().opacity(0.45)
            searchField
            Divider().opacity(0.45)
            controls
            Divider().opacity(0.45)
            entries
            Divider().opacity(0.45)
            footer
        }
        .frame(width: 318, height: 464)
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
                AppController.shared.togglePasteStackCollecting()
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

    /// Saved decks the user can switch between - each pill is a past
    /// `newStack()` call (or the current one), showing a "New Stack" action
    /// alongside them so starting a fresh deck never requires losing this one.
    private var deckStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(stack.savedStacks) { deck in
                    PasteStackDeckPill(deck: deck, isActive: deck.id == stack.activeStackID)
                }
                Button { AppController.shared.newPasteStack() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 27, height: 27)
                        .background(Color.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .help("New Stack")
            }
            .padding(.horizontal, 15)
        }
        .padding(.vertical, 8)
    }

    /// Filters the visible entry list live as the user types. Purely a
    /// display filter - it never touches the underlying queue or paste
    /// order, which `PasteSequence.moveEntry` and `next()` still act on.
    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Search this stack", text: $stack.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !stack.searchText.isEmpty {
                Button { stack.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                settings.stackPasteInReverse.toggle()
            } label: {
                Label(settings.stackPasteInReverse ? "Last to first" : "First to last",
                      systemImage: settings.stackPasteInReverse
                        ? "arrow.down.to.line.compact"
                        : "arrow.up.to.line.compact")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Change the order used when pasting stack items")

            Spacer()

            if stack.hasEntries {
                Button(role: .destructive) { AppController.shared.clearPasteStack() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear Paste Stack")
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var entries: some View {
        if stack.entries.isEmpty {
            emptyState
        } else if visibleEntries.isEmpty {
            searchEmptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: Self.entryRowSpacing) {
                        ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
                            PasteStackEntryRow(entry: entry,
                                               index: index + 1,
                                               selected: stack.selectedEntryID == entry.id)
                                .id(entry.id)
                                .modifier(PasteStackEntryReorderTarget(entry: entry,
                                                                       reorderable: !stack.isFiltering))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                .onChange(of: stack.selectedEntryID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private var visibleEntries: [PasteStackEntry] {
        stack.visibleEntries()
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

    private var searchEmptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text("No matches for “\(stack.searchText)”")
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
                    AppController.shared.pasteNextStackItem()
                } label: {
                    Label("Paste Next", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Text(settings.sequenceHotkeyDisplay)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Text("Stack is ready for clips")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
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

/// One queued clip: a compact preview, a "paste this" click target, and a
/// remove button. The selected row is both the keyboard-navigable focus and
/// the entry Enter/"Paste Next" will act on.
private struct PasteStackEntryRow: View {
    let entry: PasteStackEntry
    let index: Int
    let selected: Bool

    private var stack: PasteSequence { PasteSequence.shared }

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
                if !entry.isPasted {
                    Button("Paste") { AppController.shared.pasteStackEntry(entry) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
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
        .help(helpText)
        .modifier(PasteStackEntryDragSource(entry: entry, reorderable: !stack.isFiltering))
    }

    /// Only advertises dragging when dragging is actually available - a
    /// filtered list has reordering switched off.
    private var helpText: String {
        if entry.isPasted { return "Pasted clip" }
        return stack.isFiltering ? "Select this stack clip" : "Select this stack clip - drag to reorder"
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

    /// Mirrors ClipCardView's per-type preview rendering for the two types
    /// that have an actual thumbnail; everything else falls back to the
    /// type icon above, matching ClipCardView's own placeholder treatment.
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

/// Identifies which stack entry a drag inside the panel originated from, so
/// a drop target elsewhere in the list can reorder by ID. Scoped to Paste
/// Stack's own in-panel reordering - unrelated to ClipDragProvider, which
/// carries a clip's exported content out to other apps.
private let pasteStackEntryIdentifierType = "com.greycorelabs.pesty.paste-stack-entry-id"

/// Makes a pending entry row draggable within the panel. Pasted entries
/// (already at the bottom of the list, no longer affecting paste order in
/// any meaningful way) are left non-draggable, and so is every row while a
/// search filter is on: a drop only knows about the rows still on screen, so
/// reordering across a filtered list would silently leapfrog hidden entries
/// and change a paste order the user cannot see.
private struct PasteStackEntryDragSource: ViewModifier {
    let entry: PasteStackEntry
    let reorderable: Bool

    func body(content: Content) -> some View {
        if entry.isPasted || !reorderable {
            content
        } else {
            content.onDrag {
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: pasteStackEntryIdentifierType,
                                                     visibility: .all) { completion in
                    completion(Data(entry.id.uuidString.utf8), nil)
                    return nil
                }
                return provider
            }
        }
    }
}

/// Lets a pending entry be dropped onto another to reorder the active stack.
/// The drop affordance is an insertion caret drawn above the row being
/// dragged over, rather than a box highlight around it, so it reads as "the
/// entry lands here" instead of "this row is the target".
private struct PasteStackEntryReorderTarget: ViewModifier {
    let entry: PasteStackEntry
    let reorderable: Bool
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if entry.isPasted || !reorderable {
            content
        } else {
            content
                .overlay(alignment: .top) {
                    if isTargeted {
                        PasteStackInsertionCaret(color: Theme.selection)
                            .offset(y: -PasteStackView.entryRowSpacing / 2 - 1.5)
                            .allowsHitTesting(false)
                    }
                }
                .onDrop(of: [pasteStackEntryIdentifierType], isTargeted: $isTargeted) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadDataRepresentation(forTypeIdentifier: pasteStackEntryIdentifierType) { data, _ in
                        guard let data, let idString = String(data: data, encoding: .utf8),
                              let draggedID = UUID(uuidString: idString) else { return }
                        DispatchQueue.main.async {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                                PasteSequence.shared.moveEntry(draggedID, before: entry.id)
                            }
                        }
                    }
                    return true
                }
        }
    }
}

/// A horizontal, capsule-capped insertion line shown above whichever row a
/// dragged stack entry is currently over: an I-beam caret marking where the
/// entry will land, laid out for a vertical list.
private struct PasteStackInsertionCaret: View {
    var color: Color
    var capWidth: CGFloat = 12
    var lineWidth: CGFloat = 3

    var body: some View {
        HStack(spacing: 0) {
            Capsule().fill(color).frame(width: capWidth, height: lineWidth)
            Rectangle().fill(color).frame(height: lineWidth)
            Capsule().fill(color).frame(width: capWidth, height: lineWidth)
        }
        .frame(maxWidth: .infinity)
    }
}

/// One saved deck in the switcher strip: a compact pill identifying the deck
/// by its first clip (or, once empty, its creation date), its pending count,
/// and a tap target to switch to it. Deleting lives in its context menu since
/// the strip has no room for a dedicated close button per pill.
private struct PasteStackDeckPill: View {
    let deck: SavedPasteStack
    let isActive: Bool

    var body: some View {
        Button {
            guard !isActive else { return }
            AppController.shared.selectPasteStack(deck.id)
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 108, alignment: .leading)
                Text("\(deck.pendingCount)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.16), in: Capsule())
            }
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 27)
            .background(isActive ? Theme.selection.opacity(0.22) : Color.white.opacity(0.12), in: Capsule())
            .overlay {
                Capsule().strokeBorder(isActive ? Theme.selection : .clear, lineWidth: 1.4)
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .contextMenu {
            Button(role: .destructive) {
                AppController.shared.deletePasteStack(deck.id)
            } label: {
                Label("Delete Deck", systemImage: "trash")
            }
        }
        .help(label)
    }

    private var label: String {
        if let first = deck.entries.first {
            return first.item.displayTitle
        }
        return deck.createdAt.clipRelative
    }
}
