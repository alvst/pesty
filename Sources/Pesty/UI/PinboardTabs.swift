import SwiftUI

struct PinboardTabs: View {
    @Bindable private var store = ClipboardStore.shared
    @State private var editingBoardID: UUID?
    @State private var draftName = ""
    @FocusState private var focusedBoardID: UUID?

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
                                    HStack {
                                        Circle().fill(Color(hex: color.hex) ?? .accentColor)
                                            .frame(width: 12, height: 12)
                                        Text(color.name)
                                        if board.colorHex.caseInsensitiveCompare(color.hex) == .orderedSame {
                                            Image(systemName: "checkmark")
                                        }
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
            .background(Theme.pillSelected, in: Capsule())
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
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 29)
            .background(selected ? Theme.pillSelected : Theme.pillBG, in: Capsule())
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
