import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(LibraryStore.self) private var store
    @State private var searchText = ""
    @State private var selectedKind: ClipKind?
    @State private var isPresentingNewClip = false
    @State private var isImportingStore = false

    private var visibleClips: [PestyClip] {
        store.clips.filter { clip in
            let matchesSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || clip.searchableText.contains(searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            let matchesKind = selectedKind == nil || selectedKind == clip.kind
            return matchesSearch && matchesKind
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.clips.isEmpty {
                    EmptyLibraryView(
                        addClip: { isPresentingNewClip = true },
                        importStore: { isImportingStore = true }
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            SyncStatusBanner(status: store.syncStatus) {
                                Task { await store.refreshSyncStatus() }
                            }
                            .padding(.horizontal)

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
                                        if !store.boards.isEmpty {
                                            Menu("Add to Pinboard") {
                                                ForEach(store.boards) { board in
                                                    Button(board.name) { store.add(clip, to: board) }
                                                }
                                            }
                                        }
                                        Divider()
                                        Button("Delete", systemImage: "trash", role: .destructive) {
                                            store.deleteClip(id: clip.id)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .background(Color(uiColor: .systemGroupedBackground))
                }
            }
            .navigationTitle("Pesty-Alvie")
            .searchable(text: $searchText, prompt: "Search your library")
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
                        Image(systemName: selectedKind?.symbol ?? "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Filter clips")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if store.undoableDeletedClip != nil {
                        Button("Undo", systemImage: "arrow.uturn.backward") {
                            store.undoClipDeletion()
                        }
                        .accessibilityLabel("Undo clip deletion")
                    }
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
        }
    }

    private func copy(_ clip: PestyClip) {
        do {
            try ClipboardWriter.copy(clip)
            store.markCopied(clip)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch {
            store.errorMessage = error.localizedDescription
        }
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
    let addClip: () -> Void
    let importStore: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Your Pesty-Alvie library is empty", systemImage: "doc.on.clipboard")
        } description: {
            Text("Add a clip here, or import your existing Pesty-Alvie store from iCloud Drive. Live Mac sync will arrive when the Mac app adopts the shared sync service.")
        } actions: {
            VStack(spacing: 10) {
                Button("Add a clip", action: addClip)
                    .buttonStyle(.borderedProminent)
                Button("Import Pesty-Alvie store.json", action: importStore)
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
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(clip.kind.tint)
                .frame(width: 7)
                .padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: clip.kind.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(clip.kind.tint)
                        .frame(width: 20)
                    Text(clip.kind.title.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if isRecentlyCopied {
                        Label("Copied", systemImage: "checkmark")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    } else {
                        Text(clip.capturedAt, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if clip.kind == .color, let color = Color(hex: clip.colorHex ?? "") {
                    HStack(spacing: 10) {
                        Circle().fill(color).frame(width: 28, height: 28)
                        Text(clip.displayTitle)
                            .font(.headline)
                    }
                } else {
                    Text(clip.displayTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let preview = clip.previewText,
                       preview != clip.displayTitle {
                        Text(preview)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                if let source = clip.sourceAppName ?? clip.sourceDeviceName {
                    Label(source, systemImage: "laptopcomputer.and.iphone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .padding(.horizontal)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct SyncStatusBanner: View {
    let status: SyncStatus
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if status == .checking {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: status.symbol)
                    .foregroundStyle(status == .readyForMacBridge ? .indigo : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.subheadline.weight(.semibold))
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if status != .checking {
                Button("Check", action: retry)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}
