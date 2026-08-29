import SwiftUI
import UIKit

@main
@MainActor
struct PestyAlvieApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var libraryStore = LibraryStore()

    init() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(libraryStore)
                .task { libraryStore.start() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await libraryStore.refreshSyncStatus() }
                }
        }
    }
}
