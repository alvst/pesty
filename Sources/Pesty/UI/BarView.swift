import SwiftUI

struct BarView: View {
    /// Keeps a substantial portion of a phrase visible while searching without
    /// forcing the pinboard tabs out of a narrow bar.
    private static let preferredSearchWidth: CGFloat = 700
    private static let collapsedSearchWidth: CGFloat = 22
    private static let minimumNonSearchChromeWidth: CGFloat = 230
    private static let stripTopInset: CGFloat = 4
    private static let stripBottomInset: CGFloat = 18

    @Bindable private var store = ClipboardStore.shared
    @Bindable private var settings = Settings.shared
    @State private var resizeStartHeight: Double?
    @State private var cardFrames: [UUID: CGRect] = [:]
    private var sequence: PasteSequence { AppController.shared.pasteSequence }

    private var showsStackDeck: Bool {
        store.source == .history && store.searchText.isEmpty && sequence.hasSavedStacks
    }

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow)
            Theme.panelTint
            VStack(spacing: 0) {
                if settings.showBarResizeHandle { resizeHandle }
                topBar
                if store.source == .pasteStack {
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
        .clipShape(RoundedCorners(radius: Theme.cornerRadius, corners: [.topLeft, .topRight]))
        .ignoresSafeArea()
    }

    private var resizeHandle: some View {
        HStack {
            Capsule(style: .continuous)
                .fill(Theme.textTertiary.opacity(0.7))
                .frame(width: 42, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 14)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if resizeStartHeight == nil { resizeStartHeight = settings.barHeight }
                    guard let start = resizeStartHeight else { return }
                    settings.barHeight = min(720, max(300, start - value.translation.height))
                }
                .onEnded { _ in resizeStartHeight = nil }
        )
        .help("Drag to resize the Pesty bar")
    }

    private var topBar: some View {
        GeometryReader { geometry in
            HStack(spacing: 14) {
                if settings.iCloudSync {
                    syncButton
                }
                if store.source != .pasteStack {
                    searchIndicator(width: searchWidth(in: geometry.size.width))
                }
                PinboardTabs()
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if store.source != .pasteStack, store.selectedIDs.count > 1 {
                    bulkDeleteButton
                }
                if settings.clipPreviewStyle == .inlinePesty, store.source != .pasteStack {
                    previewButton
                }
                pasteStackButton
                moreMenu
            }
            .padding(.horizontal, 18)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: 56)
    }

    private var previewButton: some View {
        Button { AppController.shared.toggleInlinePreview() } label: {
            Image(systemName: store.inlinePreviewVisible ? "rectangle.on.rectangle" : "rectangle.on.rectangle.angled")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(store.inlinePreviewVisible ? Theme.selection : Theme.textSecondary)
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

    private func searchWidth(in barWidth: CGFloat) -> CGFloat {
        guard !store.searchText.isEmpty else { return Self.collapsedSearchWidth }
        let available = barWidth - (2 * 18) - Self.minimumNonSearchChromeWidth
        return min(Self.preferredSearchWidth, max(Self.collapsedSearchWidth, available))
    }

    private var syncButton: some View {
        Button {
            AppController.shared.toggleICloudSync()
        } label: {
            Image(systemName: settings.iCloudSync ? "checkmark.icloud.fill" : "arrow.triangle.2.circlepath")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(settings.iCloudSync ? Theme.selection : Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .help(settings.iCloudSync ? "iCloud sync on" : "Turn on iCloud sync")
    }

    private func searchIndicator(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(store.searchText.isEmpty ? Theme.textSecondary : Theme.textPrimary)
            if !store.searchText.isEmpty {
                Text(store.searchText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    // Match a native search field's behavior: once a query is
                    // longer than the field, keep the newest typed text visible.
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { store.searchText = ""; store.selectFirst() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, store.searchText.isEmpty ? 0 : 10)
        .frame(width: width, height: 30, alignment: .leading)
        .background(store.searchText.isEmpty ? Color.clear : Theme.fieldBG, in: Capsule())
        .clipped()
        .layoutPriority(store.searchText.isEmpty ? 0 : 2)
        .animation(.spring(response: 0.30, dampingFraction: 0.84), value: store.searchText.isEmpty)
        .accessibilityLabel(store.searchText.isEmpty ? "Search clipboard history" : "Clipboard history search")
    }

    private var moreMenu: some View {
        Menu {
            Button("Settings…") { AppController.shared.showSettings() }
            Button("Clear History") { store.clearHistory() }
            Divider()
            Button("About Pesty") { AppController.shared.showAbout() }
            Button("Quit Pesty") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 30, height: 30)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 34)
        .fixedSize()
    }

    private var bulkDeleteButton: some View {
        let count = store.selectedIDs.count
        return Button(role: .destructive) {
            store.deleteSelected()
        } label: {
            Label("Delete \(count)", systemImage: "trash")
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Delete \(count) selected clips (⌘⌫)")
        .accessibilityLabel("Delete \(count) selected clips")
    }

    private var pasteStackButton: some View {
        Button {
            AppController.shared.newPasteStack()
        } label: {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help("Start Paste Stack")
    }

    private var strip: some View {
        GeometryReader { geometry in
            let cardHeight = max(1, geometry.size.height - Self.stripTopInset - Self.stripBottomInset)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Theme.cardSpacing) {
                        if showsStackDeck {
                            ForEach(sequence.savedStacks.filter(\.hasEntries)) { stack in
                                PasteStackDeckCard(
                                    stack: stack,
                                    isActive: stack.id == sequence.activeStackID,
                                    isCollecting: stack.id == sequence.activeStackID && sequence.isCollecting
                                )
                                .frame(height: cardHeight)
                                .id(stack.id)
                            }
                        }

                        ForEach(Array(store.visibleItems.enumerated()), id: \.element.id) { index, item in
                            ClipCardView(item: item,
                                         index: index,
                                         selected: store.selectedIDs.contains(item.id))
                                .frame(height: cardHeight)
                                .id(item.id)
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: ClipCardFramePreferenceKey.self,
                                            value: [item.id: proxy.frame(in: .named("PestyBar"))]
                                        )
                                    }
                                }
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.92).combined(with: .opacity),
                                    removal: .opacity))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, Self.stripTopInset)
                    .padding(.bottom, Self.stripBottomInset)
                    .animation(.spring(response: 0.34, dampingFraction: 0.8), value: store.visibleItems.count)
                }
                .onChange(of: store.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                        if settings.selectedClipPosition == .rightEdge {
                            proxy.scrollTo(id, anchor: .trailing)
                        } else {
                            // Do not re-center a card that is already visible.
                            // This keeps arrow-key navigation visually stable
                            // while still revealing the next off-screen card.
                            proxy.scrollTo(id)
                        }
                    }
                }
                .onChange(of: settings.selectedClipPosition) { _, _ in
                    guard let id = store.selectedID else { return }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                        proxy.scrollTo(id, anchor: selectedClipAnchor)
                    }
                }
                .overlay {
                    if store.visibleItems.isEmpty && !showsStackDeck { emptyState }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var selectedClipAnchor: UnitPoint {
        settings.selectedClipPosition == .rightEdge ? .trailing : .center
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: store.searchText.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(store.searchText.isEmpty
                 ? "Nothing copied yet"
                 : "No matches for “\(store.searchText)”")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
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
