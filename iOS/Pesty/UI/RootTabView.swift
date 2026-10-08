import SwiftUI

enum LibraryRoute: Equatable {
    case clip(UUID)
    case search
    case newClip
}

struct RootTabView: View {
    @Environment(LibraryStore.self) private var store
    @State private var selectedTab = 0
    @State private var pendingLibraryRoute: LibraryRoute?

    var body: some View {
        TabView(selection: $selectedTab) {
            LibraryView(pendingRoute: $pendingLibraryRoute)
                .tabItem { Label("Library", systemImage: "square.stack.3d.up") }
                .tag(0)

            BoardsView()
                .tabItem { Label("Pinboards", systemImage: "rectangle.3.group") }
                .tag(1)

            CompanionSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(2)
        }
        .tint(PestyPalette.selection)
        .onOpenURL(perform: open)
        .alert(
            "Pesty couldn’t complete that action",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private func open(_ url: URL) {
        guard url.scheme == "pesty" else { return }
        selectedTab = 0
        switch url.host {
        case "clip":
            if let value = url.pathComponents.dropFirst().first,
               let id = UUID(uuidString: value) {
                pendingLibraryRoute = .clip(id)
            }
        case "new": pendingLibraryRoute = .newClip
        case "search": pendingLibraryRoute = .search
        default: pendingLibraryRoute = nil
        }
    }
}
