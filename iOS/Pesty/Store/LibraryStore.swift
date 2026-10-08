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
    private let sharedLibraryLoader: () throws -> PestyLibrary
    private let librarySaver: (PestyLibrary) throws -> Void
    private let usesDefaultLibrarySaver: Bool
    private let deferredWriter = DeferredLibraryWriter()
    private let sharedInboxLoader: () throws -> [LocalLibraryPersistence.SharedInboxItem]
    private let sharedInboxAcknowledger: ([LocalLibraryPersistence.SharedInboxItem]) throws -> Void
    /// False for a demo launch: the seeded library lives only in memory and
    /// never overwrites the real one on disk.
    private let persistsToDisk: Bool
    @ObservationIgnored private var hasPendingSave = false
    @ObservationIgnored private var localLibraryAvailable = true
    @ObservationIgnored private var syncStarted = false
    @ObservationIgnored private var needsReplicaRebuild = false
    @ObservationIgnored private var lastSaveErrorMessage: String?
    @ObservationIgnored private var undoExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var widgetReloadTask: Task<Void, Never>?
    @ObservationIgnored private var assetCleanupTask: Task<Void, Never>?
    @ObservationIgnored private var deferredSaveTask: Task<Void, Never>?
    @ObservationIgnored private var saveRevision: UInt64 = 0

    init(
        library: PestyLibrary? = nil,
        syncService: (any LibrarySyncing)? = nil,
        currentDate: @escaping () -> Date = { .now },
        persistsToDisk: Bool = true,
        sharedLibraryLoader: @escaping () throws -> PestyLibrary = {
            try LocalLibraryPersistence.loadThrowing()
        },
        librarySaver: ((PestyLibrary) throws -> Void)? = nil,
        sharedInboxLoader: @escaping () throws -> [LocalLibraryPersistence.SharedInboxItem] = {
            try LocalLibraryPersistence.loadSharedInbox()
        },
        sharedInboxAcknowledger: @escaping ([LocalLibraryPersistence.SharedInboxItem]) throws -> Void = {
            try LocalLibraryPersistence.acknowledgeSharedInbox($0)
        }
    ) {
        var initialLibrary = library ?? PestyLibrary()
        var initialLoadError: String?
        if library == nil {
            do { initialLibrary = try sharedLibraryLoader() }
            catch { initialLoadError = Self.libraryLoadError(error) }
        }
        let now = currentDate()
        self.library = initialLibrary
        self.syncService = syncService ?? CloudSyncService()
        self.currentDate = currentDate
        self.sharedLibraryLoader = sharedLibraryLoader
        self.librarySaver = librarySaver ?? { try LocalLibraryPersistence.save($0) }
        self.usesDefaultLibrarySaver = librarySaver == nil
        self.sharedInboxLoader = sharedInboxLoader
        self.sharedInboxAcknowledger = sharedInboxAcknowledger
        self.persistsToDisk = persistsToDisk
        self.localLibraryAvailable = initialLoadError == nil
        self.errorMessage = initialLoadError
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
        deferredSaveTask?.cancel()
    }

    var clips: [PestyClip] { library.activeClips }
    var boards: [PestyBoard] { library.activeBoards }

    func start() {
        reloadSharedLibrary()
        refreshUndoAvailability()
        guard canSyncLocalLibrary else {
            syncStatus = .failed(errorMessage ?? "The local library is unavailable.")
            return
        }
        if persistsToDisk { LocalLibraryPersistence.ensureWidgetSnapshot(for: library) }
        if !syncStarted {
            syncService.start(target: self)
            syncStarted = true
        }
    }

    func reloadSharedLibrary() {
        guard persistsToDisk else { return }
        let sharedLibrary: PestyLibrary
        do {
            sharedLibrary = try sharedLibraryLoader()
        } catch {
            localLibraryAvailable = false
            let message = Self.libraryLoadError(error)
            errorMessage = message
            syncStatus = .failed(message)
            return
        }
        let recovered = !localLibraryAvailable
        localLibraryAvailable = true
        if recovered {
            if errorMessage?.hasPrefix("Pesty could not read the local library") == true {
                errorMessage = nil
            }
        }
        let inboxItems: [LocalLibraryPersistence.SharedInboxItem]
        do {
            inboxItems = try sharedInboxLoader()
        } catch {
            // Keep the files for a later activation. A partial import could
            // hide a damaged entry and let asset cleanup delete its image.
            inboxItems = []
            errorMessage = "Pesty could not read shared items. \(error.localizedDescription)"
        }
        if hasPendingSave || recovered
                || sharedLibrary.updatedAt > library.updatedAt
                || sharedLibrary.clips.count != library.clips.count
                || sharedLibrary.boards.count != library.boards.count
                || !inboxItems.isEmpty {
            library = library.merged(with: sharedLibrary)
            if !inboxItems.isEmpty {
                let inboxClips = inboxItems.map(\.clip)
                let inboxLibrary = PestyLibrary(
                    clips: inboxClips,
                    updatedAt: inboxClips.map(\.updatedAt).max() ?? .distantPast
                )
                library = library.merged(with: inboxLibrary)
            }
            let saved = persist(notifySync: !recovered, allowReplicaRebuild: !recovered)
            if saved && !inboxItems.isEmpty {
                do {
                    try sharedInboxAcknowledger(inboxItems)
                } catch {
                    errorMessage = "Pesty saved shared items but could not clear its inbox. \(error.localizedDescription)"
                }
            }
            refreshUndoAvailability()
        }
        if recovered {
            guard !hasPendingSave else {
                syncStatus = .failed(errorMessage ?? "The local library could not be saved.")
                return
            }
            if syncStarted {
                syncService.rebuildLocalReplica()
                needsReplicaRebuild = false
            } else {
                syncService.start(target: self)
                syncStarted = true
                needsReplicaRebuild = false
            }
        }
    }

    func refreshSyncStatus() async {
        reloadSharedLibrary()
        await flushPendingSave()
        guard canSyncLocalLibrary else { return }
        syncService.fetchNow()
    }

    @discardableResult
    func refreshOnOpen(addingClipboard: Bool = false) -> Bool {
        // Read the now-accessible library before importing a new clipboard
        // item, including after a background launch before the first unlock.
        reloadSharedLibrary()
        if hasPendingSave { persist() }
        let imported = addingClipboard && addClipboardOnOpenIfNeeded()
        // Foreground sync starts immediately below. Persist a clipboard import
        // before exposing the library to its outgoing record projection.
        if hasPendingSave { persist() }
        if canSyncLocalLibrary {
            if !syncStarted {
                syncService.start(target: self)
                syncStarted = true
                needsReplicaRebuild = false
            } else {
                syncService.refreshOnActivate()
            }
        }
        return imported
    }

    func clip(id: UUID) -> PestyClip? { library.clip(id: id) }
    func board(id: UUID) -> PestyBoard? { library.board(id: id) }
    func clips(in board: PestyBoard) -> [PestyClip] { library.clips(in: board) }

    func addClip(
        kind: ClipKind,
        text: String,
        title: String? = nil,
        colorHex: String? = nil,
        imageData: Data? = nil
    ) {
        let now = Date.now
        let image: (name: String, hash: String)?
        if let imageData {
            do {
                image = try LocalAssetPersistence.storeImageData(imageData)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        } else {
            image = nil
        }
        let clip = PestyClip(
            kind: kind,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text,
            imageAssetID: image?.name,
            imageHash: image?.hash,
            colorHex: colorHex?.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceDeviceName: UIDevice.current.name,
            customTitle: title?.trimmingCharacters(in: .whitespacesAndNewlines),
            capturedAt: now,
            updatedAt: now
        )
        library.upsert(clip)
        persist(debounced: true)
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
        var candidate: PestyClip
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
        case .textAndImage(let data, let text, let kind, let richText):
            imageData = data
            candidate = PestyClip(
                kind: kind,
                text: text,
                richTextData: richText,
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
            do {
                let stored = try LocalAssetPersistence.storeImageData(imageData)
                candidate.imageAssetID = stored.name
                candidate.imageHash = stored.hash
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        library.upsert(candidate)
        persist(debounced: true)
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
            persist(debounced: true)
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
        persist(debounced: true)
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
        persist(debounced: true)
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
        persist(debounced: true)
    }

    func deleteBoard(id: UUID) {
        library.deleteBoard(id: id, at: currentDate())
        persist()
        refreshUndoAvailability()
        scheduleAssetCleanup()
    }

    func add(_ clip: PestyClip, to board: PestyBoard) {
        _ = library.add(clipID: clip.id, to: board.id)
        persist(debounced: true)
    }

    func contains(_ clip: PestyClip, in board: PestyBoard) -> Bool {
        library.containsEquivalent(clip, in: board)
    }

    func remove(_ clip: PestyClip, from board: PestyBoard) {
        library.remove(clipID: clip.id, from: board.id, at: currentDate())
        persist(debounced: true)
        refreshUndoAvailability()
    }

    func toggle(_ clip: PestyClip, in board: PestyBoard) {
        if let ownedCopy = library.clips(in: board).first(where: { $0.hasSameContent(as: clip) }) {
            library.remove(clipID: ownedCopy.id, from: board.id, at: currentDate())
        } else {
            _ = library.add(clipID: clip.id, to: board.id, at: currentDate())
        }
        persist(debounced: true)
        refreshUndoAvailability()
    }

    func importMacStore(data: Data, imageDirectory: URL? = nil) {
        do {
            let imported = try MacPestyStoreImporter.library(from: data, imageDirectory: imageDirectory)
            library = library.merged(with: imported)
            persist()
            refreshUndoAvailability()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importMacStore(from selectedURL: URL) throws {
        let imported = try MacPestyStoreImporter.library(from: selectedURL)
        library = library.merged(with: imported)
        persist()
        refreshUndoAvailability()
    }

    func clearLocalLibrary() {
        saveRevision &+= 1
        deferredSaveTask?.cancel()
        deferredSaveTask = nil
        do {
            try LocalLibraryPersistence.removeAll()
            library = PestyLibrary()
            localLibraryAvailable = true
            lastCopiedClipID = nil
            hasPendingSave = false
            needsReplicaRebuild = false
            refreshUndoAvailability()
            scheduleWidgetReload()
            do { try LocalAssetPersistence.removeAll() }
            catch { errorMessage = error.localizedDescription }
            syncService.rebuildLocalReplica()
            syncStarted = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func persist(notifySync: Bool = true, allowReplicaRebuild: Bool = true,
                         debounced: Bool = false) -> Bool {
        guard persistsToDisk else { return false }
        hasPendingSave = true
        saveRevision &+= 1
        deferredSaveTask?.cancel()
        deferredSaveTask = nil
        if debounced && usesDefaultLibrarySaver {
            let revision = saveRevision
            deferredSaveTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.commitDeferredSave(revision: revision)
            }
            return false
        }
        do {
            try librarySaver(library)
            didSave(notifySync: notifySync, allowReplicaRebuild: allowReplicaRebuild)
            return true
        } catch {
            didFailToSave(error)
            return false
        }
    }

    private func commitDeferredSave(revision: UInt64) async {
        guard revision == saveRevision, hasPendingSave else { return }
        let snapshot = library
        do {
            try await deferredWriter.save(snapshot)
            guard revision == saveRevision else { return }
            deferredSaveTask = nil
            didSave(notifySync: true, allowReplicaRebuild: true)
        } catch is CancellationError {
            return
        } catch {
            guard revision == saveRevision else { return }
            deferredSaveTask = nil
            didFailToSave(error)
        }
    }

    /// Called by the app as it enters the background. The save still runs off
    /// the main actor, but an iOS background task lets it finish before the
    /// process is suspended.
    func flushPendingSaveForBackground() {
        guard persistsToDisk, hasPendingSave else { return }
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save Pesty Library")
        Task { @MainActor [weak self] in
            await self?.flushPendingSave()
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
    }

    func flushPendingSave() async {
        guard persistsToDisk, hasPendingSave else { return }
        while hasPendingSave {
            let previous = deferredSaveTask
            previous?.cancel()
            if let previous { await previous.value }
            guard hasPendingSave else { return }
            saveRevision &+= 1
            let revision = saveRevision
            await commitDeferredSave(revision: revision)
            if revision == saveRevision { return }
        }
    }

    private func didSave(notifySync: Bool, allowReplicaRebuild: Bool) {
        hasPendingSave = false
        // A later successful retry resolves only the save error; unrelated
        // errors still need to be shown to the user.
        if let lastSaveErrorMessage, errorMessage == lastSaveErrorMessage {
            errorMessage = nil
        }
        lastSaveErrorMessage = nil
        scheduleWidgetReload()
        if needsReplicaRebuild && syncStarted && allowReplicaRebuild {
            needsReplicaRebuild = false
            syncService.rebuildLocalReplica()
        } else if notifySync && localLibraryAvailable {
            syncService.localLibraryDidChange()
        }
    }

    private func didFailToSave(_ error: Error) {
        let message = "Pesty could not save this change. \(error.localizedDescription)"
        lastSaveErrorMessage = message
        errorMessage = message
        needsReplicaRebuild = true
        syncStatus = .failed(message)
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
        let redactedOldTombstones = library.redactFinalizedDeletions()
        if hadExpiredRecords || redactedOldTombstones {
            persist()
            scheduleAssetCleanup()
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
        assetCleanupTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            // The share extension may have queued a new image while this app
            // was suspended. Include its pending inbox references.
            guard let onDisk = try? LocalLibraryPersistence.loadThrowing(),
                  let inbox = try? LocalLibraryPersistence.loadSharedInbox() else { return }
            var referenced = snapshot.merged(with: onDisk)
            // Retain every inbox image even when its clip ID already exists in
            // the saved library at a newer timestamp.
            referenced.clips.append(contentsOf: inbox.map(\.clip))
            LocalAssetPersistence.removeUnreferencedAssets(in: referenced)
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

/// Serializes ordinary full-library saves away from the main actor. The
/// synchronous save path remains for remote changes, shared inbox adoption,
/// and explicit deletion/reset operations.
private actor DeferredLibraryWriter {
    func save(_ library: PestyLibrary) throws {
        try LocalLibraryPersistence.saveDeferred(library)
    }
}

extension LibraryStore: LibrarySyncTarget {
    var cloudSyncLibrary: PestyLibrary { library }
    var canSyncLocalLibrary: Bool { localLibraryAvailable && !hasPendingSave }

    func updateSyncStatus(_ status: SyncStatus) {
        guard canSyncLocalLibrary, syncStatus != status else { return }
        syncStatus = status
        #if DEBUG
        exportSyncDiagnosticsIfRequested()
        #endif
    }

    #if DEBUG
    /// Local verification metadata only; never exports clip bodies or assets.
    func exportSyncDiagnosticsIfRequested() {
        guard CommandLine.arguments.contains("--sync-diagnostics") else { return }
        struct Diagnostics: Encodable {
            var status: String
            var detail: String
            var historyCount: Int
            var boardCount: Int
            var clipIDs: [UUID]
            var newestClipID: UUID?
            var newestCapturedAt: Date?
            var recordedAt: Date
        }
        let newest = clips.max { $0.capturedAt < $1.capturedAt }
        let report = Diagnostics(status: syncStatus.title, detail: syncStatus.detail,
                                 historyCount: clips.count, boardCount: boards.count,
                                 clipIDs: clips.map(\.id),
                                 newestClipID: newest?.id, newestCapturedAt: newest?.capturedAt,
                                 recordedAt: currentDate())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? encoder.encode(report).write(to: directory.appendingPathComponent("sync-diagnostics.json"),
                                          options: LocalFileProtection.writingOptions)
    }
    #endif

    func applyRemoteSync(
        clips decodedClips: [CloudRecordCodec.DecodedClip],
        boards remoteBoards: [PestyBoard],
        deletedIDs: [UUID]
    ) {
        guard canSyncLocalLibrary else { return }
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
                // A clip may arrive before its board. Only a placeholder
                // needs synthesized membership; a real board's record owns
                // its order and membership across fetch batches.
                if existingBoards[boardID] == nil && boardsByID[boardID] == nil {
                    boardsByID[boardID] = PestyBoard(
                        id: boardID, name: "Pinboard", clipIDs: [clip.id],
                        createdAt: .distantPast, updatedAt: .distantPast
                    )
                } else if var placeholder = boardsByID[boardID],
                          placeholder.createdAt == .distantPast,
                          !placeholder.clipIDs.contains(clip.id) {
                    placeholder.clipIDs.append(clip.id)
                    boardsByID[boardID] = placeholder
                }
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

private extension LibraryStore {
    static func libraryLoadError(_ error: Error) -> String {
        "Pesty could not read the local library. Sync is paused to protect your iCloud data. \(error.localizedDescription)"
    }
}
