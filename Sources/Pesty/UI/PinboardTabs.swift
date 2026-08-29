import SwiftUI
import UniformTypeIdentifiers
import os.log

private let pinboardDragLog = Logger(subsystem: "com.alvst.pesty-alvie", category: "PinboardDrag")

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
/// top and bottom, shown where a dragged Pinboard tab or clip card would land.
struct InsertionCaret: View {
    var color: Color
    var height: CGFloat = 29
    var capWidth: CGFloat = 8
    var lineWidth: CGFloat = 3

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(color).frame(width: capWidth, height: lineWidth)
            Rectangle().fill(color).frame(width: lineWidth, height: height - lineWidth * 2)
            Capsule().fill(color).frame(width: capWidth, height: lineWidth)
        }
        // The caret floats over card content of any brightness; the halo
        // keeps it legible on both.
        .shadow(color: .black.opacity(0.55), radius: 2)
        .shadow(color: .white.opacity(0.35), radius: 0.5)
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
    /// Clip drags (a card dragged from the strip) target a whole tab to pin
    /// onto, not a gap between tabs, so they get their own hover/drop pair.
    let onClipHover: (CGFloat?) -> Void
    let onClipDrop: (UUID, CGFloat) -> Void

    /// Clip cards also carry plain text for drags into other apps, so the
    /// private clip-ID type — not .plainText — is what tells a card drag
    /// apart from a Pinboard tab reorder.
    private func isClipDrag(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.pestyClipID])
    }

    func dropEntered(info: DropInfo) {
        isClipDrag(info) ? onClipHover(info.location.x) : onHover(info.location.x)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if isClipDrag(info) {
            onClipHover(info.location.x)
            return DropProposal(operation: .copy)
        }
        // An Escape-cancelled drag empties the drag pasteboard; a session
        // with neither payload gets no hover chrome and no drop.
        guard info.hasItemsConforming(to: [.plainText]) else {
            onHover(nil)
            onClipHover(nil)
            return DropProposal(operation: .cancel)
        }
        onHover(info.location.x)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        onHover(nil)
        onClipHover(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        onHover(nil)
        onClipHover(nil)
        let x = info.location.x
        pinboardDragLog.debug("row performDrop: clip=\(self.isClipDrag(info)) x=\(x)")
        if isClipDrag(info) {
            // The pasteboard type is only a marker; the actual clip is
            // remembered in-process when the drag starts.
            guard let id = AppController.shared.draggedClipID else {
                pinboardDragLog.debug("row clip drop: no dragged clip (cancelled?)")
                return false
            }
            onClipDrop(id, x)
            return true
        }
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
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
    // The Pinboard tab a dragged clip card is currently over — highlighted
    // as the pin target. nil when no clip drag is over the row.
    @State private var clipDropBoardID: UUID?
    @State private var chromeWatchdog: Task<Void, Never>?

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
                        .foregroundStyle(Theme.chromeTextMuted)
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
            .onDrop(of: [.plainText, .pestyClipID], delegate: PinboardRowDropDelegate(
                onHover: { x in
                    insertionX = x.flatMap { snappedInsertionX(forHoverX: $0) }
                    watchForDragEnd()
                },
                onDrop: { draggedID, x in
                    let index = insertionIndex(forX: x)
                    pinboardDragLog.debug("row drop RECEIVED at x=\(x) -> index=\(index)")
                    defer { AppController.shared.restoreFocusAfterInBarDrop() }
                    guard draggedID != store.pinboards[safe: index]?.id else { return }
                    if index >= store.pinboards.count {
                        store.movePinboardToEnd(draggedID)
                    } else {
                        store.movePinboard(draggedID, before: store.pinboards[index].id)
                    }
                },
                onClipHover: { x in
                    let target = x.flatMap { boardID(atX: $0) }
                    if target != clipDropBoardID {
                        pinboardDragLog.debug("clipDropBoardID -> \(target?.uuidString ?? "nil", privacy: .public)")
                        clipDropBoardID = target
                    }
                    watchForDragEnd()
                },
                onClipDrop: { clipID, x in
                    clipDropBoardID = nil
                    let frameDesc = store.pinboards
                        .map { b in "\(b.name):\(tabFrames[b.id].map { "\(Int($0.minX))-\(Int($0.maxX))" } ?? "nil")" }
                        .joined(separator: " ")
                    pinboardDragLog.debug("clip drop id=\(clipID) x=\(x) frames=[\(frameDesc, privacy: .public)]")
                    guard let boardID = boardID(atX: x) else {
                        pinboardDragLog.debug("clip drop MISSED every tab")
                        return
                    }
                    AppController.shared.pinClip(id: clipID, toBoard: boardID)
                }
            ))
        }
        .onChange(of: focusedBoardID) { oldValue, newValue in
            if let oldValue, oldValue == editingBoardID, newValue != oldValue {
                finishEditing()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pestyDragSessionEnded)) { _ in
            pinboardDragLog.debug("drag ended: clearing row hover chrome")
            insertionX = nil
            clipDropBoardID = nil
            // A trailing dropUpdated delivered after this notification can
            // repaint; sweep once more after the session is definitely gone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                insertionX = nil
                clipDropBoardID = nil
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
                    .foregroundStyle(Theme.pillText)
                    .frame(minWidth: 92, idealWidth: 120)
                    .focused($focusedBoardID, equals: board.id)
                    .onSubmit(finishEditing)
            }
            .padding(.horizontal, 12)
            .frame(height: 29)
            .background(Theme.pillSelected, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.pillStroke, lineWidth: 1))
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
                AppController.shared.beginTabDrag()
                return NSItemProvider(object: board.id.uuidString as NSString)
            }
            .overlay(
                Capsule()
                    .strokeBorder(Theme.selection, lineWidth: 2)
                    .opacity(clipDropBoardID == board.id ? 1 : 0)
            )
            .animation(.easeOut(duration: 0.1), value: clipDropBoardID == board.id)
            .help("Drag to reorder Pinboards")
            // Drag-to-reorder is mouse-only; VoiceOver gets explicit actions.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("\(board.name) Pinboard"))
            .accessibilityAddTraits(store.source == .pinboard(board.id) ? .isSelected : [])
            .accessibilityAction(named: Text("Move Left")) { moveBoard(board, by: -1) }
            .accessibilityAction(named: Text("Move Right")) { moveBoard(board, by: 1) }
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
        Button { moveBoard(board, by: -1) } label: {
            Label("Move Left", systemImage: "arrow.left")
        }
        .disabled(store.pinboards.first?.id == board.id)
        Button { moveBoard(board, by: 1) } label: {
            Label("Move Right", systemImage: "arrow.right")
        }
        .disabled(store.pinboards.last?.id == board.id)
        Divider()
        Button(role: .destructive) {
            store.deletePinboard(board.id)
        } label: {
            Label("Delete Pinboard", systemImage: "trash")
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
        .foregroundStyle(selected ? Theme.pillText : Theme.pillTextMuted)
        .padding(.horizontal, 12)
        .frame(height: 29)
        .background(selected ? Theme.pillSelected : Theme.pillBG, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.pillStroke, lineWidth: selected ? 1 : 0.5))
        .fixedSize()
        .animation(.easeOut(duration: 0.15), value: selected)
    }

    /// Menu and VoiceOver moves get spoken confirmation; a sighted user
    /// watches the tab slide, a VoiceOver user hears where it landed.
    private func moveBoard(_ board: Pinboard, by offset: Int) {
        let before = store.pinboards.firstIndex(where: { $0.id == board.id })
        store.movePinboard(board.id, by: offset)
        let after = store.pinboards.firstIndex(where: { $0.id == board.id })
        guard let before, let after, before != after else { return }
        AccessibilityNotification.Announcement(
            "Moved \(board.name) to position \(after + 1) of \(store.pinboards.count)"
        ).post()
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

    /// Drop targets can miss their final `dropExited` when a drag ends
    /// somewhere else, stranding a caret or ring on screen with no drag in
    /// progress. Watching for the mouse button's release clears the chrome in
    /// every one of those cases, while leaving it alone during a live drag
    /// that simply pauses over the row.
    private func watchForDragEnd() {
        chromeWatchdog?.cancel()
        chromeWatchdog = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                guard NSEvent.pressedMouseButtons == 0 else { continue }
                insertionX = nil
                clipDropBoardID = nil
                return
            }
        }
    }

    /// The Pinboard tab under an x-position (in the row's coordinate space),
    /// with a small tolerance so a drop just past a pill's edge still counts.
    private func boardID(atX x: CGFloat) -> UUID? {
        store.pinboards.first { board in
            guard let frame = tabFrames[board.id] else { return false }
            return x >= frame.minX - 4 && x <= frame.maxX + 4
        }?.id
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
        // `initialFirstResponder` alone is set before the alert has laid out
        // its accessory view, so the field could come up unfocused — leaving
        // the prompt looking ready to type into when it was not. Lay out
        // first, then take first responder and select what is there, so the
        // existing value can be replaced by typing.
        alert.layout()
        alert.window.initialFirstResponder = field
        alert.window.makeFirstResponder(field)
        field.selectText(nil)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}
