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
            "Your Pesty-Alvie library is up to date across signed-in devices."
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
    private var isApplyingRemote = false
    private var immediateSyncTask: Task<Void, Never>?
    private var immediateSyncStartedAt: Date?
    private var immediateSyncGeneration: UInt64 = 0
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

        #if targetEnvironment(simulator)
        target.updateSyncStatus(.unavailable(
            "CloudKit sync requires a signed device build. The unsigned simulator build still supports local libraries and tests."
        ))
        return
        #else
        target.updateSyncStatus(.checking)

        CloudRecordCodec.purgeTemporaryAssets()
        prepareDirectories()
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
        diffAndEnqueue()
    }

    func refreshOnActivate() {
        if immediateSyncTask != nil,
           let immediateSyncStartedAt,
           currentDate().timeIntervalSince(immediateSyncStartedAt)
               > Self.immediateSyncStaleInterval {
            // A CloudKit call suspended in the background must not block every
            // later foreground fetch. A fresh cold-launch task is left alone.
            cancelImmediateSync()
        }
        refreshAccountStatus()
        fetchNow()
    }

    func fetchNow() {
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
        if let status { target?.updateSyncStatus(status) }
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
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: shadowURL)
        try? FileManager.default.removeItem(at: systemFieldsDirectory)
        try? FileManager.default.removeItem(at: accountChangeMarkerURL)
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
                        self.target?.updateSyncStatus(.unavailable("Sign in to iCloud in Settings to sync Pesty-Alvie."))
                    case .restricted:
                        self.target?.updateSyncStatus(.unavailable("iCloud is restricted on this device."))
                    case .couldNotDetermine:
                        self.target?.updateSyncStatus(.unavailable("Pesty-Alvie could not determine your iCloud account status."))
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
        for clip in library.clips {
            if clip.deletionFinalizedAt != nil { continue }
            if let deletedAt = clip.deletedAt,
               deletedAt.addingTimeInterval(PestyLibrary.deletionUndoInterval) <= now {
                continue
            }
            desired[clip.id.uuidString] = DesiredRecord(
                fingerprint: fingerprint(CloudSyncProjection.clip(clip))
            )
        }
        for board in library.boards {
            if board.deletionFinalizedAt != nil { continue }
            if let deletedAt = board.deletedAt,
               deletedAt.addingTimeInterval(PestyLibrary.deletionUndoInterval) <= now {
                continue
            }
            desired[board.id.uuidString] = DesiredRecord(
                fingerprint: fingerprint(CloudSyncProjection.board(board))
            )
        }
        return desired
    }

    private func diffAndEnqueue() {
        guard let engine, !isApplyingRemote else { return }
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
        // Adding pending changes schedules an automatic send. Calling
        // sendChanges() here is unsafe because this method can run while the
        // engine is delivering a delegate event, and CloudKit forbids awaiting
        // another engine operation from inside that delegate context.
    }

    private func record(for recordID: CKRecord.ID) -> CKRecord? {
        guard desiredRecords()[recordID.recordName] != nil,
              let library = target?.cloudSyncLibrary else {
            engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
        if let clip = library.clips.first(where: { $0.id.uuidString == recordID.recordName }) {
            let projected = CloudSyncProjection.clip(clip)
            let record = baseRecord(name: recordID.recordName, type: CKSchema.clipType)
            CloudRecordCodec.populate(
                record,
                from: projected,
                imageFileURL: LocalAssetPersistence.url(for: projected.imageAssetID)
            )
            return record
        }
        if let board = library.boards.first(where: { $0.id.uuidString == recordID.recordName }) {
            let record = baseRecord(name: recordID.recordName, type: CKSchema.pinboardType)
            CloudRecordCodec.populate(record, from: CloudSyncProjection.board(board))
            return record
        }
        engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        return nil
    }

    private func applyFetchedChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) {
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
        reconcileShadow(
            clipIDs: clips.map(\.clip.id),
            boardIDs: boards.map(\.id),
            deletedIDs: deletedIDs
        )
    }

    private func reconcileShadow(clipIDs: [UUID], boardIDs: [UUID], deletedIDs: [UUID]) {
        let desired = desiredRecords()
        var pendingDeletes: [CKSyncEngine.PendingRecordZoneChange] = []
        for id in clipIDs + boardIDs {
            let name = id.uuidString
            if let record = desired[name] {
                shadow[name] = record.fingerprint
            } else {
                shadow.removeValue(forKey: name)
                removeSystemFields(name)
                pendingDeletes.append(.deleteRecord(CKSchema.recordID(name)))
            }
        }
        for id in deletedIDs { shadow.removeValue(forKey: id.uuidString) }
        saveShadow()
        if !pendingDeletes.isEmpty {
            engine?.state.add(pendingRecordZoneChanges: pendingDeletes)
        }
    }

    private func applyServerRecord(_ record: CKRecord) {
        saveSystemFields(record)
        isApplyingRemote = true
        if let clip = CloudRecordCodec.decodeClip(record) {
            target?.applyRemoteSync(clips: [clip], boards: [], deletedIDs: [])
            isApplyingRemote = false
            reconcileShadow(clipIDs: [clip.clip.id], boardIDs: [], deletedIDs: [])
        } else if let board = CloudRecordCodec.decodeBoard(record) {
            target?.applyRemoteSync(clips: [], boards: [board], deletedIDs: [])
            isApplyingRemote = false
            reconcileShadow(clipIDs: [], boardIDs: [board.id], deletedIDs: [])
        } else {
            isApplyingRemote = false
        }
    }

    private func recreateZoneAndReupload() {
        guard let engine else { return }
        shadow = [:]
        saveShadow()
        try? FileManager.default.removeItem(at: systemFieldsDirectory)
        prepareDirectories()
        engine.state.add(pendingDatabaseChanges: [
            .saveZone(CKRecordZone(zoneID: CKSchema.zoneID))
        ])
        diffAndEnqueue()
    }

    private func resetAfterAccountChange() {
        engine = nil
        shadow = [:]
        try? FileManager.default.removeItem(at: shadowURL)
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: systemFieldsDirectory)
        prepareDirectories()
        try? Data().write(to: accountChangeMarkerURL, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: accountChangeMarkerURL.path
        )
        target?.updateSyncStatus(.unavailable(
            "The iCloud account changed. Clear the local library in Settings before downloading the new account."
        ))
    }

    private func fingerprint(_ clip: PestyClip) -> String {
        digest([
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
            String(clip.capturedAt.timeIntervalSinceReferenceDate),
            String(clip.updatedAt.timeIntervalSinceReferenceDate),
            clip.containerID?.uuidString ?? CKSchema.historyContainerValue,
            clip.deletedAt == nil ? "active" : "pending-delete"
        ])
    }

    private func fingerprint(_ board: PestyBoard) -> String {
        digest([
            "pinboard",
            board.name,
            board.colorHex,
            board.clipIDs.map(\.uuidString).joined(separator: "\u{1F}"),
            board.pinnedClipIDs.map(\.uuidString).joined(separator: "\u{1F}"),
            String(board.sortIndex),
            String(board.updatedAt.timeIntervalSinceReferenceDate),
            board.deletedAt == nil ? "active" : "pending-delete"
        ])
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
        try? FileManager.default.createDirectory(
            at: systemFieldsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveState(_ state: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    private func loadShadow() -> [String: String] {
        guard let data = try? Data(contentsOf: shadowURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func saveShadow() {
        guard let data = try? JSONEncoder().encode(shadow) else { return }
        try? data.write(to: shadowURL, options: [.atomic, .completeFileProtection])
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
            options: [.atomic, .completeFileProtection]
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
                return "Sign in to iCloud in Settings to sync Pesty-Alvie."
            case .quotaExceeded:
                return "Your iCloud storage is full. Free some space, then try syncing again."
            default:
                break
            }
        }
        return "Pesty-Alvie could not sync right now. \(error.localizedDescription)"
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
                recreateZoneAndReupload()
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
                    }
                case .zoneNotFound:
                    recreateZoneAndReupload()
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
            saveShadow()
            CloudRecordCodec.purgeTemporaryAssets()
            target?.updateSyncStatus(
                encounteredRetryableFailure
                    ? .failed("Some items could not upload yet. They remain queued for retry.")
                    : .ready
            )

        case .sentDatabaseChanges:
            break

        case .willFetchChanges, .willSendChanges:
            target?.updateSyncStatus(.syncing)

        case .didFetchChanges, .didSendChanges:
            target?.updateSyncStatus(.ready)

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
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] recordID in
            await self?.record(for: recordID)
        }
    }
}
