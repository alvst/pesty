#if MAS
import AppKit
import CloudKit
import CryptoKit
import Observation

/// Record-level private CloudKit sync for the Mac App Store build. Direct
/// downloads continue to use the existing optional iCloud Drive snapshot.
@Observable
@MainActor
final class CloudSyncService {
    static let shared = CloudSyncService()

    private(set) var status = "Sync is off"
    private(set) var requiresAccountConfirmation = false

    @ObservationIgnored private var engine: CKSyncEngine?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var shadow: [String: String] = [:]
    @ObservationIgnored private var protectedRemoteRecordNames: Set<String> = []
    @ObservationIgnored private var isApplyingRemote = false
    @ObservationIgnored private var lastFetchStartedAt: Date?
    @ObservationIgnored private var fallbackFetchTimer: Timer?
    /// Pushes from CloudKit can lag or drop, so opening the bar and a slow
    /// timer both fetch as a fallback; these keep that from hammering iCloud.
    private static let barOpenFetchThrottle: TimeInterval = 5
    private static let fallbackFetchInterval: TimeInterval = 60

    private var store: ClipboardStore { ClipboardStore.shared }
    private var stateURL: URL { ClipboardStore.localBase.appendingPathComponent("cksync-state.json") }
    private var shadowURL: URL { ClipboardStore.localBase.appendingPathComponent("cksync-shadow.json") }
    private var protectedURL: URL { ClipboardStore.localBase.appendingPathComponent("cksync-protected.json") }
    private var accountChangeMarkerURL: URL {
        ClipboardStore.localBase.appendingPathComponent("cksync-account-changed")
    }
    private var systemFieldsDirectory: URL {
        ClipboardStore.localBase.appendingPathComponent("ck-system-fields", isDirectory: true)
    }

    private init() {
        if FileManager.default.fileExists(atPath: accountChangeMarkerURL.path) {
            requiresAccountConfirmation = true
            status = "iCloud account changed — confirmation required"
        }
    }

    func start() {
        guard engine == nil else { return }
        if FileManager.default.fileExists(atPath: accountChangeMarkerURL.path) {
            requiresAccountConfirmation = true
            Settings.shared.cloudKitSync = false
            status = "iCloud account changed — confirmation required"
            return
        }
        status = "Checking iCloud…"
        CloudRecordCodec.purgeTemporaryAssets()
        prepareDirectories()
        shadow = load([String: String].self, from: shadowURL) ?? [:]
        protectedRemoteRecordNames = load(Set<String>.self, from: protectedURL) ?? []
        let state = load(CKSyncEngine.State.Serialization.self, from: stateURL)
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
        addObservers()
        refreshAccountStatus()
        diffAndEnqueue()
        fetchNow()
        startFallbackFetchTimer()
    }

    func stop() {
        removeObservers()
        fallbackFetchTimer?.invalidate()
        fallbackFetchTimer = nil
        engine = nil
        status = "Sync is off"
    }

    /// Called when the bar opens: the user is probably looking for something
    /// that just synced from another device, so do not wait for a push.
    func fetchIfStale() {
        guard engine != nil else { return }
        if let lastFetchStartedAt,
           Date.now.timeIntervalSince(lastFetchStartedAt) < Self.barOpenFetchThrottle {
            return
        }
        fetchNow()
    }

    private func fetchNow() {
        guard let engine else { return }
        lastFetchStartedAt = .now
        Task { try? await engine.fetchChanges() }
    }

