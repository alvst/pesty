import SwiftUI

struct BarView: View {
    private static let stripStartID = "pesty.clip-strip.start"
    private static let stripTopInset: CGFloat = 16
    private static let stripBottomInset: CGFloat = 26

    @Bindable private var store = ClipboardStore.shared
    @Bindable private var settings = Settings.shared
    private var monitor: ClipboardMonitor { AppController.shared.monitor }
    private var sequence: PasteSequence { AppController.shared.pasteSequence }
    private var showsStackDeck: Bool {
        store.source == .history && store.searchText.isEmpty && sequence.hasSavedStacks
    }
    @State private var resizeStartHeight: Double?
    @State private var cardFrames: [UUID: CGRect] = [:]

    var body: some View {
        ZStack {
            panelBackground
            VStack(spacing: 0) {
                if settings.showBarResizeHandle { resizeHandle }
                topBar
                if store.source == .pasteStack {
                    PasteStackContentView()
                } else {
                    if settings.clipPreviewStyle == .inlinePesty,
                       store.inlinePreviewVisible {
                        Spacer(minLength: 0)
                        strip.frame(height: 280)
                    } else {
                        strip
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if settings.clipPreviewStyle == .inlinePesty,
               store.source != .pasteStack,
               store.inlinePreviewVisible,
               let item = store.selectedItem {
                PestyPreviewPopover(
                    item: item,
                    pointer: cardFrames[item.id].map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero)
            }
        }
        .coordinateSpace(name: "PestyBar")
        .onPreferenceChange(ClipCardFramePreferenceKey.self) { cardFrames = $0 }
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
            if store.source != .pasteStack { searchIndicator }
            PinboardTabs()
                .layoutPriority(1)
            Spacer(minLength: 8)
            if store.source != .pasteStack {
                if settings.clipPreviewStyle == .inlinePesty { previewButton }
                startPasteStackButton
            }
            moreMenu
        }
        .padding(.horizontal, 18)
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

    private var searchIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(store.searchText.isEmpty ? Theme.textSecondary : Theme.textPrimary)
            if !store.searchText.isEmpty {
                Text(store.searchText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Button { store.searchText = ""; store.selectFirst() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, store.searchText.isEmpty ? 0 : 10)
        .frame(height: 30)
        .background(store.searchText.isEmpty ? Color.clear : Theme.fieldBG, in: Capsule())
        .animation(.easeOut(duration: 0.15), value: store.searchText.isEmpty)
    }

    private var moreMenu: some View {
        Menu {
            Button { AppController.shared.showSettings() } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            Button { AppController.shared.togglePestyPause() } label: {
                Label(monitor.isPaused ? "Resume Pesty" : "Pause Pesty",
                      systemImage: monitor.isPaused ? "play.fill" : "pause.fill")
            }
            Button { store.clearHistory() } label: {
                Label("Clear History", systemImage: "trash")
            }
            Divider()
            Button { AppController.shared.showAbout() } label: {
                Label("About Pesty", systemImage: "info.circle")
            }
            Button { NSApp.terminate(nil) } label: {
                Label("Quit Pesty", systemImage: "power")
            }
        } label: {
            Image(systemName: monitor.isPaused ? "pause.fill" : "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 30, height: 30)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 34)
        .fixedSize()
    }

    private var strip: some View {
        GeometryReader { geometry in
            // A horizontal ScrollView measures its content at intrinsic height.
            // Link cards now include a richer preview, so without an explicit
            // height those cards make the LazyHStack center shorter cards around
            // them. Size every card from the available strip height instead.
            let cardHeight = max(1, geometry.size.height - Self.stripTopInset - Self.stripBottomInset)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Theme.cardSpacing) {
                        // This is a real scroll target, rather than an ID applied
                        // to the HStack. Scrolling it to the leading edge leaves
                        // one card-spacing of room before the first card.
                        Color.clear
                            .frame(width: 1, height: 1)
                            .id(Self.stripStartID)

                        if showsStackDeck {
                            ForEach(sequence.savedStacks.filter(\.hasEntries)) { stack in
                                PasteStackDeckCard(stack: stack,
                                                   isActive: stack.id == sequence.activeStackID,
                                                   isCollecting: stack.id == sequence.activeStackID && sequence.isCollecting)
                                    .frame(height: cardHeight)
                                    .id(stack.id)
                            }
                        }

                        ForEach(Array(store.visibleItems.enumerated()), id: \.element.id) { index, item in
                            ClipCardView(item: item,
                                         index: index,
                                         selected: item.id == store.selectedID)
                                .frame(height: cardHeight)
                                .id(item.id)
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: ClipCardFramePreferenceKey.self,
                                            value: [item.id: proxy.frame(in: .named("PestyBar"))])
                                    }
                                }
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.92).combined(with: .opacity),
                                    removal: .opacity))
                        }
                    }
                    .padding(.trailing, 28)
                    .padding(.top, Self.stripTopInset)
                    .padding(.bottom, Self.stripBottomInset)
                    .animation(.spring(response: 0.34, dampingFraction: 0.8), value: store.visibleItems.count)
                }
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
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .overlay {
                    if store.visibleItems.isEmpty && !showsStackDeck { emptyState }
                }
            }
        }
        .frame(maxHeight: .infinity)
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
