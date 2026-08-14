import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class LibraryStore {
    private(set) var library: PestyLibrary
    private(set) var syncStatus: SyncStatus = .checking
    private(set) var lastCopiedClipID: UUID?
    private(set) var undoableDeletedClip: PestyClip?
    private(set) var undoableDeletedBoard: PestyBoard?
    var errorMessage: String?

    private let syncChecker: any LibrarySyncing
    private let currentDate: () -> Date
    @ObservationIgnored private var undoExpiryTask: Task<Void, Never>?

    init(
        library: PestyLibrary? = nil,
        syncChecker: any LibrarySyncing = CloudKitReadinessChecker(),
        currentDate: @escaping () -> Date = { .now }
    ) {
        let initialLibrary = library ?? LocalLibraryPersistence.load()
        let now = currentDate()
        self.library = initialLibrary
        self.syncChecker = syncChecker
        self.currentDate = currentDate
        self.undoableDeletedClip = initialLibrary.undoableDeletedClip(at: now)
        self.undoableDeletedBoard = initialLibrary.undoableDeletedBoard(at: now)
    }

    deinit {
        undoExpiryTask?.cancel()
    }

    var clips: [PestyClip] { library.activeClips }
    var boards: [PestyBoard] { library.activeBoards }

    func start() {
        refreshUndoAvailability()
        Task { await refreshSyncStatus() }
    }

    func refreshSyncStatus() async {
        syncStatus = .checking
        syncStatus = await syncChecker.checkAvailability()
    }

    func clip(id: UUID) -> PestyClip? { library.clip(id: id) }
    func board(id: UUID) -> PestyBoard? { library.board(id: id) }
    func clips(in board: PestyBoard) -> [PestyClip] { library.clips(in: board) }

    func addClip(
        kind: ClipKind,
        text: String,
        title: String? = nil,
        colorHex: String? = nil
    ) {
        let now = Date.now
        let clip = PestyClip(
            kind: kind,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text,
            colorHex: colorHex?.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceDeviceName: UIDevice.current.name,
            customTitle: title?.trimmingCharacters(in: .whitespacesAndNewlines),
            capturedAt: now,
            updatedAt: now
        )
        library.upsert(clip)
        persist()
    }

    func update(_ clip: PestyClip) {
        var updated = clip
        updated.updatedAt = .now
        library.upsert(updated)
        persist()
    }

    func deleteClip(id: UUID) {
        library.deleteClip(id: id, at: currentDate())
        persist()
        refreshUndoAvailability()
    }

    func undoClipDeletion() {
        guard library.undoMostRecentClipDeletion(at: currentDate()) else {
            refreshUndoAvailability()
            return
        }
        persist()
        refreshUndoAvailability()
    }

    func markCopied(_ clip: PestyClip) {
        var updated = clip
        updated.markUsed()
        library.upsert(updated)
        lastCopiedClipID = clip.id
        persist()
    }

    func addBoard(name: String, colorHex: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        library.upsert(PestyBoard(name: trimmed, colorHex: colorHex))
        persist()
    }

    func deleteBoard(id: UUID) {
        library.deleteBoard(id: id, at: currentDate())
        persist()
        refreshUndoAvailability()
    }

    func undoBoardDeletion() {
        guard library.undoMostRecentBoardDeletion(at: currentDate()) else {
            refreshUndoAvailability()
            return
        }
        persist()
        refreshUndoAvailability()
    }

    func add(_ clip: PestyClip, to board: PestyBoard) {
        library.add(clipID: clip.id, to: board.id)
        persist()
    }

    func remove(_ clip: PestyClip, from board: PestyBoard) {
        library.remove(clipID: clip.id, from: board.id)
        persist()
    }

    func importMacStore(data: Data) {
        do {
            let imported = try MacPestyStoreImporter.library(from: data)
            library = library.merged(with: imported)
            persist()
            refreshUndoAvailability()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearLocalLibrary() {
        library = PestyLibrary()
        lastCopiedClipID = nil
        refreshUndoAvailability()
        do {
            try LocalLibraryPersistence.removeAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persist() {
        do {
            try LocalLibraryPersistence.save(library)
        } catch {
            errorMessage = "Pesty-Alvie could not save this change. \(error.localizedDescription)"
        }
    }

    private func refreshUndoAvailability() {
        let now = currentDate()
        undoableDeletedClip = library.undoableDeletedClip(at: now)
        undoableDeletedBoard = library.undoableDeletedBoard(at: now)
        scheduleUndoExpiry(after: now)
    }

    private func scheduleUndoExpiry(after date: Date) {
        undoExpiryTask?.cancel()
        undoExpiryTask = nil

        let expirations = [
            undoableDeletedClip?.deletedAt?.addingTimeInterval(PestyLibrary.deletionUndoInterval),
            undoableDeletedBoard?.deletedAt?.addingTimeInterval(PestyLibrary.deletionUndoInterval)
        ].compactMap { $0 }
        guard let expiration = expirations.min() else { return }

        // Wake periodically for an unexpectedly future-dated sync tombstone,
        // while normal local deletions sleep once until their five-minute edge.
        let delay = min(max(0, expiration.timeIntervalSince(date)), 24 * 60 * 60)
        let nanoseconds = UInt64(delay * 1_000_000_000)
        undoExpiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.refreshUndoAvailability()
        }
    }
}
