import Foundation
import Observation
import UIKit
import WidgetKit

@MainActor
@Observable
final class LibraryStore {
    private(set) var library: PestyLibrary
    private(set) var syncStatus: SyncStatus = .checking
    private(set) var lastCopiedClipID: UUID?
    private(set) var undoableDeletion: PendingLibraryDeletion?
    var undoableDeletedClip: PestyClip? {
        if case .clip(let clip)? = undoableDeletion { return clip }
        return nil
    }
    var errorMessage: String?
    /// Imports whatever is on the clipboard each time the app comes to the
    /// foreground. Opening the companion usually means "move this to my Mac",
    /// so the default is on; Settings can turn it off.
    var addsClipboardOnOpen: Bool {
        didSet { UserDefaults.standard.set(addsClipboardOnOpen, forKey: Self.addsClipboardOnOpenKey) }
    }
    private static let addsClipboardOnOpenKey = "addsClipboardOnOpen"
    private static let lastImportedChangeCountKey = "lastAutoImportedPasteboardChangeCount"

    private let syncService: any LibrarySyncing
    private let currentDate: () -> Date
    private let sharedLibraryLoader: () -> PestyLibrary
    private let librarySaver: (PestyLibrary) throws -> Void
    /// False for a demo launch: the seeded library lives only in memory and
    /// never overwrites the real one on disk.
    private let persistsToDisk: Bool
    @ObservationIgnored private var hasPendingSave = false
    @ObservationIgnored private var lastSaveErrorMessage: String?
    @ObservationIgnored private var undoExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var widgetReloadTask: Task<Void, Never>?
    @ObservationIgnored private var assetCleanupTask: Task<Void, Never>?

    init(
        library: PestyLibrary? = nil,
        syncService: (any LibrarySyncing)? = nil,
        currentDate: @escaping () -> Date = { .now },
        persistsToDisk: Bool = true,
        sharedLibraryLoader: @escaping () -> PestyLibrary = {
            LocalLibraryPersistence.load()
        },
        librarySaver: @escaping (PestyLibrary) throws -> Void = {
            try LocalLibraryPersistence.save($0)
        }
    ) {
        let initialLibrary = library ?? sharedLibraryLoader()
        let now = currentDate()
        self.library = initialLibrary
        self.syncService = syncService ?? CloudSyncService()
        self.currentDate = currentDate
        self.sharedLibraryLoader = sharedLibraryLoader
        self.librarySaver = librarySaver
        self.persistsToDisk = persistsToDisk
        self.undoableDeletion = initialLibrary.undoableDeletion(at: now)
        self.addsClipboardOnOpen = UserDefaults.standard.object(forKey: Self.addsClipboardOnOpenKey) as? Bool ?? true
    }

    /// The `--demo` store: fixed content, no disk writes, no iCloud.
    static func demo() -> LibraryStore {
        LibraryStore(library: DemoLibrary.make(), syncService: NoCloudSyncService(), persistsToDisk: false)
    }

    deinit {
        undoExpiryTask?.cancel()
        widgetReloadTask?.cancel()
        assetCleanupTask?.cancel()
    }

    var clips: [PestyClip] { library.activeClips }
    var boards: [PestyBoard] { library.activeBoards }

    func start() {
        reloadSharedLibrary()
        refreshUndoAvailability()
        syncService.start(target: self)
    }

    func reloadSharedLibrary() {
        guard persistsToDisk else { return }
        let sharedLibrary = sharedLibraryLoader()
        guard hasPendingSave
                || sharedLibrary.updatedAt > library.updatedAt
                || sharedLibrary.clips.count != library.clips.count
                || sharedLibrary.boards.count != library.boards.count else { return }
        library = library.merged(with: sharedLibrary)
        persist()
        refreshUndoAvailability()
    }

    func refreshSyncStatus() async {
        syncService.fetchNow()
    }

