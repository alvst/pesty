import SwiftUI

struct BarView: View {
    /// Keeps a substantial portion of a phrase visible while searching without
    /// forcing the pinboard tabs out of a narrow bar.
    private static let preferredSearchWidth: CGFloat = 700
    private static let collapsedSearchWidth: CGFloat = 22
    private static let minimumNonSearchChromeWidth: CGFloat = 230

    @Bindable private var store = ClipboardStore.shared
    @Bindable private var settings = Settings.shared

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow)
            Theme.panelTint
        }
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                topBar
                strip
            }
        }
        .clipShape(RoundedCorners(radius: Theme.cornerRadius, corners: [.topLeft, .topRight]))
        .ignoresSafeArea()
    }

    private var topBar: some View {
        GeometryReader { geometry in
            HStack(spacing: 14) {
                syncButton
                searchIndicator(width: searchWidth(in: geometry.size.width))
                PinboardTabs()
                    .layoutPriority(1)
                Spacer(minLength: 8)
                moreMenu
            }
            .padding(.horizontal, 18)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: 56)
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

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Theme.cardSpacing) {
                    ForEach(Array(store.visibleItems.enumerated()), id: \.element.id) { index, item in
                        ClipCardView(item: item,
                                     index: index,
                                     selected: item.id == store.selectedID)
                            .id(item.id)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.92).combined(with: .opacity),
                                removal: .opacity))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 18)
                .animation(.spring(response: 0.34, dampingFraction: 0.8), value: store.visibleItems.count)
            }
            .onChange(of: store.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .overlay { if store.visibleItems.isEmpty { emptyState } }
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
