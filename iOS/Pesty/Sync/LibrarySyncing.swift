import CloudKit
import CryptoKit
import Foundation

enum SyncStatus: Equatable {
    case checking
    case syncing
    case ready
    case unavailable(String)
    case failed(String)

    var title: String {
        switch self {
        case .checking: "Checking iCloud"
        case .syncing: "Syncing"
        case .ready: "Synced with iCloud"
        case .unavailable: "iCloud unavailable"
        case .failed: "Sync needs attention"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            "Confirming your iCloud account and sync configuration."
        case .syncing:
            "Sending local changes and checking for updates from your other devices."
        case .ready:
            "Your Pesty library is up to date across signed-in devices."
        case .unavailable(let message), .failed(let message):
            message
        }
    }

    var symbol: String {
        switch self {
        case .checking, .syncing: "arrow.triangle.2.circlepath.icloud"
        case .ready: "checkmark.icloud.fill"
        case .unavailable: "icloud.slash"
        case .failed: "exclamationmark.icloud"
        }
    }

    var isReady: Bool { self == .ready }
}

@MainActor
protocol LibrarySyncTarget: AnyObject {
    var cloudSyncLibrary: PestyLibrary { get }
    var canSyncLocalLibrary: Bool { get }
    func applyRemoteSync(
        clips: [CloudRecordCodec.DecodedClip],
        boards: [PestyBoard],
        deletedIDs: [UUID]
    )
    func updateSyncStatus(_ status: SyncStatus)
}

@MainActor
protocol LibrarySyncing: AnyObject {
    func start(target: any LibrarySyncTarget)
    func localLibraryDidChange()
    func fetchNow()
    func refreshOnActivate()
    func rebuildLocalReplica()
}

/// A pending local deletion remains represented by its last active version
/// until Undo expires. This prevents the grace period itself from publishing
/// a newer live record to other devices.
enum CloudSyncProjection {
    static func clip(_ source: PestyClip) -> PestyClip {
        guard source.deletedAt != nil,
              source.deletionFinalizedAt == nil,
              let priorVersion = source.preDeletionUpdatedAt else { return source }
        var projected = source
        projected.updatedAt = priorVersion
        projected.deletedAt = nil
        projected.preDeletionUpdatedAt = nil
        return projected
    }

    static func board(_ source: PestyBoard) -> PestyBoard {
        guard source.deletedAt != nil,
              source.deletionFinalizedAt == nil,
              let priorVersion = source.preDeletionUpdatedAt else { return source }
        var projected = source
        projected.updatedAt = priorVersion
        projected.deletedAt = nil
        projected.preDeletionUpdatedAt = nil
        return projected
    }
}

/// Bidirectional private-database synchronization for the iOS companion.
/// CKSyncEngine persists its change token and pending work, so edits made
/// offline are retried automatically when the account becomes reachable.
@MainActor
final class CloudSyncService: LibrarySyncing {
    private static let immediateSyncStaleInterval: TimeInterval = 10

    private weak var target: (any LibrarySyncTarget)?
    private var engine: CKSyncEngine?
    private var shadow: [String: String] = [:]
    // Keep the projected value as the cache key. Its synthesized equality
    // checks every wire-relevant field, including text and RTF data, so a
    // same-timestamp edit can never reuse an obsolete fingerprint. The value
    // shares the library's copy-on-write payload buffers until it changes.
    private var clipFingerprintCache: [UUID: (source: PestyClip, fingerprint: String)] = [:]
    private var boardFingerprintCache: [UUID: (source: PestyBoard, fingerprint: String)] = [:]
    private var isApplyingRemote = false
    private var immediateSyncTask: Task<Void, Never>?
    private var immediateSyncStartedAt: Date?
    private var immediateSyncGeneration: UInt64 = 0
    /// A local change enqueued while a foreground fetch-and-send is already
    /// running would otherwise wait on the engine's opportunistic scheduler.
    private var needsSendAfterImmediateSync = false
    private var lastRecordFailure: String?
    private let currentDate: () -> Date
    private let immediateSyncOperation: (() async throws -> Void)?
    private let accountStatusProvider: () async throws -> CKAccountStatus

