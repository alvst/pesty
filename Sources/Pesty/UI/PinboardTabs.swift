import SwiftUI
import UniformTypeIdentifiers

struct PinboardTabs: View {
    @Bindable private var store = ClipboardStore.shared
    @Bindable private var settings = Settings.shared
    private var stack: PasteSequence { AppController.shared.pasteSequence }
    @State private var draggedBoardID: UUID?
    @State private var lastDropTargetID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill(title: "Clipboard",
                     dot: nil,
                     icon: "clock",
                     selected: store.source == .history) {
                    store.source = .history; store.selectFirst()
                }

                if settings.pasteStacksEnabled {
                    pill(title: "Paste Stack",
                         dot: nil,
                         icon: "rectangle.stack.fill",
                         badge: stack.pendingCount,
                         selected: store.source == .pasteStack) {
                        AppController.shared.showPasteStackTab()
                    }
                }

                ForEach(store.pinboards) { board in
                    draggableBoardTab(board)
                        .contextMenu { pinboardContextMenu(board) }
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
                .onDrop(of: [.plainText], delegate: PinboardEndDropDelegate(
                    store: store,
                    draggedBoardID: $draggedBoardID,
                    lastDropTargetID: $lastDropTargetID
                ))
            }
        }
    }

    private func draggableBoardTab(_ board: Pinboard) -> some View {
        pill(title: board.name,
             dot: board.color,
             selected: store.source == .pinboard(board.id)) {
            store.source = .pinboard(board.id)
            store.selectFirst()
        }
        .onDrag {
            draggedBoardID = board.id
            lastDropTargetID = nil
            return NSItemProvider(object: board.id.uuidString as NSString)
        }
        .onDrop(of: [.plainText], delegate: PinboardTabDropDelegate(
            targetID: board.id,
            store: store,
            draggedBoardID: $draggedBoardID,
            lastDropTargetID: $lastDropTargetID
        ))
        .help("Drag to reorder Pinboards")
    }

    @ViewBuilder
    private func pinboardContextMenu(_ board: Pinboard) -> some View {
        Button("Rename…") { rename(board) }
        Divider()
        Button { store.movePinboard(board.id, by: -1) } label: {
            Label("Move Left", systemImage: "arrow.left")
        }
        .disabled(store.pinboards.first?.id == board.id)
        Button { store.movePinboard(board.id, by: 1) } label: {
            Label("Move Right", systemImage: "arrow.right")
        }
        .disabled(store.pinboards.last?.id == board.id)
        Divider()
        Button("Delete Pinboard", role: .destructive) {
            store.deletePinboard(board.id)
        }
    }

    private func pill(title: String, dot: Color?, icon: String? = nil,
                      badge: Int? = nil,
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
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(selected ? .white : Theme.selection)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(selected ? Theme.selection : Theme.selection.opacity(0.14), in: Capsule())
                }
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
    }

    private func rename(_ board: Pinboard) {
        if let name = TextPrompt.run(title: "Rename Pinboard",
                                     message: "Enter a new name",
                                     defaultValue: board.name) {
            store.renamePinboard(board.id, to: name)
        }
    }
}

private struct PinboardTabDropDelegate: DropDelegate {
    let targetID: UUID
    let store: ClipboardStore
    @Binding var draggedBoardID: UUID?
    @Binding var lastDropTargetID: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        draggedBoardID != nil && draggedBoardID != targetID
    }

    func dropEntered(info: DropInfo) {
        guard let draggedBoardID,
              draggedBoardID != targetID,
              lastDropTargetID != targetID else { return }
        lastDropTargetID = targetID
        store.movePinboard(draggedBoardID, over: targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedBoardID = nil
        lastDropTargetID = nil
        return true
    }
}

private struct PinboardEndDropDelegate: DropDelegate {
    let store: ClipboardStore
    @Binding var draggedBoardID: UUID?
    @Binding var lastDropTargetID: UUID?

    func validateDrop(info: DropInfo) -> Bool { draggedBoardID != nil }

    func dropEntered(info: DropInfo) {
        guard let draggedBoardID else { return }
        store.movePinboardToEnd(draggedBoardID)
        lastDropTargetID = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedBoardID = nil
        lastDropTargetID = nil
        return true
    }
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
