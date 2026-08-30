import Foundation
import JavaScriptCore

final class ExtensionHost {
    private static let maximumTextUTF16Units = 65_536
    private static let maximumBadgeCharacters = 24
    private static let maximumExceptionCharacters = 200
    private static let loadBudget: TimeInterval = 0.5
    private static let badgeBudget: TimeInterval = 0.1
    private static let quarantineThreshold = 5

    private let queue = DispatchQueue(
        label: "com.alvst.pesty-alvie.extension-host",
        qos: .utility
    )
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let failureStateLock = NSLock()
    private var consecutiveFailures: [String: Int] = [:]
    private var quarantinedIDs: Set<String> = []
    private var quarantineHandler: (@MainActor @Sendable (String) -> Void)?

    init() {
        queue.setSpecific(key: queueKey, value: 1)
    }

    var onQuarantine: (@MainActor @Sendable (String) -> Void)? {
        get {
            failureStateLock.lock()
            defer { failureStateLock.unlock() }
            return quarantineHandler
        }
        set {
            failureStateLock.lock()
            quarantineHandler = newValue
            failureStateLock.unlock()
        }
    }

    func validate(source: String) -> Result<ExtensionManifest, ExtensionError> {
        runValidation(source: source, timeout: Self.loadBudget)
    }

    func badgeSync(
        clipType: String,
        text: String,
        extension installedExtension: InstalledExtension
    ) -> Result<String?, ExtensionError> {
        syncOnQueue {
            badgeOnQueue(
                clipType: clipType,
                text: text,
                extension: installedExtension
            )
        }
    }

    func badge(
        clipType: String,
        text: String,
        extension installedExtension: InstalledExtension,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        queue.async { [self] in
            let value: String?
            switch badgeOnQueue(
                clipType: clipType,
                text: text,
                extension: installedExtension
            ) {
            case .success(let badge):
                value = badge
            case .failure:
                value = nil
            }
            DispatchQueue.main.async {
                completion(value)
            }
        }
    }

    func isQuarantined(_ id: String) -> Bool {
        failureStateLock.lock()
        defer { failureStateLock.unlock() }
        return quarantinedIDs.contains(id)
    }

    func liftQuarantine(_ id: String) {
        failureStateLock.lock()
        quarantinedIDs.remove(id)
        consecutiveFailures.removeValue(forKey: id)
        failureStateLock.unlock()
    }

    private func badgeOnQueue(
        clipType: String,
        text: String,
        extension installedExtension: InstalledExtension
    ) -> Result<String?, ExtensionError> {
        let id = installedExtension.id
        guard !isQuarantined(id) else {
            return .success(nil)
        }

        let result = runBadge(
            source: installedExtension.source,
            clipType: clipType,
            text: Self.boundedText(text)
        )

        record(result, for: id)
        return result
    }

    private func record(
        _ result: Result<String?, ExtensionError>,
        for id: String
    ) {
        var callback: (@MainActor @Sendable (String) -> Void)?
        failureStateLock.lock()

        switch result {
        case .success:
            consecutiveFailures.removeValue(forKey: id)
        case .failure(.timedOut):
            consecutiveFailures[id] = Self.quarantineThreshold
            if quarantinedIDs.insert(id).inserted {
                callback = quarantineHandler
            }
        case .failure:
            let failures = (consecutiveFailures[id] ?? 0) + 1
            consecutiveFailures[id] = failures
            if failures >= Self.quarantineThreshold,
               quarantinedIDs.insert(id).inserted {
                callback = quarantineHandler
            }
        }
        failureStateLock.unlock()

        if let callback {
            DispatchQueue.main.async {
                callback(id)
            }
        }
    }

