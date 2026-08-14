import SwiftUI
import UniformTypeIdentifiers
import os.log

private let pinboardDragLog = Logger(subsystem: "com.greycorelabs.pesty", category: "PinboardDrag")

/// Each tab's frame, measured live in the row's own coordinate space, so a
/// drop's location can be resolved to "insert before whichever tab this
/// point is closest to" instead of requiring a precise hit on a narrow
/// per-tab target.
private struct TabFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// A text-cursor-style "I-beam": a vertical line with small horizontal caps
/// top and bottom, shown where a dragged Pinboard would land.
private struct InsertionCaret: View {
    var color: Color
    var height: CGFloat = 29
    var capWidth: CGFloat = 6
    var lineWidth: CGFloat = 2

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(color).frame(width: capWidth, height: lineWidth)
            Rectangle().fill(color).frame(width: lineWidth, height: height - lineWidth * 2)
            Capsule().fill(color).frame(width: capWidth, height: lineWidth)
        }
    }
}

/// One drop target spans the whole row instead of many narrow per-tab
/// targets. `dropUpdated` reports a live `location`, which drives the
/// insertion caret while dragging; the actual move only commits in
/// `performDrop`, at the position under the cursor when you release —
/// there's no "live reorder on every tab you cross" to feel erratic.
private struct PinboardRowDropDelegate: DropDelegate {
    let onHover: (CGFloat?) -> Void
    let onDrop: (UUID, CGFloat) -> Void

    func dropEntered(info: DropInfo) {
        onHover(info.location.x)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onHover(info.location.x)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        onHover(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        onHover(nil)
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let x = info.location.x
        _ = provider.loadObject(ofClass: NSString.self) { reading, _ in
            guard let idString = reading as? String, let id = UUID(uuidString: idString) else { return }
            DispatchQueue.main.async {
                onDrop(id, x)
            }
        }
        return true
    }
}

struct PinboardTabs: View {
    @Bindable private var store = ClipboardStore.shared
    @Bindable private var settings = Settings.shared
    private var stack: PasteSequence { AppController.shared.pasteSequence }
    @State private var editingBoardID: UUID?
    @State private var draftName = ""
    @FocusState private var focusedBoardID: UUID?
    @State private var tabFrames: [UUID: CGRect] = [:]
    // Live x-position (in the row's coordinate space) of the gap the drag
    // is currently over, drawn as the insertion caret — nil when no drag
    // is active over the row.
    @State private var insertionX: CGFloat?

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
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: TabFramePreferenceKey.self,
                                    value: [board.id: geo.frame(in: .named("pinboardRow"))]
                                )
                            }
                        )
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
            .padding(.vertical, 12)
            .coordinateSpace(name: "pinboardRow")
            .onPreferenceChange(TabFramePreferenceKey.self) { tabFrames = $0 }
            .overlay {
                if let insertionX {
                    GeometryReader { geo in
                        InsertionCaret(color: Theme.selection)
                            .position(x: insertionX, y: geo.size.height / 2)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.08), value: insertionX != nil)
            // One generous drop zone spans the entire row instead of many
            // narrow per-tab targets: a drop anywhere on (or well past the
            // top/bottom of) the row resolves to the nearest gap.
            .contentShape(Rectangle().inset(by: -20))
            .onDrop(of: [.plainText], delegate: PinboardRowDropDelegate(
                onHover: { x in
                    insertionX = x.flatMap { snappedInsertionX(forHoverX: $0) }
                },
                onDrop: { draggedID, x in
                    let index = insertionIndex(forX: x)
                    pinboardDragLog.debug("row drop RECEIVED at x=\(x) -> index=\(index)")
                    guard draggedID != store.pinboards[safe: index]?.id else { return }
                    if index >= store.pinboards.count {
                        store.movePinboardToEnd(draggedID)
                    } else {
                        store.movePinboard(draggedID, before: store.pinboards[index].id)
                    }
                }
            ))
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

    @ViewBuilder
    private func draggableBoardTab(_ board: Pinboard) -> some View {
        if editingBoardID == board.id {
            boardTab(board)
        } else {
            // Not built from boardTab()/pill() here: a SwiftUI `Button` claims
            // the press gesture before `.onDrag` can start a drag session, so
            // reordering never actually began. Click-to-select is wired as a
            // *simultaneous* gesture instead, which doesn't claim exclusive
            // priority, so the drag gesture is free to win once the mouse
            // actually moves.
            pillLabel(title: board.name, dot: board.color, icon: nil, badge: nil,
                      selected: store.source == .pinboard(board.id))
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                store.source = .pinboard(board.id); store.selectFirst()
            })
            .onDrag {
                pinboardDragLog.debug("onDrag FIRED for \(board.name, privacy: .public)")
                return NSItemProvider(object: board.id.uuidString as NSString)
            }
            .help("Drag to reorder Pinboards")
        }
    }

    @ViewBuilder
    private func pinboardContextMenu(_ board: Pinboard) -> some View {
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
            pillLabel(title: title, dot: dot, icon: icon, badge: badge, selected: selected)
        }
        .buttonStyle(.plain)
    }

    private func pillLabel(title: String, dot: Color?, icon: String?,
                           badge: Int?, selected: Bool) -> some View {
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

    /// Resolves an x-position (in the row's own coordinate space) to "insert
    /// before the tab at this index", or `store.pinboards.count` to mean
    /// "append at the end" — shared by the live caret and the actual drop,
    /// so the line always shows exactly where a drop would land.
    private func insertionIndex(forX x: CGFloat) -> Int {
        for (index, board) in store.pinboards.enumerated() {
            if let frame = tabFrames[board.id], x < frame.midX {
                return index
            }
        }
        return store.pinboards.count
    }

    /// The visual x-position for the insertion caret: the midpoint of the
    /// gap on either side of `insertionIndex(forX:)`, not the raw cursor
    /// position, so the line snaps cleanly between two tabs.
    private func snappedInsertionX(forHoverX x: CGFloat) -> CGFloat? {
        let frames = store.pinboards.compactMap { tabFrames[$0.id] }
        guard frames.count == store.pinboards.count, !frames.isEmpty else { return nil }
        let index = insertionIndex(forX: x)
        if index == 0 {
            return frames[0].minX - 4
        } else if index == frames.count {
            return frames[frames.count - 1].maxX + 4
        } else {
            return (frames[index - 1].maxX + frames[index].minX) / 2
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
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
