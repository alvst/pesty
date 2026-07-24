import AppKit
import SwiftUI

struct PinboardTabs: View {
    @Bindable private var store = ClipboardStore.shared
    @State private var editingBoardID: UUID?
    @State private var draftName = ""
    @FocusState private var focusedBoardID: UUID?

    private let activePillFill = Color.white.opacity(0.25)
    private let inactiveTabText = Color.white.opacity(0.84)

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill(title: "Clipboard",
                     dot: nil,
                     icon: "clock",
                     selected: store.source == .history) {
                    store.source = .history; store.selectFirst()
                }

                ForEach(store.pinboards) { board in
                    boardTab(board)
                    .contextMenu {
                        Button { rename(board) } label: {
                            Label("Rename…", systemImage: "pencil")
                        }
                        Menu {
                            ForEach(PinboardColorOption.all) { color in
                                Button { store.setPinboardColor(board.id, to: color.hex) } label: {
                                    Label {
                                        Text(board.colorHex.caseInsensitiveCompare(color.hex) == .orderedSame
                                             ? "✓  \(color.name)"
                                             : color.name)
                                    } icon: {
                                        Image(nsImage: color.menuSwatch)
                                    }
                                }
                            }
                        } label: {
                            Label("Color", systemImage: "paintpalette")
                        }
                        Button("Delete Pinboard", role: .destructive) {
                            store.deletePinboard(board.id)
                        }
                    }
                }

                Button(action: addPinboard) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(Theme.fieldBG, in: Circle())
                }
                .buttonStyle(.plain)
                .help("New Pinboard")
            }
        }
        .onChange(of: focusedBoardID) { oldValue, newValue in
            if let oldValue, oldValue == editingBoardID, newValue != oldValue {
                finishEditing()
            }
        }
    }

    @ViewBuilder
    private func boardTab(_ board: Pinboard) -> some View {
        if editingBoardID == board.id {
            HStack(spacing: 6) {
                Circle().fill(board.color).frame(width: 7, height: 7)
                TextField("Pinboard name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minWidth: 92, idealWidth: 120)
                    .focused($focusedBoardID, equals: board.id)
                    .onSubmit(finishEditing)
            }
            .padding(.horizontal, 12)
            .frame(height: 29)
            .background(activePillFill, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .fixedSize()
        } else {
            pill(title: board.name,
                 dot: board.color,
                 selected: store.source == .pinboard(board.id)) {
                store.source = .pinboard(board.id); store.selectFirst()
            }
        }
    }

    private func pill(title: String, dot: Color?, icon: String? = nil,
                      selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
                if let dot {
                    Circle().fill(dot).frame(width: 7, height: 7)
                }
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Theme.textPrimary : inactiveTabText)
            .padding(.horizontal, 12)
            .frame(height: 29)
            .background(selected ? activePillFill : .clear, in: Capsule())
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(selected ? 0.12 : 0), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .animation(.easeOut(duration: 0.15), value: selected)
    }

    private func addPinboard() {
        let board = store.addPinboard(name: "New Pinboard")
        store.source = .pinboard(board.id)
        beginEditing(board)
    }

    private func rename(_ board: Pinboard) {
        beginEditing(board)
    }

    private func beginEditing(_ board: Pinboard) {
        editingBoardID = board.id
        draftName = board.name
        DispatchQueue.main.async {
            focusedBoardID = board.id
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    private func finishEditing() {
        guard let id = editingBoardID else { return }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { store.renamePinboard(id, to: name) }
        editingBoardID = nil
        focusedBoardID = nil
    }
}

private struct PinboardColorOption: Identifiable {
    let name: String
    let hex: String

    var id: String { hex }

    /// AppKit's native menus retain `NSImage` icons but discard SwiftUI shapes,
    /// so use a small non-template image for a reliably colored menu swatch.
    var menuSwatch: NSImage {
        let size = NSSize(width: 13, height: 13)
        let image = NSImage(size: size)
        image.lockFocus()

        let inset: CGFloat = 1
        let circle = NSRect(x: inset, y: inset,
                            width: size.width - inset * 2,
                            height: size.height - inset * 2)
        (NSColor(hex: hex) ?? .controlAccentColor).setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSColor.black.withAlphaComponent(0.18).setStroke()
        NSBezierPath(ovalIn: circle).stroke()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    static let all = [
        Self(name: "Red", hex: "#FF3B5C"),
        Self(name: "Orange", hex: "#FF8A2B"),
        Self(name: "Yellow", hex: "#F5B700"),
        Self(name: "Green", hex: "#34C759"),
        Self(name: "Blue", hex: "#0A84FF"),
        Self(name: "Purple", hex: "#BF3BE0"),
        Self(name: "Pink", hex: "#FF2D55"),
        Self(name: "Gray", hex: "#98989F")
    ]
}

@MainActor
enum TextPrompt {
    static func run(title: String, message: String, defaultValue: String = "") -> String? {
        AppController.shared.suppressAutoHide = true
        defer { AppController.shared.suppressAutoHide = false }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}
