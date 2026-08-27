import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os.log

private let clipDragLog = Logger(subsystem: "com.greycorelabs.pesty", category: "PinboardDrag")

struct BarView: View {
    private static let stripStartID = "pesty.clip-strip.start"

    let searchBridge: BarSearchFieldBridge
    @Bindable private var store = ClipboardStore.shared
    @Bindable private var settings = Settings.shared
    private var monitor: ClipboardMonitor { AppController.shared.monitor }
    private var sequence: PasteSequence { AppController.shared.pasteSequence }
    private var showsStackDeck: Bool {
        settings.pasteStacksEnabled
            && store.source == .history
            && store.searchText.isEmpty
            && sequence.hasSavedStacks
    }
    @State private var resizeStartHeight: Double?
    @State private var resizeStartScreenY: CGFloat?
    @State private var cardFrames: [UUID: CGRect] = [:]
    // Live x-position of the gap a dragged clip card is over while
    // reordering within a Pinboard — nil when no such drag is active.
    @State private var stripInsertionX: CGFloat?

    var body: some View {
        ZStack {
            panelBackground
            VStack(spacing: 0) {
                if settings.showBarResizeHandle { resizeHandle }
                topBar
                if settings.pasteStacksEnabled, store.source == .pasteStack {
                    PasteStackContentView()
                } else {
                    strip
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .coordinateSpace(name: "PestyBar")
        .onPreferenceChange(ClipCardFramePreferenceKey.self) {
            cardFrames = $0
            updateFloatingPreview()
        }
        .onChange(of: store.inlinePreviewVisible) { _, visible in
            guard visible else { return }
            DispatchQueue.main.async { updateFloatingPreview() }
        }
        .onChange(of: store.selectedID) { _, _ in
            guard store.inlinePreviewVisible else { return }
            DispatchQueue.main.async { updateFloatingPreview() }
        }
        .onChange(of: store.source) { _, source in
            // A reorder caret from one view must not survive into another.
            stripInsertionX = nil
            guard store.inlinePreviewVisible else { return }
            guard source != .pasteStack else {
                AppController.shared.hideInlinePreview()
                return
            }
            DispatchQueue.main.async { updateFloatingPreview() }
        }
        .clipShape(RoundedCorners(radius: Theme.cornerRadius, corners: [.topLeft, .topRight]))
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var panelBackground: some View {
        if #available(macOS 26.0, *) {
            Theme.panelTint
        } else {
            VisualEffectView(material: .hudWindow)
            Theme.panelTint
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            if settings.iCloudSync {
                syncButton
            }
            searchIndicator
            PinboardTabs()
                .layoutPriority(1)
            Spacer(minLength: 8)
            if store.source != .pasteStack {
                if settings.clipPreviewStyle == .inlinePesty { previewButton }
                if settings.pasteStacksEnabled { startPasteStackButton }
            }
            if store.hasUndoableDeletion { undoDeleteButton }
            moreMenu
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private var previewButton: some View {
        Button { AppController.shared.toggleInlinePreview() } label: {
            Image(systemName: store.inlinePreviewVisible ? "rectangle.on.rectangle" : "rectangle.on.rectangle.angled")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(store.inlinePreviewVisible ? Theme.selection : Theme.chromeTextMuted)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help(store.inlinePreviewVisible ? "Hide clip preview" : "Show clip preview")
    }

    private func updateFloatingPreview() {
        guard settings.clipPreviewStyle == .inlinePesty,
              store.source != .pasteStack,
              store.inlinePreviewVisible,
              let item = store.selectedItem,
              let frame = cardFrames[item.id] else { return }
        AppController.shared.updateInlinePreview(item: item, cardFrame: frame)
    }

    private var startPasteStackButton: some View {
        Button { AppController.shared.newPasteStack() } label: {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.selection)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help("Start Paste Stack")
    }

    private var undoDeleteButton: some View {
        Button { store.undoLastDelete() } label: {
            Label("Undo", systemImage: "arrow.uturn.backward")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.chromeText)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.fieldBG, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Undo last deleted item")
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private var resizeHandle: some View {
        HStack {
            Capsule(style: .continuous)
                .fill(Theme.chromeTextFaint.opacity(0.7))
                .frame(width: 42, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 14)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in
                    beginResizeIfNeeded()
                    guard let height = resizedHeight else { return }
                    // Resize live without publishing the preference on every
                    // pointer event. The panel's top edge moves during this
                    // gesture, so screen coordinates avoid a feedback loop
                    // through the handle's local coordinate space.
                    AppController.shared.resizeVisibleBar(to: height)
                }
                .onEnded { _ in
                    if let height = resizedHeight {
                        settings.barHeight = height
                    }
                    resizeStartHeight = nil
                    resizeStartScreenY = nil
                }
        )
        .help("Drag to resize the Pesty-Alvie bar")
        // The drag gesture is invisible to VoiceOver; expose the handle as an
        // adjustable element so the bar height is controllable without a mouse.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Resize the Pesty-Alvie bar")
        .accessibilityValue("\(Int(settings.barHeight)) points tall")
        .accessibilityAdjustableAction { direction in
            let step: Double = 20
            let target = settings.barHeight + (direction == .increment ? step : -step)
            settings.barHeight = min(720, max(300, target))
            AppController.shared.resizeVisibleBar(to: settings.barHeight)
        }
    }

    private func beginResizeIfNeeded() {
        guard resizeStartHeight == nil else { return }
        resizeStartHeight = settings.barHeight
        resizeStartScreenY = NSEvent.mouseLocation.y
    }

    private var resizedHeight: Double? {
        guard let startHeight = resizeStartHeight,
              let startScreenY = resizeStartScreenY else { return nil }
        let verticalTravel = Double(NSEvent.mouseLocation.y - startScreenY)
        return min(720, max(300, startHeight + verticalTravel))
    }

    private var syncButton: some View {
        Button {
            AppController.shared.toggleICloudSync()
        } label: {
            Image(systemName: settings.iCloudSync ? "checkmark.icloud.fill" : "arrow.triangle.2.circlepath")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(settings.iCloudSync ? Theme.selection : Theme.chromeTextMuted)
        }
        .buttonStyle(.plain)
        .help(settings.iCloudSync ? "iCloud sync on" : "Turn on iCloud sync")
    }

    private var searchIsActive: Bool {
        store.barInputMode == .search || !store.searchText.isEmpty
    }

    private var searchTextBinding: Binding<String> {
        Binding(
            get: { store.searchText },
            set: { AppController.shared.updateBarSearchText($0) }
        )
    }

    private var searchIndicator: some View {
        HStack(spacing: searchIsActive ? 6 : 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(searchIsActive ? Theme.chromeText : Theme.chromeTextMuted)
                .accessibilityHidden(true)

            // Keep this native field mounted even in the compact state. The
            // key monitor can focus it synchronously and return the same first
            // key event, so type-anywhere search never loses a character.
            NativeBarSearchField(
                text: searchTextBinding,
                bridge: searchBridge,
                onBegin: { AppController.shared.setBarSearchEditing(true) },
                onEnd: { AppController.shared.setBarSearchEditing(false) },
                onSubmit: { AppController.shared.submitBarSearch() },
                onCancel: { AppController.shared.cancelBarSearchOrHide() }
            )
            .frame(minWidth: searchIsActive ? 120 : 0,
                   idealWidth: searchIsActive ? 180 : 0,
                   maxWidth: searchIsActive ? 260 : 0,
                   alignment: .leading)
            .opacity(searchIsActive ? 1 : 0)
            .allowsHitTesting(searchIsActive)
            .accessibilityHidden(!searchIsActive)
            .accessibilityLabel("Search clips")

            if searchIsActive {
                Button { AppController.shared.clearBarSearch() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(Theme.chromeTextFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, searchIsActive ? 10 : 0)
        .frame(height: 30)
        .background(searchIsActive ? Theme.fieldBG : Color.clear, in: Capsule())
        // Once a query exists, it must win space from the horizontally
        // scrollable tab strip so the user can see what they typed.
        .layoutPriority(searchIsActive ? 2 : 0)
        .animation(.easeOut(duration: 0.15), value: searchIsActive)
    }

    private var moreMenu: some View {
        Menu {
            Button { AppController.shared.showSettings() } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            Button { AppController.shared.togglePestyPause() } label: {
                Label(monitor.isPaused ? "Resume Pesty-Alvie" : "Pause Pesty-Alvie",
                      systemImage: monitor.isPaused ? "play.fill" : "pause.fill")
            }
            Button { store.clearHistory() } label: {
                Label("Clear History", systemImage: "trash")
            }
            Divider()
            Button { AppController.shared.showAbout() } label: {
                Label("About Pesty-Alvie", systemImage: "info.circle")
            }
            Button { NSApp.terminate(nil) } label: {
                Label("Quit Pesty-Alvie", systemImage: "power")
            }
        } label: {
            Image(systemName: monitor.isPaused ? "pause.fill" : "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.chromeTextMuted)
                .frame(width: 30, height: 30)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 34)
        .fixedSize()
    }

    private var strip: some View {
        GeometryReader { geometry in
            // A horizontal ScrollView measures card content at its intrinsic
            // height. Rich link previews would otherwise make their card
            // taller than every other card and shift the strip vertically.
            let cardHeight = max(1, geometry.size.height
                - Theme.cardStripTopInset - Theme.cardStripBottomInset)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Theme.cardStripLayoutSpacing) {
                        // This is a real scroll target, rather than an ID applied
                        // to the HStack. Scrolling it to the leading edge leaves
                        // a consistent edge inset before the first card.
                        Color.clear
                            .frame(width: Theme.cardStripStartTargetWidth,
                                   height: 1)
                            .id(Self.stripStartID)

                        if showsStackDeck {
                            ForEach(sequence.savedStacks.filter(\.hasEntries)) { stack in
                                PasteStackDeckCard(stack: stack,
                                                   isActive: stack.id == sequence.activeStackID,
                                                   isCollecting: stack.id == sequence.activeStackID && sequence.isCollecting)
                                    .frame(height: cardHeight)
                                    .padding(.horizontal, Theme.cardScrollTargetPadding)
                                    .id(stack.id)
                            }
                        }

                        ForEach(Array(store.visibleItems.enumerated()), id: \.element.id) { index, item in
                            ClipCardView(item: item,
                                         index: index,
                                         selected: item.id == store.selectedID)
                                .frame(height: cardHeight)
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: ClipCardFramePreferenceKey.self,
                                            value: [item.id: proxy.frame(in: .named("PestyBar"))])
                                    }
                                }
                                .padding(.horizontal, Theme.cardScrollTargetPadding)
                                .id(item.id)
                        }
                    }
                    .padding(.trailing, Theme.cardStripEndContentInset)
                    .padding(.top, Theme.cardStripTopInset)
                    .padding(.bottom, Theme.cardStripBottomInset)
                }
                .contentMargins(.horizontal, Theme.cardStripViewportInset, for: .scrollContent)
                .scrollClipDisabled()
                .onChange(of: store.selectedID) { _, id in
                    guard let id else { return }
                    if store.initialScrollTargetID == id {
                        store.initialScrollTargetID = nil
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            // The leading spacer preserves room for the first
                            // card's focus ring when reopening Pesty.
                            proxy.scrollTo(Self.stripStartID, anchor: .leading)
                        }
                        return
                    }
                    scrollToSelected(id, proxy: proxy)
                }
                .onChange(of: settings.selectedClipPosition) { _, _ in
                    guard let id = store.selectedID else { return }
                    scrollToSelected(id, proxy: proxy)
                }
                .overlay {
                    if store.visibleItems.isEmpty && !showsStackDeck { emptyState }
                }
                .overlay {
                    if let stripInsertionX {
                        // Same height as the cards, centered on their span.
                        InsertionCaret(color: Theme.selection, height: cardHeight)
                            .position(x: stripInsertionX,
                                      y: Theme.cardStripTopInset + cardHeight / 2)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.08), value: stripInsertionX != nil)
                .onDrop(of: [.pestyClipID], delegate: ClipStripDropDelegate(
                    canReorder: isPinboardSource,
                    onHover: { x in
                        let snapped = x.flatMap { snappedStripInsertionX(forX: $0) }
                        if (snapped == nil) != (stripInsertionX == nil) {
                            clipDragLog.debug("strip caret \(snapped == nil ? "cleared" : "shown", privacy: .public)")
                        }
                        stripInsertionX = snapped
                    },
                    onDrop: { id, x in
                        stripInsertionX = nil
                        guard case .pinboard(let boardID) = store.source else { return }
                        store.movePinboardItem(id,
                                               before: stripInsertionTargetID(forX: x),
                                               inBoard: boardID)
                        AppController.shared.restoreFocusAfterInBarDrop()
                    }
                ))
                .onReceive(NotificationCenter.default.publisher(for: .pestyDragSessionEnded)) { _ in
                    clipDragLog.debug("drag ended: clearing strip caret")
                    stripInsertionX = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        stripInsertionX = nil
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var isPinboardSource: Bool {
        if case .pinboard = store.source { return true }
        return false
    }

    /// Keyboard selection must land visibly in the same event turn; the
    /// anchor preference decides whether the strip parks the selected card
    /// centered or against the right edge, Paste-style.
    private func scrollToSelected(_ id: UUID, proxy: ScrollViewProxy) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
            proxy.scrollTo(id, anchor: settings.selectedClipPosition == .rightEdge ? .trailing : .center)
        }
    }

    /// The visible cards left-to-right with their live frames. Both the
    /// drop's x-position and these frames are measured in the bar's own
    /// coordinate space, so they compare directly.
    private var orderedStripFrames: [(id: UUID, frame: CGRect)] {
        store.visibleItems.compactMap { item in
            cardFrames[item.id].map { (item.id, $0) }
        }
    }

    /// The card a dragged clip would land in front of — nil appends at the end.
    private func stripInsertionTargetID(forX x: CGFloat) -> UUID? {
        orderedStripFrames.first(where: { x < $0.frame.midX })?.id
    }

    /// The caret's x-position: the middle of the gap the drop resolves to,
    /// so the line snaps cleanly between two cards.
    private func snappedStripInsertionX(forX x: CGFloat) -> CGFloat? {
        let frames = orderedStripFrames
        guard !frames.isEmpty else { return nil }
        guard let index = frames.firstIndex(where: { x < $0.frame.midX }) else {
            return frames[frames.count - 1].frame.maxX + 8
        }
        if index == 0 { return frames[0].frame.minX - 8 }
        return (frames[index - 1].frame.maxX + frames[index].frame.minX) / 2
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: store.searchText.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.chromeTextFaint)
            Text(store.searchText.isEmpty
                 ? "Nothing copied yet"
                 : "No matches for “\(store.searchText)”")
                .font(.system(size: 13))
                .foregroundStyle(Theme.chromeTextMuted)
        }
    }
}

/// Reorders clips within a Pinboard: tracks the drag's x-position to drive
/// the insertion caret and commits the move on release. Inert everywhere
/// else — history and search results keep their recency order.
private struct ClipStripDropDelegate: DropDelegate {
    let canReorder: Bool
    let onHover: (CGFloat?) -> Void
    let onDrop: (UUID, CGFloat) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        clipDragLog.debug("strip validateDrop: canReorder=\(canReorder)")
        return canReorder
    }

    func dropEntered(info: DropInfo) {
        onHover(info.location.x)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // An Escape-cancelled drag forgets the dragged clip; stop painting
        // the caret and refuse the drop.
        guard AppController.shared.draggedClipID != nil else {
            onHover(nil)
            return DropProposal(operation: .cancel)
        }
        onHover(info.location.x)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        onHover(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        onHover(nil)
        clipDragLog.debug("strip performDrop at x=\(info.location.x)")
        guard canReorder,
              let id = AppController.shared.draggedClipID else { return false }
        onDrop(id, info.location.x)
        return true
    }
}

private struct ClipCardFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct RoundedCorners: Shape {
    var radius: CGFloat
    var corners: RectCorner

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let tl = corners.contains(.topLeft) ? radius : 0
        let tr = corners.contains(.topRight) ? radius : 0
        let bl = corners.contains(.bottomLeft) ? radius : 0
        let br = corners.contains(.bottomRight) ? radius : 0
        p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        p.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

struct RectCorner: OptionSet {
    let rawValue: Int
    static let topLeft = RectCorner(rawValue: 1 << 0)
    static let topRight = RectCorner(rawValue: 1 << 1)
    static let bottomLeft = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)
}
