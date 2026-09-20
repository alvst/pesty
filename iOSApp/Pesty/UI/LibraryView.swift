import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var pendingRoute: LibraryRoute?
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var navigationPath: [UUID] = []
    @State private var selectedKind: ClipKind?
    @State private var isPresentingNewClip = false
    @State private var isImportingStore = false

    private func visibleClips(in clips: [PestyClip]) -> [PestyClip] {
        let query = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !query.isEmpty || selectedKind != nil else { return clips }
        return clips.filter { clip in
            let matchesSearch = query.isEmpty || clip.searchableText.contains(query)
            let matchesKind = selectedKind == nil || selectedKind == clip.kind
            return matchesSearch && matchesKind
        }
    }

    private var gridColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: 12, alignment: .top)]
        }
        return [GridItem(.adaptive(minimum: 164, maximum: 300), spacing: 12, alignment: .top)]
    }

    var body: some View {
        // Materialize the sorted library once per render. Referencing the old
        // computed property from each grid branch repeated the same full sort
        // and filter several times during a refresh.
        let allClips = store.clips
        let allBoards = store.boards
        let visibleClips = visibleClips(in: allClips)
        let allClipIDs = allClips.map(\.id)

        NavigationStack(path: $navigationPath) {
            Group {
                if allClips.isEmpty {
                    EmptyLibraryView(
                        addClipboard: addCurrentClipboard,
                        addClip: { isPresentingNewClip = true },
                        importStore: { isImportingStore = true }
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: gridColumns, alignment: .center, spacing: 12) {
                            if visibleClips.isEmpty {
                                ContentUnavailableView.search(text: searchText)
                                    .padding(.top, 72)
                            } else {
                                ForEach(visibleClips) { clip in
                                    NavigationLink(value: clip.id) {
                                        ClipCard(
                                            clip: clip,
                                            isRecentlyCopied: store.lastCopiedClipID == clip.id
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button {
                                            copy(clip)
                                        } label: {
                                            Label("Copy", systemImage: "doc.on.doc")
                                        }
                                        if FormatConverter.canConvert(clip) {
                                            ForEach([CopyFormat.plainText, .cleanFormatting, .markdown]) { format in
                                                Button(format.title, systemImage: format.symbol) {
                                                    copy(clip, format: format)
                                                }
                                            }
                                        }
                                        if !allBoards.isEmpty {
                                            Menu("Pinboards", systemImage: "pin") {
                                                ForEach(allBoards) { board in
                                                    Button {
                                                        store.toggle(clip, in: board)
                                                    } label: {
                                                        Label(
                                                            board.name,
                                                            systemImage: store.contains(clip, in: board)
                                                                ? "checkmark"
                                                                : "plus"
                                                        )
                                                    }
                                                }
                                            }
                                        }
                                        Divider()
                                        Button("Delete", systemImage: "trash", role: .destructive) {
                                            store.deleteClip(id: clip.id)
                                        }
                                    }
                                    .transition(.asymmetric(
                                        insertion: .scale(scale: 0.94, anchor: .top)
                                            .combined(with: .opacity),
                                        removal: .opacity
                                    ))
                                }
                            }
                        }
                        .padding(12)
                        // Animate library insertions/removals, but not every
                        // keystroke or filter change in the visible subset.
                        .animation(
                            .spring(response: 0.38, dampingFraction: 0.82),
                            value: allClipIDs
                        )
                    }
                    .background(Color(uiColor: .systemGroupedBackground))
                }
            }
            .navigationTitle("Pesty")
            .searchable(
                text: $searchText,
                isPresented: $isSearchPresented,
                prompt: "Search your library"
            )
            .navigationDestination(for: UUID.self) { clipID in
                ClipDetailView(clipID: clipID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("All clips") { selectedKind = nil }
                        Divider()
                        ForEach(ClipKind.allCases) { kind in
                            Button {
                                selectedKind = kind
                            } label: {
                                Label(kind.title, systemImage: kind.symbol)
                            }
                        }
                    } label: {
                        // Filled while a filter is active, so it reads as
                        // "on" at a glance instead of changing shape.
                        Image(systemName: selectedKind == nil
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Filter clips")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if store.undoableDeletion != nil {
                        Button("Undo", systemImage: "arrow.uturn.backward") {
                            store.undoDeletion()
                        }
                        .accessibilityLabel("Undo deletion")
                    }
                    Button {
                        Task { await store.refreshSyncStatus() }
                    } label: {
                        if store.syncStatus == .checking || store.syncStatus == .syncing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: store.syncStatus.isReady
                                  ? "arrow.clockwise"
                                  : store.syncStatus.symbol)
                        }
                    }
                    .disabled(store.syncStatus == .checking || store.syncStatus == .syncing)
                    .accessibilityLabel("\(store.syncStatus.title). Refresh iCloud")
                    Button(action: addCurrentClipboard) {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .accessibilityLabel("Add current clipboard")
                    .accessibilityHint("Adds the current iPhone clipboard to your library")
                    Button {
                        isPresentingNewClip = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add clip")
                }
            }
            .sheet(isPresented: $isPresentingNewClip) {
                NewClipSheet()
            }
            .fileImporter(
                isPresented: $isImportingStore,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                importStore(result)
            }
            .onChange(of: pendingRoute, initial: true) { _, route in
                guard let route else { return }
                switch route {
                case .clip(let id): navigationPath = [id]
                case .search:
                    searchText = ""
                    isSearchPresented = true
                case .newClip: isPresentingNewClip = true
                }
                pendingRoute = nil
            }
        }
    }

    private func copy(_ clip: PestyClip, format: CopyFormat = .original) {
        do {
            try ClipboardWriter.copy(clip, format: format)
            store.markCopied(clip)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func addCurrentClipboard() {
        guard store.addCurrentClipboard() else { return }
        searchText = ""
        selectedKind = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func importStore(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            store.importMacStore(data: try Data(contentsOf: url))
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }
}

private struct EmptyLibraryView: View {
    let addClipboard: () -> Void
    let addClip: () -> Void
    let importStore: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Your Pesty library is empty", systemImage: "doc.on.clipboard")
        } description: {
#if targetEnvironment(simulator)
            Text("Add a clip here or import an existing Pesty store.")
#else
            Text("Add a clip here, import an existing Pesty store, or let iCloud sync it from your Mac.")
#endif
        } actions: {
            VStack(spacing: 10) {
                Button("Add current clipboard", systemImage: "doc.on.clipboard", action: addClipboard)
                    .buttonStyle(.borderedProminent)
                Button("Add a clip", action: addClip)
                    .buttonStyle(.bordered)
                Button("Import Pesty store.json", action: importStore)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
    }
}

struct ClipCard: View {
    let clip: PestyClip
    let isRecentlyCopied: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.kind.title.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PestyPalette.headerText)
                    Text(clip.capturedAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(PestyPalette.headerSubtext)
                }
                Spacer(minLength: 2)
                if isRecentlyCopied {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white)
                        .accessibilityLabel("Copied")
                } else {
                    sourceBadge
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .background(PestyPalette.sourceColor(for: clip))

            RichClipPreview(clip: clip)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(PestyPalette.cardBody)

            if let source = clip.sourceAppName ?? clip.sourceDeviceName {
                HStack(spacing: 5) {
                    Image(systemName: clip.sourceAppName == nil ? "iphone" : "app.fill")
                    Text(source).lineLimit(1)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(PestyPalette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(PestyPalette.cardBody)
                .overlay(alignment: .top) { Divider().opacity(0.6) }
            }
        }
        .background(PestyPalette.cardBody)
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .strokeBorder(PestyPalette.cardBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.13), radius: 5, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var sourceBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.18))
            if let initial = clip.sourceAppName?.first {
                Text(String(initial).uppercased())
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: clip.kind.symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 30, height: 30)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.18))
        }
    }
}
