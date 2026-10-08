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
                .task {
                    libraryStore.start()
                    #if DEBUG
                    libraryStore.exportSyncDiagnosticsIfRequested()
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // Restore the local library, import the clipboard, and
                        // then start the foreground fetch-and-send.
                        if libraryStore.refreshOnOpen(addingClipboard: true) {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        }
                    case .background:
                        libraryStore.flushPendingSaveForBackground()
                    case .inactive:
                        Task { await libraryStore.flushPendingSave() }
                    @unknown default:
                        break
                    }
                }
        }
    }
}
