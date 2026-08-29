import SwiftUI
import UniformTypeIdentifiers

struct CompanionSettingsView: View {
    @Environment(LibraryStore.self) private var store
    @State private var isImportingStore = false
    @State private var isShowingClearConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section("Sync") {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: store.syncStatus.symbol)
                            .foregroundStyle(store.syncStatus.isReady ? .indigo : .secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.syncStatus.title)
                                .font(.body.weight(.semibold))
                            Text(store.syncStatus.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Check iCloud Again") {
                        Task { await store.refreshSyncStatus() }
                    }
                }

                Section("Bring over your Mac library") {
                    Button {
                        isImportingStore = true
                    } label: {
                        Label("Import Pesty-Alvie store.json", systemImage: "square.and.arrow.down")
                    }
                    Text("Choose store.json in iCloud Drive/Pesty-Alvie for a one-time import. Ongoing changes sync through your private iCloud database.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Privacy") {
                    Label("Pesty-Alvie only copies a clip after you tap Copy.", systemImage: "hand.tap")
                    Label("It never reads your clipboard in the background.", systemImage: "lock")
                }

                Section("On this iPhone or iPad") {
                    LabeledContent("Clips", value: "\(store.clips.count)")
                    LabeledContent("Pinboards", value: "\(store.boards.count)")
                    Button("Clear local library", role: .destructive) {
                        isShowingClearConfirmation = true
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pesty-Alvie Companion")
                            .font(.subheadline.weight(.semibold))
                        Text("A private, portable library for the things you copy.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .fileImporter(
                isPresented: $isImportingStore,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false,
                onCompletion: importStore
            )
            .confirmationDialog(
                "Clear local Pesty-Alvie library?",
                isPresented: $isShowingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear Library", role: .destructive) { store.clearLocalLibrary() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears the local cache without deleting iCloud records. Synced items may download again while sync is enabled.")
            }
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