    init(
        currentDate: @escaping () -> Date = { .now },
        immediateSyncOperation: (() async throws -> Void)? = nil,
        accountStatusProvider: @escaping () async throws -> CKAccountStatus = {
            try await CKContainer(identifier: CKSchema.containerID).accountStatus()
        }
    ) {
        self.currentDate = currentDate
        self.immediateSyncOperation = immediateSyncOperation
        self.accountStatusProvider = accountStatusProvider
    }

    private var stateURL: URL {
        LocalLibraryPersistence.supportDirectory.appendingPathComponent("cksync-state.json")
    }

    private var shadowURL: URL {
        LocalLibraryPersistence.supportDirectory.appendingPathComponent("cksync-shadow.json")
    }

    private var systemFieldsDirectory: URL {
        LocalLibraryPersistence.supportDirectory
            .appendingPathComponent("ck-system-fields", isDirectory: true)
    }

    private var accountChangeMarkerURL: URL {
        LocalLibraryPersistence.supportDirectory.appendingPathComponent("cksync-account-changed")
    }

    private var zoneDeletionMarkerURL: URL {
        LocalLibraryPersistence.supportDirectory.appendingPathComponent("cksync-zone-deleted")
    }

    private var incompleteFetchMarkerURL: URL {
        LocalLibraryPersistence.supportDirectory.appendingPathComponent("cksync-incomplete-fetch")
    }

    func start(target: any LibrarySyncTarget) {
        self.target = target
        guard engine == nil else {
            fetchNow()
            return
        }

        if FileManager.default.fileExists(atPath: accountChangeMarkerURL.path) {
            target.updateSyncStatus(.unavailable(
                "The iCloud account changed. Clear the local library in Settings before downloading the new account, so two accounts are never merged automatically."
            ))
            return
        }
        if FileManager.default.fileExists(atPath: zoneDeletionMarkerURL.path) {
            target.updateSyncStatus(.unavailable(
                "Pesty's iCloud data was deleted. Sync is paused so this device does not upload it again. Clear the local library to start fresh."
            ))
            return
        }

        #if targetEnvironment(simulator)
        target.updateSyncStatus(.unavailable(
            "CloudKit sync requires a signed device build. The unsigned simulator build still supports local libraries and tests."
        ))
        return
        #else
        target.updateSyncStatus(.checking)

        CloudRecordCodec.purgeTemporaryAssets()
        prepareDirectories()
        if FileManager.default.fileExists(atPath: incompleteFetchMarkerURL.path) {
            // An earlier fetch reached this device but could not be saved.
            // Discard its token and shadow so it is downloaded in full again.
            try? FileManager.default.removeItem(at: stateURL)
            try? FileManager.default.removeItem(at: shadowURL)
            try? FileManager.default.removeItem(at: systemFieldsDirectory)
            prepareDirectories()
        }
        shadow = loadShadow()
        let state = loadState()
        let configuration = CKSyncEngine.Configuration(
            database: CKContainer(identifier: CKSchema.containerID).privateCloudDatabase,
            stateSerialization: state,
            delegate: self
        )
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        if state == nil {
            engine.state.add(pendingDatabaseChanges: [
                .saveZone(CKRecordZone(zoneID: CKSchema.zoneID))
            ])
        }
        refreshAccountStatus()
        diffAndEnqueue()
        // Opening the app should be deterministic even though CKSyncEngine's
        // normal push/scheduler path is intentionally opportunistic.
        fetchNow()
        #endif
    }

    func localLibraryDidChange() {
        // A fetch may have advanced CloudKit's token while a debounced local
        // write was pending. Once that write becomes durable, discard the
        // token and download the skipped records again from the beginning.
        if target?.canSyncLocalLibrary == true,
           FileManager.default.fileExists(atPath: incompleteFetchMarkerURL.path),
           !FileManager.default.fileExists(atPath: zoneDeletionMarkerURL.path),
           !FileManager.default.fileExists(atPath: accountChangeMarkerURL.path) {
            rebuildLocalReplica()
            return
        }
        diffAndEnqueue()
    }

    func refreshOnActivate() {
        refreshAccountStatus()
        fetchNow()
    }

