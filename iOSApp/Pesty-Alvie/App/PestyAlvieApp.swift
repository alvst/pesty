import SwiftUI

@main
@MainActor
struct PestyAlvieApp: App {
    @State private var libraryStore = LibraryStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(libraryStore)
                .task { libraryStore.start() }
        }
    }
}
