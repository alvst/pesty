import SwiftUI

struct RootTabView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Library", systemImage: "square.stack.3d.up") }

            BoardsView()
                .tabItem { Label("Pinboards", systemImage: "rectangle.3.group") }

            CompanionSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.indigo)
        .alert(
            "Pesty-Alvie couldn’t complete that action",
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
}