    func fetchNow() {
        var cancelsStalledOperations = false
        if immediateSyncTask != nil,
           let immediateSyncStartedAt,
           currentDate().timeIntervalSince(immediateSyncStartedAt)
               > Self.immediateSyncStaleInterval {
            // A suspended CloudKit call must not block later foreground or
            // manual refresh requests. Coalesce requests while it is fresh.
            cancelImmediateSync()
            cancelsStalledOperations = true
        }
        guard engine != nil || immediateSyncOperation != nil else {
            if let target { start(target: target) }
            return
        }
        guard immediateSyncTask == nil else { return }
        target?.updateSyncStatus(.syncing)
        immediateSyncGeneration &+= 1
        let generation = immediateSyncGeneration
        immediateSyncStartedAt = currentDate()
        let engine = engine
        let immediateSyncOperation = immediateSyncOperation
        immediateSyncTask = Task { [weak self] in
            guard let self else { return }
            var completionStatus: SyncStatus?
            defer {
                self.finishImmediateSync(
                    generation: generation,
                    status: completionStatus
                )
            }
            do {
                try Task.checkCancellation()
                if cancelsStalledOperations, let engine {
                    // Cancelling the Swift task alone doesn't cancel the
                    // engine's callback-based CloudKit operations.
                    await engine.cancelOperations()
                    try Task.checkCancellation()
                }
                if let immediateSyncOperation {
                    try await immediateSyncOperation()
                } else {
                    guard let engine else { return }
                    try await engine.fetchChanges()
                    try Task.checkCancellation()
                    try await engine.sendChanges()
                }
                try Task.checkCancellation()
                completionStatus = .ready
            } catch {
                guard !Task.isCancelled else { return }
                completionStatus = .failed(Self.userFacingMessage(for: error))
            }
        }
    }

    private func finishImmediateSync(generation: UInt64, status: SyncStatus?) {
        guard generation == immediateSyncGeneration else { return }
        immediateSyncTask = nil
        immediateSyncStartedAt = nil
        if let status {
            target?.updateSyncStatus(status == .ready && lastRecordFailure != nil
                ? .failed(lastRecordFailure!) : status)
        }
        if needsSendAfterImmediateSync {
            needsSendAfterImmediateSync = false
            fetchNow()
        }
    }

    private func cancelImmediateSync() {
        // Invalidate first so a cancellation completion cannot clear or
        // publish status over a task started immediately afterward.
        immediateSyncGeneration &+= 1
        immediateSyncTask?.cancel()
        immediateSyncTask = nil
        immediateSyncStartedAt = nil
    }

