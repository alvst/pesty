import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

struct ClipCardView: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    /// The one card in a multi-selection that the keyboard moves from. Every
    /// selected card gets the ring; only the lead gets the brighter inner
    /// edge, so it stays findable in a run of ten.
    let isLead: Bool
    /// Supplying a stack entry preserves the normal card appearance while the
    /// Paste Stack owns selection and paste behavior.
    let pasteStackEntry: PasteStackEntry?

    init(item: ClipItem,
         index: Int,
         selected: Bool,
         isLead: Bool = true,
         pasteStackEntry: PasteStackEntry? = nil) {
        self.item = item
        self.index = index
        self.selected = selected
        self.isLead = isLead
        self.pasteStackEntry = pasteStackEntry
    }

    @State private var hovering = false
    @State private var fileThumbnail: NSImage?
    @State private var fileIsMissing = false
    private var isPinboardCard: Bool {
        guard pasteStackEntry == nil else { return false }
        if case .pinboard = ClipboardStore.shared.source { return true }
        return false
    }
    private var store: ClipboardStore { ClipboardStore.shared }
    private var settings: Settings { Settings.shared }
    private var headerColor: Color { SourceColor.color(for: item.sourceBundleID) }

    /// Promotion is per board, so it only means anything while that board is
    /// the one on screen.
    private var pinnedBoardID: UUID? {
        guard pasteStackEntry == nil, let boardID = store.currentPinboardID,
              store.isPinned(item.id, inBoard: boardID) else { return nil }
        return boardID
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            body_
        }
        .frame(width: Theme.cardWidth)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .background {
            if selected {
                RoundedRectangle(
                    cornerRadius: Theme.cardCorner + Theme.selectedCardRing,
                    style: .continuous
                )
                .fill(Theme.selection.opacity(isLead ? 1 : 0.55))
                .padding(-Theme.selectedCardRing)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(selected ? .white.opacity(isLead ? 0.95 : 0.45) : Theme.cardBorder,
                              lineWidth: selected ? (isLead ? 2 : 1.5) : 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        .scaleEffect(hovering && !selected ? 1.015 : 1.0)
        .zIndex(selected ? (isLead ? 2 : 1) : 0)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            pasteCard()
        }
        .onTapGesture {
            // Only reached for cards with no drag source (that overlay claims
            // every left-mouse-down otherwise). SwiftUI's tap carries no
            // modifiers, so read them from the event still in flight.
            selectCard(NSEvent.modifierFlags)
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu { menu }
        .task(id: item.id) { await loadFileThumbnail() }
        .overlay {
            // A native dragging session instead of .onDrag: multi-file clips
            // drag out as real separate file items, and the session reports
            // its on-screen position so the bar hides exactly when the drag
            // leaves it. The overlay claims left-clicks, so it reproduces
            // the select/open taps itself. The writers are built lazily at
            // drag start - building them here would re-encode image clips
            // on every card render.
            if ClipDragProvider.canDrag(item) {
                ClipDragSource(
                    // Dragging a card that is part of a multi-selection takes
                    // the whole selection with it, like dragging a group of
                    // files in Finder.
                    makeWriters: {
                        let dragged = store.selectedIDs.contains(item.id)
                            ? store.selectedItems
                            : [item]
                        return dragged.flatMap(ClipDragProvider.pasteboardWriters(for:))
                    },
                    onSelect: { selectCard($0) },
                    onOpen: { pasteCard() },
                    onDragStarted: { AppController.shared.beginDragOut(itemID: item.id) },
                    onDragExitedBar: { AppController.shared.dragSessionExitedBar() }
                )
            }
        }
    }

    private var header: some View {
        ZStack {
            headerColor
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cardTypeLabel)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.headerText)
                    // Pinned clips are kept deliberately, so "when it was
                    // copied" is noise there — the timestamp is history-only.
                    if !isPinboardCard {
                        Text(item.createdAt.clipRelativeLong)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.headerSubText)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                if pinnedBoardID != nil { pinBadge }
                if settings.pasteStyleCards {
                    // The enlarged icon is an overlay so its overhang can't
                    // stretch the header; this only reserves the width its
                    // visible part covers, keeping the title clear of it.
                    Color.clear.frame(width: enlargedIconReservedWidth, height: 1)
                } else {
                    appIconTile
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, settings.pasteStyleCards ? 5 : 7)
        }
        .frame(height: settings.pasteStyleCards ? Theme.enlargedHeaderHeight : Theme.headerHeight)
        .overlay(alignment: .topTrailing) {
            if settings.pasteStyleCards { enlargedAppIcon }
        }
    }

    /// Scaled past the card's top and trailing edges, then cropped by the
    /// card's own rounded rectangle — the icon frames the corner instead of
    /// sitting fully inside a tile.
    private var enlargedAppIcon: some View {
        let icon = AppIconProvider.trimmedIcon(forBundleID: item.sourceBundleID)
        let aspect = icon.size.height > 0 ? icon.size.width / icon.size.height : 1
        return Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: Theme.enlargedIconSize * aspect, height: Theme.enlargedIconSize)
            .offset(x: Theme.enlargedIconOverhang, y: -Theme.enlargedIconRise)
            .allowsHitTesting(false)
    }

    /// A multi-file clip is one clip of many files, so the count is the
    /// headline - naming only the first file hid the other four.
    private var cardTypeLabel: String {
        guard item.type == .file, item.fileURLs.count > 1 else { return item.type.label }
        return "\(item.fileURLs.count) files"
    }

    private var enlargedIconReservedWidth: CGFloat {
        Theme.enlargedIconSize - Theme.enlargedIconOverhang - 13
    }

    private var appIconTile: some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(Color.white.opacity(0.14))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14))
            )
            .frame(width: 56, height: 56)
            .overlay(
                Image(nsImage: AppIconProvider.icon(forBundleID: item.sourceBundleID))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 48, height: 48)
            )
    }

    private var body_: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsFullBleedImage {
                imageCanvas
            } else {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 13)
                    .padding(.top, 11)
            }
            footer
                .padding(.horizontal, 13)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.cardBody)
    }

    /// Image clips run edge to edge instead of sitting inset in the card body:
    /// a padded thumbnail wastes the card's whole point, which is recognizing
    /// the picture at a glance. A copied screenshot arrives as a *file* rather
    /// than image data, so file clips pointing at an image get the same
    /// treatment - the distinction is invisible to the person who copied it.
    private var showsFullBleedImage: Bool {
        settings.pasteStyleCards && (item.type == .image || singleImageFileURL != nil)
    }

    /// Matched on the path extension rather than by loading the file: this is
    /// evaluated on every card render, so it must not touch disk.
    private var singleImageFileURL: URL? {
        guard item.type == .file,
              item.fileURLs.count == 1,
              let url = item.fileURLs.first.flatMap(URL.init(string:)),
              url.isFileURL,
              let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image) else { return nil }
        return url
    }

    private var fullBleedImage: NSImage? {
        if item.type == .image { return cardImage }
        return filePreviewImage
    }

    private var imageCanvas: some View {
        ZStack {
            // Transparency has to be visible, not guessed at — an image with a
            // cut-out is otherwise indistinguishable from one on white.
            CheckerboardBackground()
            if let img = fullBleedImage {
                Image(nsImage: img)
                    .resizable().interpolation(.medium).scaledToFit()
            } else {
                placeholder("photo")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var content: some View {
        switch item.type {
        case .image:
            if let img = cardImage {
                Image(nsImage: img)
                    .resizable().interpolation(.medium).scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { placeholder("photo") }
        case .color:
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(hex: item.colorHex ?? "#000") ?? .black)
                Text(item.colorHex ?? "")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white).shadow(radius: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .file:
            fileContent
        case .link:
            LinkCardPreview(text: item.text ?? item.displayTitle,
                            titleOverride: item.customTitle)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        case .richText:
            RichTextContent(rtfData: item.rtfData, fallback: item.cardPreviewText, lineLimit: 10)
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
        case .text:
            // Bounded on purpose: `lineLimit` caps what is drawn, but Text
            // still lays out everything it is handed.
            Text(item.cardPreviewText)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
                .lineLimit(10)
                .multilineTextAlignment(.leading)
        }
    }

    private func placeholder(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 30))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var fileContent: some View {
        if item.fileURLs.count > 1 {
            stackedFileIcons
        } else if let image = filePreviewImage {
            VStack(spacing: 8) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(item.displayTitle).font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let thumbnail = fileThumbnail {
            // A real preview of the contents, the way Quick Look renders it:
            // the type icon says which app opens the file, not what is in it.
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
        } else {
            VStack(spacing: 10) {
                // No preview available: the file's own icon, at a size worth
                // looking at, is the whole identity such a clip has.
                Image(nsImage: fileIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Theme.fileIconSize, height: Theme.fileIconSize)
                    .opacity(fileIsMissing ? 0.5 : 1)
                if fileIsMissing {
                    // Without this the card looks like a failed render rather
                    // than what it is: a clip whose file has moved or gone.
                    Text("File not found")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The real file's icon when it is still there, and the icon for its type
    /// when it is not — asking the workspace about a path that no longer
    /// exists yields a blank page, which looks like a bug.
    private var fileIcon: NSImage {
        guard let url = item.fileURLs.first.flatMap(URL.init(string:)), url.isFileURL else {
            return NSWorkspace.shared.icon(for: .data)
        }
        if !fileIsMissing { return NSWorkspace.shared.icon(forFile: url.path) }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    /// Thumbnails are generated off the main actor by the system and cached,
    /// so scrolling the strip does not re-render a preview per frame.
    private func loadFileThumbnail() async {
        guard item.type == .file,
              let url = item.fileURLs.first.flatMap(URL.init(string:)),
              url.isFileURL else { return }
        fileIsMissing = !FileManager.default.fileExists(atPath: url.path)
        guard !fileIsMissing,
              item.fileURLs.count == 1,
              singleImageFileURL == nil else { return }
        if let cached = FileThumbnailProvider.shared.cached(for: url) {
            fileThumbnail = cached
            return
        }
        fileThumbnail = await FileThumbnailProvider.shared.thumbnail(
            for: url,
            size: CGSize(width: Theme.cardWidth - 26, height: 190),
            scale: NSScreen.main?.backingScaleFactor ?? 2)
    }

    /// The real icons of the first few files, fanned out behind one another:
    /// it shows both what kind of files these are and that there is more than
    /// one, which a single generic page icon cannot.
    private var stackedFileIcons: some View {
        let urls = Array(item.fileURLs.prefix(3).compactMap { URL(string: $0) })
        return ZStack {
            // Reversed so the first file lands on top of the stack.
            ForEach(Array(urls.enumerated()).reversed(), id: \.offset) { index, url in
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Theme.fileIconSize, height: Theme.fileIconSize)
                    .opacity(index == 0 ? 1 : 0.92)
                    .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
                    .offset(x: CGFloat(index) * -12, y: CGFloat(index) * -10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filePreviewImage: NSImage? {
        guard item.fileURLs.count == 1, let urlString = item.fileURLs.first,
              let url = URL(string: urlString), url.isFileURL else { return nil }
        return NSImage(contentsOf: url)
    }

    private var cardImage: NSImage? {
        pasteStackEntry?.imagePreview ?? store.loadImage(for: item)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .bottom, spacing: 6) {
                // A path is worth reading in full, so it wraps rather than
                // collapsing to an ellipsis; everything else stays one line.
                Text(metaLeft)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(item.type == .file ? 3 : 1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let entry = pasteStackEntry {
                    Text(entry.isPasted ? "Pasted" : "Ready")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(entry.isPasted ? Theme.textTertiary : Theme.selection)
                } else if store.source != .pasteStack, index < 9 {
                    HStack(spacing: 3) {
                        Text(settings.quickPasteModifierDisplay)
                            .font(.system(size: 11, weight: .semibold))
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.top, 8)
    }

    private var metaLeft: String {
        switch item.type {
        case .text, .richText:
            return "\(ClipTextMetrics.characterCount(of: item)) characters"
        case .link:
            return (item.text ?? "").replacingOccurrences(of: "https://", with: "")
                                    .replacingOccurrences(of: "http://", with: "")
        case .file:
            guard item.fileURLs.count == 1,
                  let url = item.fileURLs.first.flatMap(URL.init(string:)) else {
                return item.fileURLs
                    .compactMap { URL(string: $0)?.lastPathComponent }
                    .joined(separator: ", ")
            }
            // An image shows what it is, so its size is the useful fact; a
            // screenshot's path is a timestamped folder nobody reads. Files
            // without a preview get the full location instead, since two
            // documents of the same name differ only by where they live.
            if singleImageFileURL != nil {
                guard let size = ImagePixelSize.of(url) else { return url.lastPathComponent }
                return "\(Int(size.width)) × \(Int(size.height))"
            }
            return (url.path as NSString).abbreviatingWithTildeInPath
        case .image:
            guard let size = ImagePixelSize.of(item) else { return "Image" }
            return "\(Int(size.width)) × \(Int(size.height))"
        case .color:
            return item.colorHex ?? "Color"
        }
    }

    @ViewBuilder
    private var menu: some View {
        if let entry = pasteStackEntry {
            if entry.isPasted {
                Button { AppController.shared.reAddPasteStackEntry(entry) } label: {
                    Label("Re-add to Stack", systemImage: "arrow.uturn.left")
                }
            } else {
                Button { AppController.shared.pasteStackEntry(entry) } label: {
                    Label(AppController.shared.pasteMenuTitle, systemImage: "doc.on.clipboard")
                }
                .keyboardShortcut(.return, modifiers: [])

                Button { AppController.shared.pasteStackEntry(entry, format: .plainText) } label: {
                    Label("Paste as Plain Text", systemImage: "text.alignleft")
                }
                .keyboardShortcut(.return, modifiers: .shift)
                .disabled(item.plainText == nil)

                Button { AppController.shared.pasteStackEntry(entry, format: .cleanFormatting) } label: {
                    Label("Paste with Clean Formatting", systemImage: "paintbrush")
                }
                .disabled(!FormatConverter.canConvert(item))

                Button { AppController.shared.pasteStackEntry(entry, format: .markdown) } label: {
                    Label("Paste as Markdown", systemImage: "number")
                }
                .disabled(!FormatConverter.canConvert(item))
            }

            Button { AppController.shared.copyItem(item) } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .command)

            // Only meaningful while a Pinboard is on screen: promotion is a
            // property of the clip's place on *this* board.
            if let boardID = store.currentPinboardID {
                Divider()
                Button {
                    for target in actionTargets { store.togglePin(target.id, inBoard: boardID) }
                } label: {
                    Label(pinnedBoardID != nil ? "Unpin from Top" : "Pin to Top",
                          systemImage: pinnedBoardID != nil ? "pin.slash" : "pin")
                }
            }

            Divider()

            editAndRenameActions

            Button(role: .destructive) {
                AppController.shared.removePasteStackEntry(entry)
            } label: {
                Label("Remove from Paste Stack", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: [])

            Divider()
            pinMenu

            Divider()
            previewAndShareActions
        } else {
            Button { AppController.shared.pasteItem(item) } label: {
                Label(AppController.shared.pasteMenuTitle, systemImage: "doc.on.clipboard")
            }
            .keyboardShortcut(.return, modifiers: [])

            Button { AppController.shared.pasteItem(item, format: .plainText) } label: {
                Label("Paste as Plain Text", systemImage: "text.alignleft")
            }
            .keyboardShortcut(.return, modifiers: .shift)
            .disabled(item.plainText == nil)

            Button { AppController.shared.pasteItem(item, format: .cleanFormatting) } label: {
                Label("Paste with Clean Formatting", systemImage: "paintbrush")
            }
            .disabled(!FormatConverter.canConvert(item))

            Button { AppController.shared.pasteItem(item, format: .markdown) } label: {
                Label("Paste as Markdown", systemImage: "number")
            }
            .disabled(!FormatConverter.canConvert(item))

            Button { AppController.shared.copyItem(item) } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .command)

            if settings.pasteStacksEnabled {
                Divider()

                Button { AppController.shared.addToPasteStack(item, toTop: true) } label: {
                    Label("Add to Top of Paste Stack", systemImage: "text.insert")
                }

                Button { AppController.shared.addToPasteStack(item, toTop: false) } label: {
                    Label("Add to Bottom of Paste Stack", systemImage: "text.append")
                }
            }

            Divider()

            editAndRenameActions

            Button(role: .destructive) {
                let permanently = NSEvent.modifierFlags.contains(.option)
                for target in actionTargets { store.delete(target, permanently: permanently) }
            } label: {
                Label(actionTargets.count > 1 ? "Delete \(actionTargets.count) Clips" : "Delete",
                      systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: [])

            Divider()
            pinMenu

            Divider()
            previewAndShareActions
        }
    }

    @ViewBuilder
    private var editAndRenameActions: some View {
        Button { AppController.shared.editItem(item) } label: {
            Label("Edit", systemImage: "pencil")
        }
        .keyboardShortcut("e", modifiers: .command)

        if writingToolsAvailable {
            Button { AppController.shared.editItem(item, launchWritingTools: true) } label: {
                Label("Writing Tools", systemImage: "pencil.and.scribble")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }

        Button { renameItem() } label: {
            Label("Rename…", systemImage: "pencil.line")
        }
        .keyboardShortcut("r", modifiers: .command)
    }

    /// Marks a clip promoted to the front of the board being viewed. It sits
    /// on the header rather than the body so it reads at a glance while
    /// scanning a row of cards.
    private var pinBadge: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Theme.headerText)
            .frame(width: 20, height: 20)
            .background(Color.black.opacity(0.22), in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.28)))
            .accessibilityLabel("Pinned to top")
    }

    private var pinMenu: some View {
        Menu {
            if !store.pinboards.isEmpty {
                ForEach(store.pinboards) { b in
                    Button {
                        for target in actionTargets { store.saveToPinboard(target, boardID: b.id) }
                    } label: {
                        PinboardMenuItemLabel(pinboard: b)
                    }
                }
                Divider()
            }
            Button { pinToNewBoard() } label: {
                Label("Create Pinboard…", systemImage: "plus")
            }
        } label: {
            Label("Pin", systemImage: "pin")
        }
    }

    @ViewBuilder
    private var previewAndShareActions: some View {
        Button { AppController.shared.showPreview(for: item) } label: {
            Label("Preview", systemImage: "eye")
        }
        .keyboardShortcut(.space, modifiers: [])

        Button { AppController.shared.showSharePicker(for: item) } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    private var writingToolsAvailable: Bool {
        guard [.text, .richText, .link].contains(item.type) else { return false }
        guard #available(macOS 15.2, *) else { return false }
        return NSWritingToolsCoordinator.isWritingToolsAvailable
    }

    private func renameItem() {
        if let title = TextPrompt.run(title: "Rename", message: "Card title",
                                      defaultValue: item.customTitle ?? "") {
            store.setTitle(title, for: item)
        }
    }

    private func pinToNewBoard() {
        if let name = TextPrompt.run(title: "Create Pinboard", message: "Name") {
            let board = store.addPinboard(name: name)
            for target in actionTargets { store.saveToPinboard(target, boardID: board.id) }
        }
    }

    /// macOS list conventions: ⇧ extends a contiguous run from the anchor,
    /// ⌘ toggles one card in or out, anything else replaces the selection.
    /// What a menu action applies to. Right-clicking a card that is part of a
    /// multi-selection acts on the whole selection, the way Finder does;
    /// right-clicking any other card acts on that card alone.
    private var actionTargets: [ClipItem] {
        guard pasteStackEntry == nil,
              store.hasMultipleSelection,
              store.selectedIDs.contains(item.id) else { return [item] }
        return store.selectedItems
    }

    private func selectCard(_ modifiers: NSEvent.ModifierFlags = []) {
        AppController.shared.focusBarCards()
        if let entry = pasteStackEntry {
            AppController.shared.pasteSequence.select(entry)
            return
        }
        if modifiers.contains(.shift) {
            store.extendSelection(to: item.id)
        } else if modifiers.contains(.command) {
            store.toggleSelection(of: item.id)
        } else {
            store.selectedID = item.id
        }
    }

    private func pasteCard() {
        if let entry = pasteStackEntry {
            if entry.isPasted {
                AppController.shared.reAddPasteStackEntry(entry)
            } else {
                AppController.shared.pasteStackEntry(entry)
            }
        } else {
            AppController.shared.pasteItem(item)
        }
    }
}

private struct PinboardMenuItemLabel: View {
    let pinboard: Pinboard

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(pinboard.color)
                .overlay {
                    Circle().stroke(.black.opacity(0.16), lineWidth: 0.5)
                }
                .frame(width: 18, height: 18)
            Text(pinboard.name)
        }
    }
}

/// The standard transparency checkerboard drawn behind image clips. Canvas
/// rather than a tiled Image: the pattern is a handful of rects, and this
/// keeps it resolution-independent without shipping an asset.
private struct CheckerboardBackground: View {
    var square: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let columns = Int(ceil(size.width / square))
            let rows = Int(ceil(size.height / square))
            for row in 0..<max(rows, 0) {
                for column in 0..<max(columns, 0) where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * square,
                                      y: CGFloat(row) * square,
                                      width: square,
                                      height: square)
                    context.fill(Path(rect), with: .color(Color(white: 0.87)))
                }
            }
        }
        .drawingGroup()
    }
}

/// Reads an image clip's pixel dimensions from the file's metadata instead of
/// decoding it, and remembers them: the card footer asks on every render.
@MainActor
enum ImagePixelSize {
    private static var cache: [String: CGSize] = [:]

    static func of(_ item: ClipItem) -> CGSize? {
        guard item.imageFileName != nil,
              let url = ClipboardStore.shared.imageURL(for: item) else { return nil }
        return of(url)
    }

    static func of(_ url: URL) -> CGSize? {
        let name = url.path
        if let cached = cache[name] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let size = CGSize(width: width, height: height)
        cache[name] = size
        return size
    }
}
