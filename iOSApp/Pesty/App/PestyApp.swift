import SwiftUI
import UIKit

@main
@MainActor
struct PestyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var libraryStore = DemoLibrary.isRequested ? LibraryStore.demo() : LibraryStore()

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
                    // Restore the local library, import the clipboard, and
                    // then start the foreground fetch-and-send.
                    if libraryStore.refreshOnOpen(addingClipboard: true) {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                }
        }
    }
}
