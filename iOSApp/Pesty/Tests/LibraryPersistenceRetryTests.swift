import Foundation
import XCTest
@testable import Pesty

@MainActor
final class LibraryPersistenceRetryTests: XCTestCase {
    func testRetryMergesOlderDiskClipsEvenWhenTheCountsMatch() {
        let retained = PestyClip(kind: .text, text: "Already on disk", capturedAt: .distantPast,
                                 updatedAt: .distantPast)
        let pending = PestyClip(kind: .text, text: "Pending change")
        let diskLibrary = PestyLibrary(clips: [retained], updatedAt: .distantPast)
        var attempts = 0
        var saved: PestyLibrary?
        let store = LibraryStore(library: PestyLibrary(clips: [pending]),
                                 syncService: NoCloudSyncService(),
                                 sharedLibraryLoader: { diskLibrary }, librarySaver: { library in
            attempts += 1
            if attempts == 1 { throw CocoaError(.fileWriteNoPermission) }
            saved = library
        })
        store.update(pending)

        store.refreshOnOpen()

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(Set(store.clips.map(\.id)), [retained.id, pending.id])
        XCTAssertEqual(Set(saved?.clips.map(\.id) ?? []), [retained.id, pending.id])
        XCTAssertNil(store.errorMessage)
    }

    func testForegroundRetriesAnUnsavedEditEvenWhenTheDiskLibraryHasTheSameCount() throws {
        let original = PestyClip(kind: .text, text: "Before", capturedAt: .distantPast,
                                 updatedAt: .distantPast)
        let diskLibrary = PestyLibrary(clips: [original])
        var attempts = 0
        var saved: PestyLibrary?
        let store = LibraryStore(library: diskLibrary, syncService: NoCloudSyncService(),
                                 sharedLibraryLoader: { diskLibrary }, librarySaver: { library in
            attempts += 1
            if attempts == 1 {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            }
            saved = library
        })
        var edited = original
        edited.text = "After"

        store.update(edited)

        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(saved)
        store.refreshOnOpen()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(saved?.clip(id: original.id)?.text, "After")
        XCTAssertNil(store.errorMessage)
        store.refreshOnOpen()
        XCTAssertEqual(attempts, 2, "A successful retry must not keep saving on each activation.")
    }

    func testSuccessfulRetryPreservesAnUnrelatedError() {
        let original = PestyClip(kind: .text, text: "Before", capturedAt: .distantPast,
                                 updatedAt: .distantPast)
        let diskLibrary = PestyLibrary(clips: [original])
        var attempts = 0
        let store = LibraryStore(library: diskLibrary, syncService: NoCloudSyncService(),
                                 sharedLibraryLoader: { diskLibrary }, librarySaver: { _ in
            attempts += 1
            if attempts == 1 {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            }
        })
        var edited = original
        edited.text = "After"
        store.update(edited)
        store.errorMessage = "A separate import failed."

        store.refreshOnOpen()

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(store.errorMessage, "A separate import failed.")
    }
}
