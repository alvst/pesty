import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Each tab's frame, measured live in the row's own coordinate space, so a
/// drop's (items, location) can be resolved to "insert before whichever tab
/// this point is closest to" instead of requiring a precise hit on a narrow
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

/// `.dropDestination`'s `isTargeted` only reports enter/exit, with no
/// position — not enough to draw a caret that tracks the drag. `DropDelegate`
/// is the older, lower-level API, but it reports a live `location` on every
/// `dropUpdated(info:)` call, which is what a smooth insertion-line needs.
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
        guard let provider = info.itemProviders(for: [UTType.pestyPinboard]).first else { return false }
        let x = info.location.x
        _ = provider.loadDataRepresentation(for: .pestyPinboard) { data, _ in
            guard let data,
                  let item = try? JSONDecoder().decode(PinboardDragItem.self, from: data) else { return }
            DispatchQueue.main.async {
                onDrop(item.pinboardID, x)
            }
        }
        return true
    }
}

struct PinboardTabs: View {
    @Bindable private var store = ClipboardStore.shared
    @State private var tabFrames: [UUID: CGRect] = [:]
    // Live x-position (in the row's coordinate space) of the gap the drag
    // is currently over, drawn as a thin insertion caret — nil when no
    // drag is active over the row.
    @State private var insertionX: CGFloat?
    // Visible confirmation that a reorder actually landed, since the tabs
    // themselves reordering can be easy to miss in the moment.
    @State private var moveConfirmationText: String?
    @State private var renameSession: PinboardRenameSession?
    @FocusState private var focusedRenameID: UUID?
    // Highlights whichever Pinboard tab a clip card is currently being
    // dragged over, so dropping to pin reads as a distinct target from the
    // row-wide Pinboard-reordering drop zone underneath it.
    @State private var pinDropTargetID: UUID?

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
                        .foregroundStyle(Theme.chromeTextSecondary)
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
            // top/bottom of) the row resolves to the nearest gap, so there's
            // no small boundary left to miss.
            .contentShape(Rectangle().inset(by: -20))
            .onDrop(of: [UTType.pestyPinboard], delegate: PinboardRowDropDelegate(
                onHover: { x in
                    insertionX = x.flatMap { snappedInsertionX(forHoverX: $0) }
                },
                onDrop: { draggedID, x in
                    let index = insertionIndex(forX: x)
                    let destination: PinboardDropDestination = index < store.pinboards.count
                        ? .before(store.pinboards[index].id)
                        : .end
                    _ = performPinboardDrop([PinboardDragItem(pinboardID: draggedID)], at: destination)
                }
            ))
        }
        .overlay(alignment: .top) {
            if let moveConfirmationText {
                Text(moveConfirmationText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.chromeTextPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.selection, in: Capsule())
                    .offset(y: -30)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: moveConfirmationText)
        .onChange(of: focusedRenameID) { oldValue, newValue in
            guard let oldValue, oldValue != newValue,
                  let session = renameSession,
                  session.boardID == oldValue else { return }
            // Clicking away commits a valid draft and cancels a blank draft.
            resolveRename(session.focusLost(), for: oldValue)
        }
    }

    @ViewBuilder
    private func boardTab(_ board: Pinboard) -> some View {
        if renameSession?.boardID == board.id {
            inlineRenameField(for: board)
        } else {
            draggableBoardTab(board)
                .contextMenu { pinboardContextMenu(board) }
                .onChange(of: board.name) { _, newName in
                    receiveRemoteName(newName, for: board.id)
                }
        }
    }

    private func draggableBoardTab(_ board: Pinboard) -> some View {
        let canMoveLeft = store.pinboards.first?.id != board.id
        let canMoveRight = store.pinboards.last?.id != board.id

        // Built from a plain, non-Button view: a SwiftUI `Button` claims the
        // press gesture before `.draggable` can start a drag session, so
        // reordering never actually began. Click-to-select is wired as a
        // *simultaneous* gesture (not `.onTapGesture`, which is itself an
        // exclusive discrete gesture and blocks `.draggable` the same way a
        // `Button` does) so the drag gesture is free to win once the mouse
        // actually moves.
        return pillLabel(title: board.name,
                          dot: board.color,
                          icon: nil,
                          selected: store.source == .pinboard(board.id))
        // A Rectangle (not Capsule) so the whole pill — including its
        // rounded ends — is uniformly grabbable. A Capsule's hit area
        // tapers toward the rounded corners, so only the flat middle
        // (roughly where the text sits) reliably caught the gesture before.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            store.source = .pinboard(board.id)
            store.selectFirst()
        })
        .draggable(PinboardDragItem(pinboardID: board.id))
        .help("Drag to reorder Pinboards")
        .modifier(PinboardMoveAccessibilityActions(
            canMoveLeft: canMoveLeft,
            canMoveRight: canMoveRight,
            moveLeft: { _ = store.movePinboard(board.id, by: -1) },
            moveRight: { _ = store.movePinboard(board.id, by: 1) }
        ))
        .overlay {
            if pinDropTargetID == board.id {
                RoundedRectangle(cornerRadius: 100, style: .continuous)
                    .strokeBorder(Theme.selection, lineWidth: 2)
            }
        }
        .onDrop(of: [ClipDragProvider.clipIdentifierType],
                isTargeted: Binding(
                    get: { pinDropTargetID == board.id },
                    set: { targeted in
                        if targeted {
                            pinDropTargetID = board.id
                        } else if pinDropTargetID == board.id {
                            pinDropTargetID = nil
                        }
                    }
                )
        ) { providers in
            pinClip(from: providers, ontoBoardID: board.id)
        }
    }

    private func inlineRenameField(for board: Pinboard) -> some View {
        HStack(spacing: 6) {
            Circle().fill(board.color).frame(width: 7, height: 7)
            TextField("Pinboard name", text: renameBinding(for: board.id))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.chromeTextPrimary)
                .frame(width: 120)
                .focused($focusedRenameID, equals: board.id)
                .onSubmit {
                    guard let session = renameSession,
                          session.boardID == board.id else { return }
                    resolveRename(session.returnPressed(), for: board.id)
                }
                .onExitCommand {
                    guard let session = renameSession,
                          session.boardID == board.id else { return }
                    resolveRename(session.escapePressed(), for: board.id)
                }
                .accessibilityLabel("Pinboard name")
        }
        .padding(.horizontal, 12)
        .frame(height: 29)
        .background(Theme.pillSelected, in: Capsule())
        .fixedSize()
    }

    @ViewBuilder
    private func pinboardContextMenu(_ board: Pinboard) -> some View {
        Button { beginRenaming(board) } label: {
            Label("Rename…", systemImage: "pencil")
        }
        Menu {
            ForEach(PinboardColorOption.all) { color in
                Button {
                    store.setPinboardColor(board.id, to: color.hex)
                } label: {
                    let isCurrent = board.colorHex.caseInsensitiveCompare(color.hex) == .orderedSame
                    Label {
                        Text(isCurrent ? "\(color.name) ✓" : color.name)
                    } icon: {
                        Image(nsImage: Self.colorSwatchIcon(hex: color.hex))
                            .renderingMode(.original)
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
                      selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            pillLabel(title: title, dot: dot, icon: icon, selected: selected)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func pillLabel(title: String, dot: Color?, icon: String?,
                           selected: Bool) -> some View {
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
        .foregroundStyle(selected ? Theme.chromeTextPrimary : Theme.chromeTextSecondary)
        .padding(.horizontal, 12)
        .frame(height: 29)
        .background(selected ? Theme.pillSelected : Theme.pillBG, in: Capsule())
        .fixedSize()
        .animation(.easeOut(duration: 0.15), value: selected)
    }

    private func addPinboard() {
        let board = store.addPinboard(name: "New Pinboard")
        store.source = .pinboard(board.id)
        store.selectFirst()
        beginRenaming(board)
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

    /// Dropping a dragged clip card directly onto a Pinboard tab pins it
    /// there — a shortcut for the same "Pin to…" context-menu action.
    private func pinClip(from providers: [NSItemProvider], ontoBoardID boardID: UUID) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(ClipDragProvider.clipIdentifierType) })
        else { return false }
        _ = provider.loadDataRepresentation(forTypeIdentifier: ClipDragProvider.clipIdentifierType) { data, _ in
            guard let data,
                  let idString = String(data: data, encoding: .utf8),
                  let clipID = UUID(uuidString: idString) else { return }
            DispatchQueue.main.async {
                guard let item = (store.history + store.pinboards.flatMap(\.items))
                    .first(where: { $0.id == clipID }) else { return }
                store.saveToPinboard(item, boardID: boardID)
            }
        }
        return true
    }

    private func performPinboardDrop(
        _ items: [PinboardDragItem],
        at destination: PinboardDropDestination
    ) -> Bool {
        guard let move = PinboardDropDecision.move(
            draggedIDs: items.map(\.pinboardID),
            destination: destination,
            orderedIDs: store.pinboards.map(\.id)
        ) else { return false }

        let name = store.pinboards.first(where: { $0.id == draggedID(of: move) })?.name ?? "Pinboard"
        let succeeded: Bool
        switch move {
        case let .before(id, target):
            succeeded = store.movePinboard(id, before: target)
        case let .after(id, target):
            succeeded = store.movePinboard(id, after: target)
        case let .over(id, target):
            succeeded = store.movePinboard(id, over: target)
        case let .by(id, offset):
            succeeded = store.movePinboard(id, by: offset)
        case let .toEnd(id):
            succeeded = store.movePinboardToEnd(id)
        }

        if succeeded {
            showMoveConfirmation("Moved \"\(name)\"")
        }
        return succeeded
    }

    private func draggedID(of move: PinboardOrder.Move) -> UUID {
        switch move {
        case let .before(id, _), let .after(id, _), let .over(id, _),
             let .by(id, _), let .toEnd(id):
            return id
        }
    }

    private func showMoveConfirmation(_ text: String) {
        moveConfirmationText = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if moveConfirmationText == text {
                moveConfirmationText = nil
            }
        }
    }

    private func beginRenaming(_ board: Pinboard) {
        if let active = renameSession, active.boardID != board.id {
            resolveRename(active.focusLost(), for: active.boardID)
        }
        renameSession = PinboardRenameSession(boardID: board.id, name: board.name)
        // Driven directly here instead of the rendered field's .onAppear,
        // which doesn't fire reliably in every AppKit-hosted SwiftUI context
        // (e.g. right after a Button click is still settling its own
        // key-window focus). One run-loop turn lets that settle first.
        DispatchQueue.main.async {
            guard renameSession?.boardID == board.id else { return }
            focusedRenameID = board.id
            DispatchQueue.main.async {
                guard renameSession?.boardID == board.id,
                      focusedRenameID == board.id else { return }
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    private func renameBinding(for boardID: UUID) -> Binding<String> {
        Binding {
            guard let session = renameSession, session.boardID == boardID else { return "" }
            return session.draft
        } set: { value in
            guard renameSession?.boardID == boardID else { return }
            renameSession?.updateDraft(value)
        }
    }

    private func receiveRemoteName(_ name: String, for boardID: UUID) {
        guard var session = renameSession,
              session.receiveRemoteName(name, for: boardID) else { return }
        renameSession = session
    }

    private func resolveRename(
        _ outcome: PinboardRenameSession.Outcome,
        for boardID: UUID
    ) {
        guard renameSession?.boardID == boardID else { return }
        switch outcome {
        case let .commit(name):
            store.renamePinboard(boardID, to: name)
            endRenaming(boardID)
        case .cancel:
            endRenaming(boardID)
        case let .keepEditing(refocus):
            guard refocus else { return }
            DispatchQueue.main.async {
                guard renameSession?.boardID == boardID else { return }
                focusedRenameID = boardID
            }
        }
    }

    private func endRenaming(_ boardID: UUID) {
        guard renameSession?.boardID == boardID else { return }
        renameSession = nil
        if focusedRenameID == boardID { focusedRenameID = nil }
    }

    /// SwiftUI shapes (e.g. `Circle().fill(...)`) don't render inside a
    /// native NSMenu item's label — the menu bridge only draws image
    /// content. Rasterize the swatch as a real, non-template `NSImage`
    /// instead.
    private static func colorSwatchIcon(hex: String) -> NSImage {
        let color = NSColor(Color(hex: hex) ?? .accentColor)
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

private struct PinboardMoveAccessibilityActions: ViewModifier {
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let moveLeft: () -> Void
    let moveRight: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if canMoveLeft && canMoveRight {
            content
                .accessibilityAction(named: Text("Move Left"), moveLeft)
                .accessibilityAction(named: Text("Move Right"), moveRight)
        } else if canMoveLeft {
            content.accessibilityAction(named: Text("Move Left"), moveLeft)
        } else if canMoveRight {
            content.accessibilityAction(named: Text("Move Right"), moveRight)
        } else {
            content
        }
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