    private func startFallbackFetchTimer() {
        fallbackFetchTimer?.invalidate()
        let timer = Timer(timeInterval: Self.fallbackFetchInterval, repeats: true) { _ in
            Task { @MainActor in CloudSyncService.shared.fetchNow() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        fallbackFetchTimer = timer
    }

    func enable() {
        guard !FileManager.default.fileExists(atPath: accountChangeMarkerURL.path) else {
            requiresAccountConfirmation = true
            Settings.shared.cloudKitSync = false
            status = "iCloud account changed — confirmation required"
            return
        }
        shadow = [:]
        save(shadow, to: shadowURL)
        if engine == nil { start() } else { diffAndEnqueue() }
    }

    /// Explicitly authorized account transition. The existing local library
    /// becomes the initial upload to the newly signed-in private database.
    func confirmAccountChangeKeepingLocalLibrary() {
        try? FileManager.default.removeItem(at: accountChangeMarkerURL)
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: shadowURL)
        try? FileManager.default.removeItem(at: protectedURL)
        try? FileManager.default.removeItem(at: systemFieldsDirectory)
        shadow = [:]
        protectedRemoteRecordNames = []
        requiresAccountConfirmation = false
        Settings.shared.cloudKitSync = true
        start()
    }

    func refreshNow() {
        guard let engine else { return }
        status = "Syncing…"
        lastFetchStartedAt = .now
        Task {
            do {
                try await engine.fetchChanges()
                try await engine.sendChanges()
                await MainActor.run { self.status = "Synced with iCloud" }
            } catch {
                await MainActor.run { self.status = Self.message(for: error) }
            }
        }
    }

    private func addObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .pestyStoreDidSave,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in CloudSyncService.shared.diffAndEnqueue() }
        })
        observers.append(center.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in CloudSyncService.shared.refreshAccountStatus() }
        })
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func refreshAccountStatus() {
        let container = CKContainer(identifier: CKSchema.containerID)
        Task {
            do {
                let account = try await container.accountStatus()
                await MainActor.run {
                    guard self.engine != nil else { return }
                    switch account {
                    case .available:
                        self.status = "Synced with iCloud"
                    case .noAccount:
                        self.status = "Sign in to iCloud to sync"
                    case .restricted:
                        self.status = "iCloud is restricted on this Mac"
                    case .temporarilyUnavailable:
                        self.status = "iCloud is temporarily unavailable"
                    case .couldNotDetermine:
                        self.status = "Could not determine iCloud status"
                    @unknown default:
                        self.status = "iCloud is unavailable"
                    }
                }
            } catch {
                await MainActor.run { self.status = Self.message(for: error) }
            }
        }
    }

    private struct DesiredRecord {
        var fingerprint: String
    }

    private func desiredRecords() -> [String: DesiredRecord] {
        var desired: [String: DesiredRecord] = [:]
        for board in store.cloudSyncPinboards {
            desired[board.id.uuidString] = DesiredRecord(fingerprint: fingerprint(board))
        }
        for projection in store.cloudSyncClips {
            desired[projection.item.id.uuidString] = DesiredRecord(
                fingerprint: fingerprint(projection.item, container: projection.container)
            )
        }
        return desired
    }

    private func diffAndEnqueue() {
        guard let engine, !isApplyingRemote else { return }
        let desired = desiredRecords()
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        for (name, record) in desired where shadow[name] != record.fingerprint {
            changes.append(.saveRecord(CKSchema.recordID(name)))
            shadow[name] = record.fingerprint
            protectedRemoteRecordNames.remove(name)
        }
        for name in Array(shadow.keys)
        where desired[name] == nil && !isProtectedFromCloudDeletion(name) {
            changes.append(.deleteRecord(CKSchema.recordID(name)))
            shadow.removeValue(forKey: name)
            removeSystemFields(name)
        }
        guard !changes.isEmpty else { return }
        save(shadow, to: shadowURL)
        save(protectedRemoteRecordNames, to: protectedURL)
        engine.state.add(pendingRecordZoneChanges: changes)
        status = "Syncing…"
        // Adding pending changes schedules an automatic send. Calling
        // sendChanges() here is unsafe because this method can run while the
        // engine is delivering a delegate event, and CloudKit forbids awaiting
        // another engine operation from inside that delegate context.
    }

    private func record(for recordID: CKRecord.ID) -> CKRecord? {
        let name = recordID.recordName
        if let board = store.cloudSyncPinboards.first(where: { $0.id.uuidString == name }) {
            let record = baseRecord(name: name, type: CKSchema.pinboardType)
            CloudRecordCodec.populate(record, from: board)
            return record
        }
        if let projection = store.cloudSyncClips.first(where: { $0.item.id.uuidString == name }) {
            let record = baseRecord(name: name, type: CKSchema.clipType)
            CloudRecordCodec.populate(
                record,
                from: projection.item,
                container: projection.container,
                // Image clips and image *files* (screenshots) both carry pixels.
                imageFileURL: projection.item.imageFileName != nil
                    ? store.imageURL(for: projection.item)
                    : nil
            )
            return record
        }
        engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        return nil
    }

    private func applyFetchedChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        var clips: [CloudRecordCodec.DecodedClip] = []
        var boards: [CloudRecordCodec.DecodedBoard] = []
        for modification in event.modifications {
            let record = modification.record
            saveSystemFields(record)
            if let decoded = CloudRecordCodec.decodeClip(record) {
                if Settings.shared.isIgnoringSourceApp(decoded.item.sourceBundleID)
                    || store.cloudRetentionExcludedIDs.contains(decoded.item.id) {
                    protectedRemoteRecordNames.insert(record.recordID.recordName)
                    shadow[record.recordID.recordName] = fingerprint(
                        decoded.item,
                        container: decoded.container
                    )
                } else {
                    protectedRemoteRecordNames.remove(record.recordID.recordName)
                    clips.append(decoded)
                }
            } else if let board = CloudRecordCodec.decodeBoard(record) {
                boards.append(board)
            }
        }
        let deletedIDs = event.deletions.compactMap { deletion -> UUID? in
            let name = deletion.recordID.recordName
            removeSystemFields(name)
            protectedRemoteRecordNames.remove(name)
            return UUID(uuidString: name)
        }

        isApplyingRemote = true
        store.applyRemote(clips: clips, boards: boards, deletedIDs: deletedIDs)
        isApplyingRemote = false
        reconcileShadow(
            clipIDs: clips.map { $0.item.id },
            boardIDs: boards.map { $0.board.id },
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
            } else if !isProtectedFromCloudDeletion(name) {
                shadow.removeValue(forKey: name)
                removeSystemFields(name)
                pendingDeletes.append(.deleteRecord(CKSchema.recordID(name)))
            }
        }
        for id in deletedIDs { shadow.removeValue(forKey: id.uuidString) }
        save(shadow, to: shadowURL)
        save(protectedRemoteRecordNames, to: protectedURL)
        if !pendingDeletes.isEmpty {
            engine?.state.add(pendingRecordZoneChanges: pendingDeletes)
        }
    }

    private func isProtectedFromCloudDeletion(_ recordName: String) -> Bool {
        if protectedRemoteRecordNames.contains(recordName) { return true }
        guard let id = UUID(uuidString: recordName) else { return false }
        return store.cloudRetentionExcludedIDs.contains(id)
    }

    private func applyServerRecord(_ record: CKRecord) {
        saveSystemFields(record)
        if let clip = CloudRecordCodec.decodeClip(record),
           Settings.shared.isIgnoringSourceApp(clip.item.sourceBundleID) {
            protectedRemoteRecordNames.insert(record.recordID.recordName)
            shadow[record.recordID.recordName] = fingerprint(clip.item, container: clip.container)
            save(shadow, to: shadowURL)
            save(protectedRemoteRecordNames, to: protectedURL)
            return
        }

        isApplyingRemote = true
        if let clip = CloudRecordCodec.decodeClip(record) {
            store.applyRemote(clips: [clip], boards: [], deletedIDs: [])
            isApplyingRemote = false
            reconcileShadow(clipIDs: [clip.item.id], boardIDs: [], deletedIDs: [])
        } else if let board = CloudRecordCodec.decodeBoard(record) {
            store.applyRemote(clips: [], boards: [board], deletedIDs: [])
            isApplyingRemote = false
            reconcileShadow(clipIDs: [], boardIDs: [board.board.id], deletedIDs: [])
        } else {
            isApplyingRemote = false
        }
    }

    private func recreateZoneAndReupload() {
        guard let engine else { return }
        shadow = [:]
        protectedRemoteRecordNames = []
        save(shadow, to: shadowURL)
        save(protectedRemoteRecordNames, to: protectedURL)
        try? FileManager.default.removeItem(at: systemFieldsDirectory)
        prepareDirectories()
        engine.state.add(pendingDatabaseChanges: [
            .saveZone(CKRecordZone(zoneID: CKSchema.zoneID))
        ])
        diffAndEnqueue()
    }

    private func resetAfterAccountChange() {
        removeObservers()
        engine = nil
        shadow = [:]
        protectedRemoteRecordNames = []
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: shadowURL)
        try? FileManager.default.removeItem(at: protectedURL)
        try? FileManager.default.removeItem(at: systemFieldsDirectory)
        prepareDirectories()
        try? Data().write(to: accountChangeMarkerURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: accountChangeMarkerURL.path
        )
        requiresAccountConfirmation = true
        Settings.shared.cloudKitSync = false
        status = "iCloud account changed — confirmation required"
    }

    private func fingerprint(_ item: ClipItem, container: String) -> String {
        digest([
            item.type.rawValue,
            item.text ?? "",
            item.rtfData?.base64EncodedString() ?? "",
            item.imageHash ?? "",
            item.fileURLs.joined(separator: "\u{1F}"),
            item.colorHex ?? "",
            item.sourceBundleID ?? "",
            item.sourceAppName ?? "",
            item.sourceDeviceName ?? "",
            item.customTitle ?? "",
            String(item.createdAt.timeIntervalSinceReferenceDate),
            String(item.updatedAt.timeIntervalSinceReferenceDate),
            String(item.lastUsedAt?.timeIntervalSinceReferenceDate ?? 0),
            container
        ])
    }

    private func fingerprint(_ board: Pinboard) -> String {
        digest([
            "pinboard",
            board.name,
            board.colorHex,
            board.items.map { $0.id.uuidString }.joined(separator: "\u{1F}"),
            board.pinnedItemIDs.map(\.uuidString).joined(separator: "\u{1F}"),
            String(board.sortIndex),
            String(board.createdAt.timeIntervalSinceReferenceDate),
            String(board.updatedAt.timeIntervalSinceReferenceDate)
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

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func systemFieldsURL(_ name: String) -> URL {
        systemFieldsDirectory.appendingPathComponent(name).appendingPathExtension("ckrecord")
    }

    private func saveSystemFields(_ record: CKRecord) {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        let url = systemFieldsURL(record.recordID.recordName)
        try? archiver.encodedData.write(to: url, options: .atomic)
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

    private static func message(for error: Error) -> String {
        guard let cloudError = error as? CKError else {
            return "Sync failed: \(error.localizedDescription)"
        }
        switch cloudError.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
            return "iCloud is temporarily unreachable — changes remain queued"
        case .notAuthenticated:
            return "Sign in to iCloud to sync"
        case .quotaExceeded:
            return "iCloud storage is full"
        default:
            return "Sync failed: \(cloudError.localizedDescription)"
        }
    }
}

extension CloudSyncService: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            save(update.stateSerialization, to: stateURL)

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
            var retryableFailure = false
            for failure in sent.failedRecordSaves {
                switch failure.error.code {
                case .serverRecordChanged:
                    if let server = failure.error.serverRecord { applyServerRecord(server) }
                case .zoneNotFound:
                    recreateZoneAndReupload()
                case .unknownItem:
                    removeSystemFields(failure.record.recordID.recordName)
                    syncEngine.state.add(pendingRecordZoneChanges: [
                        .saveRecord(failure.record.recordID)
                    ])
                default:
                    shadow.removeValue(forKey: failure.record.recordID.recordName)
                    retryableFailure = true
                }
            }
            save(shadow, to: shadowURL)
            CloudRecordCodec.purgeTemporaryAssets()
            status = retryableFailure
                ? "Some changes could not upload yet — retrying"
                : "Synced with iCloud"

        case .sentDatabaseChanges:
            break

        case .willFetchChanges, .willFetchRecordZoneChanges,
             .didFetchRecordZoneChanges, .didFetchChanges,
             .willSendChanges, .didSendChanges:
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
#endif
