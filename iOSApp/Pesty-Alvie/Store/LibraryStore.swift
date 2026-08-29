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
    var errorMessage: String?

    private let syncService: any LibrarySyncing
    private let currentDate: () -> Date
    @ObservationIgnored private var undoExpiryTask: Task<Void, Never>?

    init(
        library: PestyLibrary? = nil,
        syncService: (any LibrarySyncing)? = nil,
        currentDate: @escaping () -> Date = { .now }
    ) {
        let initialLibrary = library ?? LocalLibraryPersistence.load()
        let now = currentDate()
        self.library = initialLibrary
        self.syncService = syncService ?? CloudSyncService()
        self.currentDate = currentDate
        self.undoableDeletedClip = initialLibrary.undoableDeletedClip(at: now)
    }

    deinit {
        undoExpiryTask?.cancel()
    }

    var clips: [PestyClip] { library.activeClips }
    var boards: [PestyBoard] { library.activeBoards }

    func start() {
        refreshUndoAvailability()
        syncService.start(target: self)
    }

    func refreshSyncStatus() async {
        syncService.fetchNow()
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

    @discardableResult
    func addImageClip(data: Data, title: String? = nil) -> Bool {
        do {
            let stored = try LocalAssetPersistence.storeImageData(data)
            let now = Date.now
            library.upsert(PestyClip(
                kind: .image,
                imageAssetID: stored.name,
                imageHash: stored.hash,
                sourceDeviceName: UIDevice.current.name,
                customTitle: title?.trimmingCharacters(in: .whitespacesAndNewlines),
                capturedAt: now,
                updatedAt: now
            ))
            persist()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
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
        let nextSortIndex = (library.activeBoards.map(\.sortIndex).max() ?? -1) + 1
        library.upsert(PestyBoard(
            name: trimmed,
            colorHex: colorHex,
            sortIndex: nextSortIndex
        ))
        persist()
    }

    func deleteBoard(id: UUID) {
        library.deleteBoard(id: id, at: currentDate())
        persist()
        refreshUndoAvailability()
        LocalAssetPersistence.removeUnreferencedAssets(in: library, at: currentDate())
    }

    func add(_ clip: PestyClip, to board: PestyBoard) {
        _ = library.add(clipID: clip.id, to: board.id)
        persist()
    }

    func contains(_ clip: PestyClip, in board: PestyBoard) -> Bool {
        library.containsEquivalent(clip, in: board)
    }

    func remove(_ clip: PestyClip, from board: PestyBoard) {
        library.remove(clipID: clip.id, from: board.id)
        persist()
        LocalAssetPersistence.removeUnreferencedAssets(in: library, at: currentDate())
    }

    func toggle(_ clip: PestyClip, in board: PestyBoard) {
        if let ownedCopy = library.clips(in: board).first(where: { $0.hasSameContent(as: clip) }) {
            library.remove(clipID: ownedCopy.id, from: board.id)
        } else {
            _ = library.add(clipID: clip.id, to: board.id)
        }
        persist()
        LocalAssetPersistence.removeUnreferencedAssets(in: library, at: currentDate())
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
            try LocalAssetPersistence.removeAll()
            syncService.rebuildLocalReplica()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persist(notifySync: Bool = true) {
        do {
            try LocalLibraryPersistence.save(library)
            if notifySync { syncService.localLibraryDidChange() }
        } catch {
            errorMessage = "Pesty-Alvie could not save this change. \(error.localizedDescription)"
        }
    }

    private func refreshUndoAvailability() {
        let now = currentDate()
        let hadExpiredRecords = library.clips.contains {
            $0.deletedAt.map { $0.addingTimeInterval(PestyLibrary.deletionUndoInterval) <= now }
                == true && $0.deletionFinalizedAt == nil
        }
        library.finalizeExpiredDeletions(at: now)
        undoableDeletedClip = library.undoableDeletedClip(at: now)
        if hadExpiredRecords {
            persist()
            LocalAssetPersistence.removeUnreferencedAssets(in: library, at: now)
        }
        scheduleUndoExpiry(after: now)
    }

    private func scheduleUndoExpiry(after date: Date) {
        undoExpiryTask?.cancel()
        undoExpiryTask = nil

        let expirations = [
            undoableDeletedClip?.deletedAt?.addingTimeInterval(PestyLibrary.deletionUndoInterval)
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

extension LibraryStore: LibrarySyncTarget {
    var cloudSyncLibrary: PestyLibrary { library }

    func updateSyncStatus(_ status: SyncStatus) {
        syncStatus = status
    }

    func applyRemoteSync(
        clips decodedClips: [CloudRecordCodec.DecodedClip],
        boards remoteBoards: [PestyBoard],
        deletedIDs: [UUID]
    ) {
        var remote = PestyLibrary()
        for board in remoteBoards { remote.upsert(board) }

        for decoded in decodedClips {
            var clip = decoded.clip
            if let existing = library.clips.first(where: { $0.id == clip.id }),
               existing.updatedAt > clip.updatedAt {
                continue
            }
            if let assetURL = decoded.imageAssetURL {
                do {
                    let stored = try LocalAssetPersistence.replaceAsset(
                        from: assetURL,
                        preferredName: "\(clip.id.uuidString).image"
                    )
                    clip.imageAssetID = stored.name
                    clip.imageHash = clip.imageHash ?? stored.hash
                } catch {
                    errorMessage = "An image could not be saved from iCloud. \(error.localizedDescription)"
                    clip.imageAssetID = nil
                }
            }
            remote.upsert(clip)
            if let boardID = clip.containerID {
                var board = remote.board(id: boardID)
                    ?? library.board(id: boardID)
                    ?? PestyBoard(id: boardID, name: "Pinboard")
                if !board.clipIDs.contains(clip.id) { board.clipIDs.append(clip.id) }
                board.updatedAt = max(board.updatedAt, clip.updatedAt)
                remote.upsert(board)
            }
        }

        library = library.merged(with: remote)
        for id in deletedIDs { library.applyRemoteDeletion(id: id, at: currentDate()) }
        persist(notifySync: false)
        refreshUndoAvailability()
        LocalAssetPersistence.removeUnreferencedAssets(in: library, at: currentDate())
    }
}