    /// Clears only local CloudKit bookkeeping, then downloads the account's
    /// records again. It intentionally does not enqueue deletions.
    func rebuildLocalReplica() {
        cancelImmediateSync()
        engine = nil
        shadow = [:]
        clipFingerprintCache = [:]
        boardFingerprintCache = [:]
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: shadowURL)
        try? FileManager.default.removeItem(at: systemFieldsDirectory)
        try? FileManager.default.removeItem(at: accountChangeMarkerURL)
        try? FileManager.default.removeItem(at: zoneDeletionMarkerURL)
        lastRecordFailure = nil
        guard let target else { return }
        start(target: target)
    }

    private func refreshAccountStatus() {
        guard engine != nil || immediateSyncOperation != nil else { return }
        let accountStatusProvider = accountStatusProvider
        Task {
            do {
                let account = try await accountStatusProvider()
                await MainActor.run {
                    guard self.engine != nil || self.immediateSyncOperation != nil else { return }
                    switch account {
                    case .available:
                        // The explicit launch/foreground fetch owns the ready
                        // state so an account check cannot report success while
                        // records are still downloading.
                        break
                    case .noAccount:
                        self.target?.updateSyncStatus(.unavailable("Sign in to iCloud in Settings to sync Pesty."))
                    case .restricted:
                        self.target?.updateSyncStatus(.unavailable("iCloud is restricted on this device."))
                    case .couldNotDetermine:
                        self.target?.updateSyncStatus(.unavailable("Pesty could not determine your iCloud account status."))
                    case .temporarilyUnavailable:
                        self.target?.updateSyncStatus(.unavailable("iCloud is temporarily unavailable. Your changes remain queued."))
                    @unknown default:
                        self.target?.updateSyncStatus(.unavailable("This iCloud account status is not supported yet."))
                    }
                }
            } catch {
                await MainActor.run {
                    self.target?.updateSyncStatus(.failed(Self.userFacingMessage(for: error)))
                }
            }
        }
    }

    private struct DesiredRecord {
        var fingerprint: String
    }

    private func desiredRecords() -> [String: DesiredRecord] {
        guard let library = target?.cloudSyncLibrary else { return [:] }
        let now = Date.now
        var desired: [String: DesiredRecord] = [:]
        var eligibleClipIDs = Set<UUID>()
        var eligibleBoardIDs = Set<UUID>()
        for clip in library.clips where Self.isSyncEligible(clip, at: now) {
            eligibleClipIDs.insert(clip.id)
            desired[clip.id.uuidString] = DesiredRecord(
                fingerprint: fingerprint(CloudSyncProjection.clip(clip))
            )
        }
        for board in library.boards where Self.isSyncEligible(board, at: now) {
            eligibleBoardIDs.insert(board.id)
            desired[board.id.uuidString] = DesiredRecord(
                fingerprint: fingerprint(CloudSyncProjection.board(board))
            )
        }
        // Finalized deletions and removed records must not retain old payloads
        // through this in-memory cache.
        clipFingerprintCache = clipFingerprintCache.filter { eligibleClipIDs.contains($0.key) }
        boardFingerprintCache = boardFingerprintCache.filter { eligibleBoardIDs.contains($0.key) }
        return desired
    }

    private static func isSyncEligible(_ clip: PestyClip, at date: Date) -> Bool {
        guard clip.deletionFinalizedAt == nil else { return false }
        return (clip.deletedAt?.addingTimeInterval(PestyLibrary.deletionUndoInterval)
            ?? .distantFuture) > date
    }

    private static func isSyncEligible(_ board: PestyBoard, at date: Date) -> Bool {
        guard board.deletionFinalizedAt == nil else { return false }
        return (board.deletedAt?.addingTimeInterval(PestyLibrary.deletionUndoInterval)
            ?? .distantFuture) > date
    }

    private func diffAndEnqueue() {
        guard let engine, !isApplyingRemote, target?.canSyncLocalLibrary == true else { return }
        let desired = desiredRecords()
        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        for (name, record) in desired where shadow[name] != record.fingerprint {
            pending.append(.saveRecord(CKSchema.recordID(name)))
            shadow[name] = record.fingerprint
        }
        for name in Array(shadow.keys) where desired[name] == nil {
            pending.append(.deleteRecord(CKSchema.recordID(name)))
            shadow.removeValue(forKey: name)
            removeSystemFields(name)
        }
        guard !pending.isEmpty else { return }
        saveShadow()
        engine.state.add(pendingRecordZoneChanges: pending)
        target?.updateSyncStatus(.syncing)
        if immediateSyncTask != nil { needsSendAfterImmediateSync = true }
        // Adding pending changes schedules an automatic send. Calling
        // sendChanges() here is unsafe because this method can run while the
        // engine is delivering a delegate event, and CloudKit forbids awaiting
        // another engine operation from inside that delegate context.
    }

    private func record(for recordID: CKRecord.ID,
                        clips: [String: PestyClip], boards: [String: PestyBoard]) -> CKRecord? {
        guard target?.canSyncLocalLibrary == true else { return nil }
        if let projected = clips[recordID.recordName] {
            let record = baseRecord(name: recordID.recordName, type: CKSchema.clipType)
            CloudRecordCodec.populate(
                record,
                from: projected,
                imageFileURL: LocalAssetPersistence.url(for: projected.imageAssetID)
            )
            return record
        }
        if let board = boards[recordID.recordName] {
            let record = baseRecord(name: recordID.recordName, type: CKSchema.pinboardType)
            CloudRecordCodec.populate(record, from: board)
            return record
        }
        engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        return nil
    }

    private func applyFetchedChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        guard target?.canSyncLocalLibrary == true else {
            markIncompleteFetch()
            return
        }
        var clips: [CloudRecordCodec.DecodedClip] = []
        var boards: [PestyBoard] = []
        for modification in event.modifications {
            let record = modification.record
            saveSystemFields(record)
            if let clip = CloudRecordCodec.decodeClip(record) {
                clips.append(clip)
            } else if let board = CloudRecordCodec.decodeBoard(record) {
                boards.append(board)
            }
        }
        let deletedIDs = event.deletions.compactMap { deletion -> UUID? in
            removeSystemFields(deletion.recordID.recordName)
            return UUID(uuidString: deletion.recordID.recordName)
        }

        isApplyingRemote = true
        target?.applyRemoteSync(clips: clips, boards: boards, deletedIDs: deletedIDs)
        isApplyingRemote = false
        guard target?.canSyncLocalLibrary == true else {
            markIncompleteFetch()
            return
        }
        reconcileShadow(
            clips: clips,
            boards: boards,
            deletedIDs: deletedIDs
        )
    }

    private func reconcileShadow(clips: [CloudRecordCodec.DecodedClip], boards: [PestyBoard],
                                 deletedIDs: [UUID]) {
        let desired = desiredRecords()
        var pendingDeletes: [CKSyncEngine.PendingRecordZoneChange] = []
        var pendingSaves: [CKSyncEngine.PendingRecordZoneChange] = []
        let library = target?.cloudSyncLibrary
        let localClips = Dictionary(uniqueKeysWithValues: (library?.clips ?? []).map { ($0.id, $0) })
        let localBoards = Dictionary(uniqueKeysWithValues: (library?.boards ?? []).map { ($0.id, $0) })

        func reconcile(_ name: String, remoteUpdatedAt: Date, localUpdatedAt: Date?) {
            if let wanted = desired[name] {
                shadow[name] = wanted.fingerprint
                if let localUpdatedAt, localUpdatedAt > remoteUpdatedAt {
                    pendingSaves.append(.saveRecord(CKSchema.recordID(name)))
                }
            } else {
                shadow.removeValue(forKey: name)
                removeSystemFields(name)
                pendingDeletes.append(.deleteRecord(CKSchema.recordID(name)))
            }
        }
        for decoded in clips {
            reconcile(decoded.clip.id.uuidString, remoteUpdatedAt: decoded.clip.updatedAt,
                      localUpdatedAt: localClips[decoded.clip.id]?.updatedAt)
        }
        for board in boards {
            reconcile(board.id.uuidString, remoteUpdatedAt: board.updatedAt,
                      localUpdatedAt: localBoards[board.id]?.updatedAt)
        }
        for id in deletedIDs { shadow.removeValue(forKey: id.uuidString) }
        saveShadow()
        if !pendingDeletes.isEmpty || !pendingSaves.isEmpty {
            engine?.state.add(pendingRecordZoneChanges: pendingDeletes + pendingSaves)
        }
    }

    private func applyServerRecord(_ record: CKRecord) {
        saveSystemFields(record)
        isApplyingRemote = true
        if let clip = CloudRecordCodec.decodeClip(record) {
            target?.applyRemoteSync(clips: [clip], boards: [], deletedIDs: [])
            isApplyingRemote = false
            guard target?.canSyncLocalLibrary == true else {
                markIncompleteFetch()
                return
            }
            reconcileShadow(clips: [clip], boards: [], deletedIDs: [])
        } else if let board = CloudRecordCodec.decodeBoard(record) {
            target?.applyRemoteSync(clips: [], boards: [board], deletedIDs: [])
            isApplyingRemote = false
            guard target?.canSyncLocalLibrary == true else {
                markIncompleteFetch()
                return
            }
            reconcileShadow(clips: [], boards: [board], deletedIDs: [])
        } else {
            isApplyingRemote = false
        }
    }

    private func markIncompleteFetch() {
        try? Data().write(to: incompleteFetchMarkerURL, options: LocalFileProtection.writingOptions)
        target?.updateSyncStatus(.failed(
            "iCloud changes could not be saved locally. Pesty will download them again after the library can be saved."
        ))
    }

    private func pauseAfterZoneDeletion() {
        cancelImmediateSync()
        engine = nil
        shadow = [:]
        clipFingerprintCache = [:]
        boardFingerprintCache = [:]
        try? FileManager.default.removeItem(at: shadowURL)
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: systemFieldsDirectory)
        try? Data().write(to: zoneDeletionMarkerURL, options: LocalFileProtection.writingOptions)
        target?.updateSyncStatus(.unavailable(
            "Pesty's iCloud data was deleted. Sync is paused so this device does not upload it again. Clear the local library to start fresh."
        ))
    }

    private func resetAfterAccountChange() {
        engine = nil
        shadow = [:]
        clipFingerprintCache = [:]
        boardFingerprintCache = [:]
        try? FileManager.default.removeItem(at: shadowURL)
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: systemFieldsDirectory)
        prepareDirectories()
        try? Data().write(to: accountChangeMarkerURL, options: LocalFileProtection.writingOptions)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: accountChangeMarkerURL.path
        )
        target?.updateSyncStatus(.unavailable(
            "The iCloud account changed. Clear the local library in Settings before downloading the new account."
        ))
    }

    private func fingerprint(_ clip: PestyClip) -> String {
        if let cached = clipFingerprintCache[clip.id],
           cached.source.updatedAt == clip.updatedAt,
           cached.source == clip {
            return cached.fingerprint
        }
        let value = digest([
            clip.kind.rawValue,
            clip.text ?? "",
            clip.richTextData?.base64EncodedString() ?? "",
            clip.imageHash ?? "",
            clip.fileNames.joined(separator: "\u{1F}"),
            clip.colorHex ?? "",
            clip.sourceBundleID ?? "",
            clip.sourceAppName ?? "",
            clip.sourceDeviceName ?? "",
            (clip.sourceFileURLs ?? []).joined(separator: "\u{1F}"),
            clip.customTitle ?? "",
            Self.fingerprintDate(clip.capturedAt),
            Self.fingerprintDate(clip.updatedAt),
            clip.lastUsedAt.map(Self.fingerprintDate) ?? "",
            clip.containerID?.uuidString ?? CKSchema.historyContainerValue,
            clip.deletedAt == nil ? "active" : "pending-delete"
        ])
        clipFingerprintCache[clip.id] = (clip, value)
        return value
    }

    private func fingerprint(_ board: PestyBoard) -> String {
        if let cached = boardFingerprintCache[board.id],
           cached.source.updatedAt == board.updatedAt,
           cached.source == board {
            return cached.fingerprint
        }
        let value = digest([
            "pinboard",
            board.name,
            board.colorHex,
            board.clipIDs.map(\.uuidString).joined(separator: "\u{1F}"),
            board.pinnedClipIDs.map(\.uuidString).joined(separator: "\u{1F}"),
            String(board.sortIndex),
            Self.fingerprintDate(board.updatedAt),
            board.deletedAt == nil ? "active" : "pending-delete"
        ])
        boardFingerprintCache[board.id] = (board, value)
        return value
    }

    private static func fingerprintDate(_ date: Date) -> String {
        // Local JSON and CloudKit both retain milliseconds. Ignore finer
        // floating-point differences so relaunch does not re-upload assets.
        String(Int64((date.timeIntervalSince1970 * 1_000).rounded()))
    }

    private func digest(_ values: [String]) -> String {
        var hasher = SHA256()
        for value in values {
            hasher.update(data: Data(value.utf8))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func prepareDirectories() {
        try? LocalFileProtection.prepareDirectory(at: systemFieldsDirectory)
    }

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveState(_ state: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: LocalFileProtection.writingOptions)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    private func loadShadow() -> [String: String] {
        guard let data = try? Data(contentsOf: shadowURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func saveShadow() {
        guard let data = try? JSONEncoder().encode(shadow) else { return }
        try? data.write(to: shadowURL, options: LocalFileProtection.writingOptions)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: shadowURL.path)
    }

    private func systemFieldsURL(_ name: String) -> URL {
        systemFieldsDirectory.appendingPathComponent(name).appendingPathExtension("ckrecord")
    }

    private func saveSystemFields(_ record: CKRecord) {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        let url = systemFieldsURL(record.recordID.recordName)
        try? archiver.encodedData.write(
            to: url,
            options: LocalFileProtection.writingOptions
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func removeSystemFields(_ name: String) {
        try? FileManager.default.removeItem(at: systemFieldsURL(name))
    }

    private func baseRecord(name: String, type: String) -> CKRecord {
        if let data = try? Data(contentsOf: systemFieldsURL(name)),
           let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) {
            unarchiver.requiresSecureCoding = true
            if let record = CKRecord(coder: unarchiver), record.recordType == type {
                return record
            }
        }
        return CKRecord(recordType: type, recordID: CKSchema.recordID(name))
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let cloudError = error as? CKError {
            switch cloudError.code {
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
                return "iCloud is temporarily unreachable. Your changes remain queued and will retry."
            case .notAuthenticated:
                return "Sign in to iCloud in Settings to sync Pesty."
            case .quotaExceeded:
                return "Your iCloud storage is full. Free some space, then try syncing again."
            default:
                break
            }
        }
        return "Pesty could not sync right now. \(error.localizedDescription)"
    }
}

extension CloudSyncService: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            saveState(update.stateSerialization)

        case .accountChange(let change):
            switch change.changeType {
            case .signIn:
                refreshAccountStatus()
                diffAndEnqueue()
            case .signOut, .switchAccounts:
                resetAfterAccountChange()
            @unknown default:
                refreshAccountStatus()
            }

        case .fetchedDatabaseChanges(let changes):
            if changes.deletions.contains(where: { $0.zoneID.zoneName == CKSchema.zoneName }) {
                pauseAfterZoneDeletion()
            }

        case .fetchedRecordZoneChanges(let changes):
            applyFetchedChanges(changes)

        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords { saveSystemFields(record) }
            for recordID in sent.deletedRecordIDs { removeSystemFields(recordID.recordName) }
            var encounteredRetryableFailure = false
            for failure in sent.failedRecordSaves {
                switch failure.error.code {
                case .serverRecordChanged:
                    if let serverRecord = failure.error.serverRecord {
                        applyServerRecord(serverRecord)
                    } else {
                        encounteredRetryableFailure = true
                    }
                case .zoneNotFound:
                    pauseAfterZoneDeletion()
                case .unknownItem:
                    removeSystemFields(failure.record.recordID.recordName)
                    syncEngine.state.add(pendingRecordZoneChanges: [
                        .saveRecord(failure.record.recordID)
                    ])
                default:
                    shadow.removeValue(forKey: failure.record.recordID.recordName)
                    encounteredRetryableFailure = true
                }
            }
            for (recordID, error) in sent.failedRecordDeletes {
                switch error.code {
                case .unknownItem:
                    removeSystemFields(recordID.recordName)
                case .zoneNotFound:
                    pauseAfterZoneDeletion()
                case .serverRecordChanged:
                    if let serverRecord = error.serverRecord {
                        saveSystemFields(serverRecord)
                    }
                    syncEngine.state.add(pendingRecordZoneChanges: [
                        .deleteRecord(recordID)
                    ])
                    encounteredRetryableFailure = true
                default:
                    encounteredRetryableFailure = true
                }
            }
            saveShadow()
            CloudRecordCodec.purgeTemporaryAssets()
            lastRecordFailure = encounteredRetryableFailure
                ? "Some items could not sync yet. They remain queued for retry." : nil
            if let lastRecordFailure {
                target?.updateSyncStatus(.failed(lastRecordFailure))
            } else if engine != nil, immediateSyncTask == nil {
                target?.updateSyncStatus(.ready)
            }

        case .sentDatabaseChanges:
            break

        case .willFetchChanges, .willSendChanges:
            target?.updateSyncStatus(.syncing)

        case .didFetchChanges, .didSendChanges:
            if case .didFetchChanges = event, target?.canSyncLocalLibrary == true {
                try? FileManager.default.removeItem(at: incompleteFetchMarkerURL)
            }
            if let lastRecordFailure {
                target?.updateSyncStatus(.failed(lastRecordFailure))
            } else if engine != nil, immediateSyncTask == nil {
                target?.updateSyncStatus(.ready)
            }

        case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break

        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        guard !pending.isEmpty,
              target?.canSyncLocalLibrary == true,
              let library = target?.cloudSyncLibrary else { return nil }
        let now = Date.now
        var clips: [String: PestyClip] = [:]
        var boards: [String: PestyBoard] = [:]
        for clip in library.clips where Self.isSyncEligible(clip, at: now) {
            clips[clip.id.uuidString] = CloudSyncProjection.clip(clip)
        }
        for board in library.boards where Self.isSyncEligible(board, at: now) {
            boards[board.id.uuidString] = CloudSyncProjection.board(board)
        }
        let projectedClips = clips
        let projectedBoards = boards
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] recordID in
            await self?.record(for: recordID, clips: projectedClips, boards: projectedBoards)
        }
    }
}