    private func runValidation(
        source: String,
        timeout: TimeInterval
    ) -> Result<ExtensionManifest, ExtensionError> {
        let result = LockedBox<Result<ExtensionManifest, ExtensionError>>()
        let finished = DispatchSemaphore(value: 0)
        startWorker(named: "extension-validate") {
            autoreleasepool {
                let outcome = Self.load(source: source).map(\.manifest)
                result.set(outcome)
                finished.signal()
            }
        }

        guard finished.wait(timeout: .now() + timeout) == .success else {
            // Timeout termination abandons the tracking thread; the script
            // itself cannot be killed with public JSC API.
            return .failure(.timedOut)
        }
        return result.get() ?? .failure(.scriptException("Extension worker returned no result"))
    }

    private func runBadge(
        source: String,
        clipType: String,
        text: String
    ) -> Result<String?, ExtensionError> {
        let state = BadgeWorkerState()
        let loadFinished = DispatchSemaphore(value: 0)
        let startBadge = DispatchSemaphore(value: 0)
        let badgeFinished = DispatchSemaphore(value: 0)

        startWorker(named: "extension-badge") {
            autoreleasepool {
                switch Self.load(source: source) {
                case .failure(let error):
                    state.setLoad(.failure(error))
                    loadFinished.signal()
                case .success(let loaded):
                    state.setLoad(.success(loaded.manifest))
                    loadFinished.signal()
                    startBadge.wait()

                    let result = Self.callBadge(
                        loaded,
                        clipType: clipType,
                        text: text
                    )
                    state.setBadge(result)
                    badgeFinished.signal()
                }
            }
        }

        guard loadFinished.wait(timeout: .now() + Self.loadBudget) == .success else {
            // Timeout termination abandons the tracking thread; the script
            // itself cannot be killed with public JSC API.
            return .failure(.timedOut)
        }
        guard let loadResult = state.loadResult() else {
            return .failure(.scriptException("Extension load returned no result"))
        }
        if case .failure(let error) = loadResult {
            return .failure(error)
        }

        startBadge.signal()
        guard badgeFinished.wait(timeout: .now() + Self.badgeBudget) == .success else {
            // Timeout termination abandons the tracking thread; the script
            // itself cannot be killed with public JSC API.
            return .failure(.timedOut)
        }
        return state.badgeResult()
            ?? .failure(.scriptException("Extension badge returned no result"))
    }

    private func startWorker(named suffix: String, operation: @escaping () -> Void) {
        let worker = Thread(block: operation)
        worker.name = "com.alvst.pesty-alvie.\(suffix)"
        worker.qualityOfService = .utility
        worker.start()
    }

