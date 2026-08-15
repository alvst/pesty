import AppKit
import SwiftUI

struct ClipCardView: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    /// Supplying a stack entry preserves the normal card appearance while the
    /// Paste Stack owns selection and paste behavior.
    let pasteStackEntry: PasteStackEntry?

    init(item: ClipItem,
         index: Int,
         selected: Bool,
         pasteStackEntry: PasteStackEntry? = nil) {
        self.item = item
        self.index = index
        self.selected = selected
        self.pasteStackEntry = pasteStackEntry
    }

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
                .strokeBorder(selected ? .white.opacity(0.72) : Theme.cardBorder,
                              lineWidth: selected ? 1.5 : 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        .scaleEffect(hovering && !selected ? 1.015 : 1.0)
        .zIndex(selected ? 1 : 0)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            pasteCard()
        }
        .onTapGesture {
            selectCard()
        }
        .onDrag {
            AppController.shared.beginDragOut()
            return ClipDragProvider.make(for: item)
        }
        .contextMenu { menu }
    }

    private var header: some View {
        ZStack {
            headerColor
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.type.label)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.headerText)
                    Text(item.createdAt.clipRelativeLong)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.headerSubText)
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                appIconTile
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
        }
        .frame(height: Theme.headerHeight)
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
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(.horizontal, 13)
        .padding(.top, 11)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.cardBody)
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
            RichTextContent(rtfData: item.rtfData, fallback: item.text ?? "", lineLimit: 10)
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
        case .text:
            Text(item.text ?? "")
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
        if let image = filePreviewImage {
            VStack(spacing: 8) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(item.displayTitle).font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 9) {
                Image(systemName: "doc.fill").font(.system(size: 32)).foregroundStyle(headerColor)
                Text(item.displayTitle).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
            HStack(spacing: 6) {
                Text(metaLeft)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
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

                Button { AppController.shared.pasteStackEntry(entry, asPlainText: true) } label: {
                    Label("Paste as Plain Text", systemImage: "text.alignleft")
                }
                .keyboardShortcut(.return, modifiers: .shift)
                .disabled(item.plainText == nil)
            }

            Button { AppController.shared.copyItem(item) } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .command)

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

            Button { AppController.shared.pasteItem(item, asPlainText: true) } label: {
                Label("Paste as Plain Text", systemImage: "text.alignleft")
            }
            .keyboardShortcut(.return, modifiers: .shift)
            .disabled(item.plainText == nil)

            Button { AppController.shared.copyItem(item) } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .command)

            Divider()

            editAndRenameActions

            Button(role: .destructive) {
                store.delete(item, permanently: NSEvent.modifierFlags.contains(.option))
            } label: {
                Label("Delete", systemImage: "trash")
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

    private var pinMenu: some View {
        Menu {
            if !store.pinboards.isEmpty {
                ForEach(store.pinboards) { b in
                    Button { store.saveToPinboard(item, boardID: b.id) } label: {
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
            store.saveToPinboard(item, boardID: board.id)
        }
    }

    private func selectCard() {
        AppController.shared.focusBarCards()
        if let entry = pasteStackEntry {
            AppController.shared.pasteSequence.select(entry)
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
