import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipCardView: View {
    let item: ClipItem
    let index: Int
    let selected: Bool

    @State private var hovering = false
    private var store: ClipboardStore { ClipboardStore.shared }
    private var settings: Settings { Settings.shared }
    private var headerColor: Color { SourceColor.color(for: item.sourceBundleID) }

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
                .fill(Theme.selection)
                .padding(-Theme.selectedCardRing)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(selected ? Theme.selection : Theme.cardBorder,
                              lineWidth: selected ? 1.5 : 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        .scaleEffect(hovering && !selected ? 1.015 : 1.0)
        .zIndex(selected ? 1 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: selected)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { AppController.shared.pasteItem(item) }
        .onTapGesture { store.select(item.id) }
        .highPriorityGesture(TapGesture().modifiers(.shift).onEnded { store.extendSelection(to: item.id) })
        .highPriorityGesture(TapGesture().modifiers(.command).onEnded { store.toggleSelection(item.id) })
        .onDrag { ClipDragProvider.make(for: item) }
        .contextMenu { menu }
    }

    private var header: some View {
        ZStack {
            headerColor
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cardTypeLabel)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.headerText)
                    Text(item.createdAt.clipRelativeLong)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.headerSubText)
                }
                .lineLimit(1)
                Spacer(minLength: 4)
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

    /// A multi-file clip is one clip of many files, so the count is the
    /// headline - naming only the first file hid the other four.
    private var cardTypeLabel: String {
        guard settings.pasteStyleCards, item.type == .file, item.fileURLs.count > 1 else {
            return item.type.label
        }
        return "\(item.fileURLs.count) files"
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
        if item.type == .image { return store.loadImage(for: item) }
        return singleImageFileURL.flatMap(NSImage.init(contentsOf:))
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
            if let img = store.loadImage(for: item) {
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
            if settings.fetchLinkPreviews {
                LinkCardPreview(text: item.text ?? item.displayTitle,
                                titleOverride: item.customTitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                VStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Image(systemName: "safari").font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.cardTextTertiary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
        default:
            Text(item.text ?? "")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.cardTextPrimary.opacity(0.9))
                .lineLimit(10)
                .multilineTextAlignment(.leading)
        }
    }

    /// Paste-style file cards are carried by the file's own icon; with the
    /// toggle off the card keeps the small generic glyph it has always had.
    @ViewBuilder
    private var fileContent: some View {
        if settings.pasteStyleCards, item.fileURLs.count > 1 {
            stackedFileIcons
        } else {
            VStack(spacing: settings.pasteStyleCards ? 10 : 9) {
                fileIcon
                Text(item.displayTitle).font(.system(size: 12))
                    .foregroundStyle(Theme.cardTextSecondary).lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var fileIcon: some View {
        // The file's real icon, at a size worth looking at: the type badge is
        // the whole identity of a file that has no preview.
        if settings.pasteStyleCards,
           let url = item.fileURLs.first.flatMap(URL.init(string:)), url.isFileURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: Theme.fileIconSize, height: Theme.fileIconSize)
        } else {
            Image(systemName: "doc.fill")
                .font(.system(size: settings.pasteStyleCards ? Theme.fileIconSize * 0.6 : 32))
                .foregroundStyle(headerColor)
        }
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

    private func placeholder(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 30))
            .foregroundStyle(Theme.cardTextTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            if item.type == .link, !settings.fetchLinkPreviews {
                Text(item.displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.cardTextPrimary).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(metaLeft)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.cardTextSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if index < 9 {
                    HStack(spacing: 3) {
                        Text(settings.quickPasteModifierDisplay)
                            .font(.system(size: 11, weight: .semibold))
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Theme.cardTextTertiary)
                }
            }
        }
        .padding(.top, 8)
    }

    private var metaLeft: String {
        switch item.type {
        case .text, .richText:
            return "\(item.charCount) characters"
        case .link:
            return (item.text ?? "").replacingOccurrences(of: "https://", with: "")
                                    .replacingOccurrences(of: "http://", with: "")
        case .file:
            return "\(item.fileURLs.count) file\(item.fileURLs.count == 1 ? "" : "s")"
        case .image:
            return "Image"
        case .color:
            return item.colorHex ?? "Color"
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button { AppController.shared.pasteItem(item) } label: {
            Label(AppController.shared.pasteMenuTitle, systemImage: "doc.on.clipboard")
        }

        Button { AppController.shared.pasteItem(item, asPlainText: true) } label: {
            Label("Paste as Plain Text", systemImage: "text.alignleft")
        }
        .disabled(item.plainText == nil)

        Button { AppController.shared.copyItem(item) } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        Divider()

        Button { AppController.shared.editItem(item) } label: {
            Label("Edit", systemImage: "pencil")
        }
        .disabled(!isEditable)

        if writingToolsAvailable {
            Button { AppController.shared.editItem(item, launchWritingTools: true) } label: {
                Label("Writing Tools", systemImage: "pencil.and.scribble")
            }
        }

        Button { renameItem() } label: {
            Label("Rename…", systemImage: "pencil.line")
        }

        Divider()

        Menu {
            if store.pinboards.isEmpty {
                Button("No Pinboards Yet") {}
                    .disabled(true)
            } else {
                ForEach(store.pinboards) { b in
                    Button { store.saveToPinboard(item, boardID: b.id) } label: {
                        Label {
                            Text(b.name)
                        } icon: {
                            Image(nsImage: Self.pinboardMenuIcon(color: NSColor(b.color)))
                                .renderingMode(.original)
                        }
                    }
                }
            }
            Divider()
            Button { pinToNewBoard() } label: {
                Label("Create Pinboard…", systemImage: "plus")
            }
        } label: {
            Label("Pin", systemImage: "pin")
        }

        Divider()

        Button { AppController.shared.showPreview(for: item) } label: {
            Label("Preview", systemImage: "eye")
        }

        Button { AppController.shared.showSharePicker(for: item) } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }

        Divider()

        Button(role: .destructive) {
            let optionHeld = NSEvent.modifierFlags.contains(.option)
            AppController.shared.deleteSelection(containing: item, permanently: optionHeld)
        } label: {
            Label(deleteMenuTitle, systemImage: "trash")
        }
    }

    private var deleteMenuTitle: String {
        let count = store.multiSelectedIDs.contains(item.id) ? store.multiSelectedIDs.count : 1
        return count > 1 ? "Delete \(count) Clips" : "Delete"
    }

    private var isEditable: Bool {
        [.text, .richText, .link, .color].contains(item.type)
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
            store.saveToPinboard(item, boardID: board.id)
        }
    }

    private static func pinboardMenuIcon(color: NSColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
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