    @discardableResult
    func refreshOnOpen(addingClipboard: Bool = false) -> Bool {
        // Read the now-accessible library before importing a new clipboard
        // item, including after a background launch before the first unlock.
        reloadSharedLibrary()
        if hasPendingSave { persist() }
        let imported = addingClipboard && addClipboardOnOpenIfNeeded()
        syncService.refreshOnActivate()
        return imported
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

    /// Imports the value currently on this iPhone's clipboard into History.
    /// Called from the toolbar button and, when enabled, on every foreground
    /// activation; the companion never polls the pasteboard in the background.
    @discardableResult
    func addCurrentClipboard(from pasteboard: UIPasteboard = .general) -> Bool {
        do {
            return try importClipboard(from: pasteboard, skippingDuplicates: false)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// The foreground import. It is skipped when the setting is off, when the
    /// pasteboard has not changed since the last automatic import, when it
    /// holds nothing importable, or when an identical clip is already in the
    /// library (for example one that just synced from the Mac and landed on
    /// this phone through Universal Clipboard). Returns true only when a new
    /// clip was added.
    @discardableResult
    func addClipboardOnOpenIfNeeded(from pasteboard: UIPasteboard = .general) -> Bool {
        guard addsClipboardOnOpen, persistsToDisk else { return false }
        let changeCount = pasteboard.changeCount
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: Self.lastImportedChangeCountKey) as? Int, last == changeCount {
            return false
        }
        guard ClipboardReader.hasImportableContent(on: pasteboard) else { return false }
        defaults.set(changeCount, forKey: Self.lastImportedChangeCountKey)
        do {
            return try importClipboard(from: pasteboard, skippingDuplicates: true)
        } catch ClipboardReader.ReadError.empty {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func importClipboard(from pasteboard: UIPasteboard, skippingDuplicates: Bool) throws -> Bool {
        let now = Date.now
        let candidate: PestyClip
        var imageData: Data?
        switch try ClipboardReader.read(from: pasteboard) {
        case .image(let data):
            imageData = data
            candidate = PestyClip(
                kind: .image,
                imageHash: LocalAssetPersistence.hash(of: data),
                sourceDeviceName: UIDevice.current.name,
                capturedAt: now,
                updatedAt: now
            )
        case .richText(let data, let plainText):
            candidate = PestyClip(
                kind: .richText,
                text: plainText,
                richTextData: data,
                sourceDeviceName: UIDevice.current.name,
                capturedAt: now,
                updatedAt: now
            )
        case .text(let text, let kind):
            candidate = PestyClip(
                kind: kind,
                text: text,
                sourceDeviceName: UIDevice.current.name,
                capturedAt: now,
                updatedAt: now
            )
        }

        if skippingDuplicates,
           library.clips.contains(where: { !$0.isDeleted && $0.hasSameContent(as: candidate) }) {
            return false
        }

        if let imageData {
            return addImageClip(data: imageData)
        }
        library.upsert(candidate)
        persist()
        return true
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

    func undoDeletion() {
        guard library.undoMostRecentDeletion(at: currentDate()) else {
            refreshUndoAvailability()
            return
        }
        persist()
        refreshUndoAvailability()
    }

    func undoClipDeletion() { undoDeletion() }

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
        library.remove(clipID: clip.id, from: board.id, at: currentDate())
        persist()
        refreshUndoAvailability()
    }

    func toggle(_ clip: PestyClip, in board: PestyBoard) {
        if let ownedCopy = library.clips(in: board).first(where: { $0.hasSameContent(as: clip) }) {
            library.remove(clipID: ownedCopy.id, from: board.id, at: currentDate())
        } else {
            _ = library.add(clipID: clip.id, to: board.id, at: currentDate())
        }
        persist()
        refreshUndoAvailability()
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
        guard persistsToDisk else { return }
        hasPendingSave = true
        do {
            try librarySaver(library)
            hasPendingSave = false
            // A later successful retry resolves only the save error; unrelated
            // errors still need to be shown to the user.
            if let lastSaveErrorMessage, errorMessage == lastSaveErrorMessage {
                errorMessage = nil
            }
            lastSaveErrorMessage = nil
            scheduleWidgetReload()
            if notifySync { syncService.localLibraryDidChange() }
        } catch {
            let message = "Pesty could not save this change. \(error.localizedDescription)"
            lastSaveErrorMessage = message
            errorMessage = message
        }
    }

    private func refreshUndoAvailability() {
        let now = currentDate()
        let hadExpiredRecords = library.clips.contains {
            $0.deletedAt.map { $0.addingTimeInterval(PestyLibrary.deletionUndoInterval) <= now }
                == true && $0.deletionFinalizedAt == nil
        } || library.boards.contains {
            $0.deletedAt.map { $0.addingTimeInterval(PestyLibrary.deletionUndoInterval) <= now }
                == true && $0.deletionFinalizedAt == nil
        }
        library.finalizeExpiredDeletions(at: now)
        undoableDeletion = library.undoableDeletion(at: now)
        if hadExpiredRecords {
            persist()
            LocalAssetPersistence.removeUnreferencedAssets(in: library, at: now)
        }
        scheduleUndoExpiry(after: now)
    }

    /// A sync can arrive in several CloudKit batches. Coalescing their widget
    /// invalidations avoids repeatedly rebuilding timelines while the main
    /// library view is also laying out newly inserted cards.
    private func scheduleWidgetReload() {
        widgetReloadTask?.cancel()
        widgetReloadTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadAllTimelines()
            self?.widgetReloadTask = nil
        }
    }

    private func scheduleAssetCleanup() {
        assetCleanupTask?.cancel()
        let snapshot = library
        let date = currentDate()
        assetCleanupTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            LocalAssetPersistence.removeUnreferencedAssets(in: snapshot, at: date)
        }
    }

    private func scheduleUndoExpiry(after date: Date) {
        undoExpiryTask?.cancel()
        undoExpiryTask = nil

        let expirations = [
            undoableDeletion?.deletedAt?.addingTimeInterval(PestyLibrary.deletionUndoInterval)
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
        guard !decodedClips.isEmpty || !remoteBoards.isEmpty || !deletedIDs.isEmpty else { return }

        let existingClips = Dictionary(uniqueKeysWithValues: library.clips.map { ($0.id, $0) })
        let existingBoards = Dictionary(uniqueKeysWithValues: library.boards.map { ($0.id, $0) })
        var boardsByID = Dictionary(uniqueKeysWithValues: remoteBoards.map { ($0.id, $0) })
        var remoteClips: [PestyClip] = []
        remoteClips.reserveCapacity(decodedClips.count)

        for decoded in decodedClips {
            var clip = decoded.clip
            let existing = existingClips[clip.id]
            if let existing,
               existing.updatedAt > clip.updatedAt {
                continue
            }
            if let assetURL = decoded.imageAssetURL {
                if let existing,
                   let remoteHash = clip.imageHash,
                   existing.imageHash == remoteHash,
                   LocalAssetPersistence.url(for: existing.imageAssetID) != nil {
                    // Metadata-only updates do not need to read, hash, and
                    // rewrite an identical image on the main actor.
                    clip.imageAssetID = existing.imageAssetID
                } else {
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
            }
            remoteClips.append(clip)
            if let boardID = clip.containerID {
                var board = boardsByID[boardID]
                    ?? existingBoards[boardID]
                    ?? PestyBoard(id: boardID, name: "Pinboard")
                if !board.clipIDs.contains(clip.id) { board.clipIDs.append(clip.id) }
                board.updatedAt = max(board.updatedAt, clip.updatedAt)
                boardsByID[boardID] = board
            }
        }

        let remote = PestyLibrary(clips: remoteClips, boards: Array(boardsByID.values))
        library = library.merged(with: remote)
        library.applyRemoteDeletions(ids: deletedIDs, at: currentDate())
        persist(notifySync: false)
        refreshUndoAvailability()
        scheduleAssetCleanup()
    }
}