    private func syncOnQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return operation()
        }
        return queue.sync(execute: operation)
    }

    private static func load(source: String) -> Result<LoadedScript, ExtensionError> {
        guard let virtualMachine = JSVirtualMachine(),
              let context = JSContext(virtualMachine: virtualMachine) else {
            return .failure(.scriptException("Unable to create JavaScript context"))
        }

        let capture = RegistrationCapture()
        let pesty = JSValue(newObjectIn: context)
        let register: @convention(block) (JSValue) -> Void = { value in
            capture.calls += 1
            if capture.value == nil {
                capture.value = value
            }
        }
        pesty?.setObject(register, forKeyedSubscript: "register" as NSString)
        context.setObject(pesty, forKeyedSubscript: "pesty" as NSString)

        var exceptionMessage: String?
        context.exceptionHandler = { _, exception in
            exceptionMessage = boundedExceptionMessage(exception)
        }
        context.evaluateScript(source)
        if let exceptionMessage {
            capture.value = nil
            return .failure(.scriptException(exceptionMessage))
        }
        guard capture.calls > 0 else {
            return .failure(.noRegisterCall)
        }
        guard capture.calls == 1 else {
            capture.value = nil
            return .failure(.duplicateRegisterCall)
        }
        guard let registration = capture.value else {
            return .failure(.invalidManifest("register requires an object"))
        }
        capture.value = nil

        switch manifest(from: registration) {
        case .failure(let error):
            return .failure(error)
        case .success(let manifest):
            guard let badge = registration.forProperty("badge"),
                  badge.isObject,
                  JSObjectIsFunction(context.jsGlobalContextRef, badge.jsValueRef) else {
                return .failure(.badgeNotAFunction)
            }
            context.exceptionHandler = nil
            return .success(
                LoadedScript(
                    virtualMachine: virtualMachine,
                    context: context,
                    manifest: manifest,
                    badge: badge
                )
            )
        }
    }

    private static func manifest(
        from registration: JSValue
    ) -> Result<ExtensionManifest, ExtensionError> {
        guard let id = stringProperty("id", in: registration) else {
            return .failure(.invalidManifest("id must be a string"))
        }
        guard let name = stringProperty("name", in: registration) else {
            return .failure(.invalidManifest("name must be a string"))
        }
        guard let version = stringProperty("version", in: registration) else {
            return .failure(.invalidManifest("version must be a string"))
        }
        guard let apiValue = registration.forProperty("api"), apiValue.isNumber else {
            return .failure(.invalidManifest("api must be an integer"))
        }
        let apiDouble = apiValue.toDouble()
        guard apiDouble.isFinite, apiDouble.rounded() == apiDouble,
              apiDouble >= Double(Int.min), apiDouble <= Double(Int.max) else {
            return .failure(.invalidManifest("api must be an integer"))
        }

        let manifest = ExtensionManifest(
            id: id,
            name: name,
            version: version,
            api: Int(apiDouble)
        )
        if let error = manifest.validationError() {
            return .failure(error)
        }
        return .success(manifest)
    }

    private static func stringProperty(_ name: String, in value: JSValue) -> String? {
        guard let property = value.forProperty(name), property.isString else {
            return nil
        }
        return property.toString()
    }

    private static func callBadge(
        _ loaded: LoadedScript,
        clipType: String,
        text: String
    ) -> Result<String?, ExtensionError> {
        let clip = JSValue(newObjectIn: loaded.context)
        clip?.setObject(clipType, forKeyedSubscript: "type" as NSString)
        clip?.setObject(text, forKeyedSubscript: "text" as NSString)

        var exceptionMessage: String?
        loaded.context.exceptionHandler = { _, exception in
            exceptionMessage = boundedExceptionMessage(exception)
        }
        let value = loaded.badge.call(withArguments: [clip as Any])
        if let exceptionMessage {
            return .failure(.scriptException(exceptionMessage))
        }
        guard let value, value.isString, let string = value.toString() else {
            return .success(nil)
        }
        return .success(sanitizeBadge(string))
    }

    private static func boundedText(_ text: String) -> String {
        String(
            decoding: text.utf16.prefix(maximumTextUTF16Units),
            as: UTF16.self
        )
    }

    private static func boundedExceptionMessage(_ exception: JSValue?) -> String {
        let message = exception?.toString() ?? "Unknown JavaScript exception"
        return String(message.prefix(maximumExceptionCharacters))
    }

    private static func sanitizeBadge(_ badge: String) -> String? {
        let trimmed = badge.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        let scalars = trimmed.unicodeScalars.filter { !forbidden.contains($0) }
        let sanitized = String(String.UnicodeScalarView(scalars))
        guard !sanitized.isEmpty else { return nil }
        return String(sanitized.prefix(maximumBadgeCharacters))
    }
}

private final class RegistrationCapture {
    var calls = 0
    var value: JSValue?
}

private struct LoadedScript {
    // Keeping the VM explicit guarantees that no extension shares a VM.
    let virtualMachine: JSVirtualMachine
    let context: JSContext
    let manifest: ExtensionManifest
    let badge: JSValue
}

private final class LockedBox<Value> {
    private let lock = NSLock()
    private var value: Value?

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class BadgeWorkerState {
    private let load = LockedBox<Result<ExtensionManifest, ExtensionError>>()
    private let badge = LockedBox<Result<String?, ExtensionError>>()

    func setLoad(_ value: Result<ExtensionManifest, ExtensionError>) {
        load.set(value)
    }

    func loadResult() -> Result<ExtensionManifest, ExtensionError>? {
        load.get()
    }

    func setBadge(_ value: Result<String?, ExtensionError>) {
        badge.set(value)
    }

    func badgeResult() -> Result<String?, ExtensionError>? {
        badge.get()
    }
}
