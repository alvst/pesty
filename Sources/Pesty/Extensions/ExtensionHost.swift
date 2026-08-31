import Foundation
import JavaScriptCore

final class ExtensionHost {
    private static let maximumTextUTF16Units = 65_536
    private static let maximumBadgeCharacters = 24
    private static let maximumLabelCharacters = 16
    private static let maximumTitleCharacters = 60
    private static let maximumSubtitleCharacters = 80
    private static let maximumIconCharacters = 64
    private static let maximumTransformUTF16Units = 1_048_576
    private static let maximumExceptionCharacters = 200
    private static let loadBudget: TimeInterval = 0.5
    private static let cardHookBudget: TimeInterval = 0.1
    private static let transformBudget: TimeInterval = 0.25
    private static let quarantineThreshold = 5
    private static let cardHookNames = ["badge", "subtitle", "icon", "color", "title", "label"]
    private static let allHookNames = [
        "badge", "color", "icon", "label", "subtitle", "title", "transform"
    ]
    private static let supportedClipTypes: Set<String> = [
        "text", "richText", "link", "image", "file", "color"
    ]

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

    func decorationsSync(
        clipType: String,
        text: String,
        extension installedExtension: InstalledExtension,
        settings: [String: ExtensionConfigValue] = [:]
    ) -> Result<CardDecorations, ExtensionError> {
        syncOnQueue {
            decorationsOnQueue(
                clipType: clipType,
                text: text,
                extension: installedExtension,
                settings: settings
            )
        }
    }

    func decorations(
        clipType: String,
        text: String,
        extension installedExtension: InstalledExtension,
        settings: [String: ExtensionConfigValue] = [:],
        completion: @escaping @MainActor @Sendable (CardDecorations) -> Void
    ) {
        queue.async { [self] in
            let value: CardDecorations
            switch decorationsOnQueue(
                clipType: clipType,
                text: text,
                extension: installedExtension,
                settings: settings
            ) {
            case .success(let decorations):
                value = decorations
            case .failure:
                value = CardDecorations()
            }
            DispatchQueue.main.async {
                completion(value)
            }
        }
    }

    func badgeSync(
        clipType: String,
        text: String,
        extension installedExtension: InstalledExtension,
        settings: [String: ExtensionConfigValue] = [:]
    ) -> Result<String?, ExtensionError> {
        decorationsSync(
            clipType: clipType,
            text: text,
            extension: installedExtension,
            settings: settings
        ).map(\.badge)
    }

    func badge(
        clipType: String,
        text: String,
        extension installedExtension: InstalledExtension,
        settings: [String: ExtensionConfigValue] = [:],
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        decorations(
            clipType: clipType,
            text: text,
            extension: installedExtension,
            settings: settings
        ) { decorations in
            completion(decorations.badge)
        }
    }

    func transformSync(
        clipType: String,
        text: String,
        extension installedExtension: InstalledExtension,
        settings: [String: ExtensionConfigValue] = [:]
    ) -> Result<String?, ExtensionError> {
        syncOnQueue {
            transformOnQueue(
                clipType: clipType,
                text: text,
                extension: installedExtension,
                settings: settings
            )
        }
    }

    func transform(
        clipType: String,
        text: String,
        extension installedExtension: InstalledExtension,
        settings: [String: ExtensionConfigValue] = [:],
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        queue.async { [self] in
            let value: String?
            switch transformOnQueue(
                clipType: clipType,
                text: text,
                extension: installedExtension,
                settings: settings
            ) {
            case .success(let transformed):
                value = transformed
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

    private func decorationsOnQueue(
        clipType: String,
        text: String,
        extension installedExtension: InstalledExtension,
        settings: [String: ExtensionConfigValue]
    ) -> Result<CardDecorations, ExtensionError> {
        let id = installedExtension.id
        guard !isQuarantined(id) else {
            return .success(CardDecorations())
        }
        guard installedExtension.manifest.supports(clipType: clipType) else {
            return .success(CardDecorations())
        }
        let cardHooks = Set(Self.cardHookNames)
        guard installedExtension.manifest.effectiveHooks.contains(where: cardHooks.contains) else {
            return .success(CardDecorations())
        }

        let evaluation = runDecorations(
            source: installedExtension.source,
            clipType: clipType,
            text: Self.boundedText(text),
            settings: settings
        )

        record(evaluation, for: id)
        return evaluation.result
    }

    private func transformOnQueue(
        clipType: String,
        text: String,
        extension installedExtension: InstalledExtension,
        settings: [String: ExtensionConfigValue]
    ) -> Result<String?, ExtensionError> {
        let id = installedExtension.id
        guard !isQuarantined(id) else {
            return .success(nil)
        }
        guard installedExtension.manifest.supports(clipType: clipType),
              installedExtension.manifest.effectiveHooks.contains("transform") else {
            return .success(nil)
        }

        let evaluation = runTransform(
            source: installedExtension.source,
            clipType: clipType,
            text: Self.boundedText(text),
            settings: settings
        )

        record(evaluation, for: id)
        return evaluation.result
    }

    private func record<Value>(
        _ evaluation: HostEvaluation<Value>,
        for id: String
    ) {
        var callback: (@MainActor @Sendable (String) -> Void)?
        failureStateLock.lock()

        switch evaluation.result {
        case .success where !evaluation.hadFailure:
            consecutiveFailures.removeValue(forKey: id)
        case .failure(.timedOut):
            consecutiveFailures[id] = Self.quarantineThreshold
            if quarantinedIDs.insert(id).inserted {
                callback = quarantineHandler
            }
        case .success, .failure:
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

    private func runDecorations(
        source: String,
        clipType: String,
        text: String,
        settings: [String: ExtensionConfigValue]
    ) -> HostEvaluation<CardDecorations> {
        let state = CardWorkerState()
        let loadFinished = DispatchSemaphore(value: 0)
        let startHook = DispatchSemaphore(value: 0)
        let hookFinished = DispatchSemaphore(value: 0)

        startWorker(named: "extension-decorations") {
            autoreleasepool {
                switch Self.load(source: source) {
                case .failure(let error):
                    state.setLoad(.failure(error))
                    loadFinished.signal()
                case .success(let loaded):
                    Self.installConfig(settings, in: loaded.context)
                    let hookNames = Self.cardHookNames.filter { loaded.hooks[$0] != nil }
                    state.setLoad(.success(hookNames))
                    loadFinished.signal()

                    for name in hookNames {
                        startHook.wait()
                        guard let hook = loaded.hooks[name] else {
                            state.setHook(
                                HookWorkerResult(
                                    name: name,
                                    result: .failure(
                                        .scriptException("Extension hook was not loaded")
                                    )
                                )
                            )
                            hookFinished.signal()
                            continue
                        }
                        state.setHook(
                            HookWorkerResult(
                                name: name,
                                result: Self.callHook(
                                    hook,
                                    in: loaded,
                                    clipType: clipType,
                                    text: text
                                )
                            )
                        )
                        hookFinished.signal()
                    }
                }
            }
        }

        guard loadFinished.wait(timeout: .now() + Self.loadBudget) == .success else {
            // Timeout termination abandons the tracking thread; the script
            // itself cannot be killed with public JSC API.
            return HostEvaluation(result: .failure(.timedOut), hadFailure: false)
        }
        guard let loadResult = state.loadResult() else {
            return HostEvaluation(
                result: .failure(.scriptException("Extension load returned no result")),
                hadFailure: false
            )
        }
        let hookNames: [String]
        switch loadResult {
        case .failure(let error):
            return HostEvaluation(result: .failure(error), hadFailure: false)
        case .success(let loadedHookNames):
            hookNames = loadedHookNames
        }

        var decorations = CardDecorations()
        var hadFailure = false
        for name in hookNames {
            startHook.signal()
            guard hookFinished.wait(timeout: .now() + Self.cardHookBudget) == .success else {
                // Timeout termination abandons the tracking thread; the script
                // itself cannot be killed with public JSC API.
                return HostEvaluation(result: .failure(.timedOut), hadFailure: false)
            }
            guard let hookResult = state.hookResult(), hookResult.name == name else {
                return HostEvaluation(
                    result: .failure(
                        .scriptException("Extension hook returned no result")
                    ),
                    hadFailure: false
                )
            }

            switch hookResult.result {
            case .success(let rawValue):
                Self.setDecoration(
                    Self.sanitize(rawValue, for: name),
                    for: name,
                    in: &decorations
                )
            case .failure(.scriptException):
                hadFailure = true
                Self.setDecoration(nil, for: name, in: &decorations)
            case .failure(let error):
                return HostEvaluation(result: .failure(error), hadFailure: false)
            }
        }

        return HostEvaluation(result: .success(decorations), hadFailure: hadFailure)
    }

    private func runTransform(
        source: String,
        clipType: String,
        text: String,
        settings: [String: ExtensionConfigValue]
    ) -> HostEvaluation<String?> {
        let state = TransformWorkerState()
        let loadFinished = DispatchSemaphore(value: 0)
        let startTransform = DispatchSemaphore(value: 0)
        let transformFinished = DispatchSemaphore(value: 0)

        startWorker(named: "extension-transform") {
            autoreleasepool {
                switch Self.load(source: source) {
                case .failure(let error):
                    state.setLoad(.failure(error))
                    loadFinished.signal()
                case .success(let loaded):
                    Self.installConfig(settings, in: loaded.context)
                    let transform = loaded.hooks["transform"]
                    state.setLoad(.success(transform != nil))
                    loadFinished.signal()
                    guard let transform else { return }
                    startTransform.wait()
                    state.setTransform(
                        Self.callHook(
                            transform,
                            in: loaded,
                            clipType: clipType,
                            text: text
                        )
                    )
                    transformFinished.signal()
                }
            }
        }

        guard loadFinished.wait(timeout: .now() + Self.loadBudget) == .success else {
            // Timeout termination abandons the tracking thread; the script
            // itself cannot be killed with public JSC API.
            return HostEvaluation(result: .failure(.timedOut), hadFailure: false)
        }
        guard let loadResult = state.loadResult() else {
            return HostEvaluation(
                result: .failure(.scriptException("Extension load returned no result")),
                hadFailure: false
            )
        }
        switch loadResult {
        case .failure(let error):
            return HostEvaluation(result: .failure(error), hadFailure: false)
        case .success(false):
            return HostEvaluation(result: .success(nil), hadFailure: false)
        case .success(true):
            break
        }

        startTransform.signal()
        guard transformFinished.wait(timeout: .now() + Self.transformBudget) == .success else {
            // Timeout termination abandons the tracking thread; the script
            // itself cannot be killed with public JSC API.
            return HostEvaluation(result: .failure(.timedOut), hadFailure: false)
        }
        guard let result = state.transformResult() else {
            return HostEvaluation(
                result: .failure(.scriptException("Extension transform returned no result")),
                hadFailure: false
            )
        }
        switch result {
        case .failure(let error):
            return HostEvaluation(result: .failure(error), hadFailure: false)
        case .success(nil):
            return HostEvaluation(result: .success(nil), hadFailure: false)
        case .success(let value?):
            // Transform output is pasted text, so preserve its content exactly.
            // Only its UTF-16 size is bounded here.
            guard value.utf16.count <= Self.maximumTransformUTF16Units else {
                return HostEvaluation(result: .success(nil), hadFailure: true)
            }
            return HostEvaluation(result: .success(value), hadFailure: false)
        }
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

        switch manifest(from: registration, hooks: []) {
        case .failure(let error):
            return .failure(error)
        case .success(let baseManifest):
            let hooks: [String: JSValue]
            switch hookFunctions(from: registration, context: context) {
            case .failure(let error):
                return .failure(error)
            case .success(let loadedHooks):
                hooks = loadedHooks
            }
            guard !hooks.isEmpty else {
                return .failure(.invalidManifest("at least one hook function is required"))
            }
            let manifest = ExtensionManifest(
                id: baseManifest.id,
                name: baseManifest.name,
                version: baseManifest.version,
                api: baseManifest.api,
                weight: baseManifest.weight,
                types: baseManifest.types,
                hooks: hooks.keys.sorted(),
                config: baseManifest.config
            )
            context.exceptionHandler = nil
            return .success(
                LoadedScript(
                    virtualMachine: virtualMachine,
                    context: context,
                    manifest: manifest,
                    hooks: hooks
                )
            )
        }
    }

    private static func manifest(
        from registration: JSValue,
        hooks: [String]
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

        let weight: Double
        if let weightValue = registration.forProperty("weight"), !weightValue.isUndefined {
            guard weightValue.isNumber else {
                return .failure(.invalidManifest("weight must be a finite number"))
            }
            let rawWeight = weightValue.toDouble()
            guard rawWeight.isFinite else {
                return .failure(.invalidManifest("weight must be a finite number"))
            }
            weight = min(1000, max(-1000, rawWeight))
        } else {
            weight = 0
        }

        let types: [String]?
        if let typesValue = registration.forProperty("types"), !typesValue.isUndefined {
            guard typesValue.isArray, let rawTypes = typesValue.toArray(), !rawTypes.isEmpty else {
                return .failure(.invalidManifest("types must be a non-empty array"))
            }
            var parsedTypes: [String] = []
            for rawType in rawTypes {
                guard let type = rawType as? String else {
                    return .failure(.invalidManifest("types entries must be strings"))
                }
                guard supportedClipTypes.contains(type) else {
                    return .failure(.invalidManifest("unknown clip type \(type)"))
                }
                if !parsedTypes.contains(type) {
                    parsedTypes.append(type)
                }
            }
            types = parsedTypes
        } else {
            types = nil
        }

        let config: [ExtensionConfigField]
        switch configFields(from: registration) {
        case .failure(let error):
            return .failure(error)
        case .success(let fields):
            config = fields
        }

        let manifest = ExtensionManifest(
            id: id,
            name: name,
            version: version,
            api: Int(apiDouble),
            weight: weight,
            types: types,
            hooks: hooks,
            config: config
        )
        if let error = manifest.validationError() {
            return .failure(error)
        }
        return .success(manifest)
    }

    private static func configFields(
        from registration: JSValue
    ) -> Result<[ExtensionConfigField], ExtensionError> {
        guard let configValue = registration.forProperty("config"),
              !configValue.isUndefined else {
            return .success([])
        }
        guard configValue.isArray, let rawFields = configValue.toArray() else {
            return .failure(.invalidManifest("config must be an array"))
        }
        guard rawFields.count <= 8 else {
            return .failure(.invalidManifest("config must contain at most 8 fields"))
        }

        var fields: [ExtensionConfigField] = []
        var keys: Set<String> = []
        for index in rawFields.indices {
            let prefix = "config[\(index)]"
            guard let value = configValue.objectAtIndexedSubscript(index),
                  value.isObject, !value.isArray, !value.isNull else {
                return .failure(.invalidManifest("\(prefix) must be an object"))
            }
            guard let key = stringProperty("key", in: value) else {
                return .failure(.invalidManifest("\(prefix).key must be a string"))
            }
            guard let rawType = stringProperty("type", in: value),
                  let type = ExtensionConfigFieldType(rawValue: rawType) else {
                return .failure(
                    .invalidManifest(
                        "\(prefix).type must be boolean, number, string, or choice"
                    )
                )
            }
            guard let rawLabel = stringProperty("label", in: value) else {
                return .failure(.invalidManifest("\(prefix).label must be a string"))
            }
            let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)

            let optionsValue = value.forProperty("options")
            let hasOptions = optionsValue != nil && optionsValue?.isUndefined == false
            let options: [String]?
            if type == .choice {
                guard hasOptions, let optionsValue, optionsValue.isArray,
                      let rawOptions = optionsValue.toArray() else {
                    return .failure(
                        .invalidManifest(
                            "\(prefix).options must contain 2-10 strings for a choice field"
                        )
                    )
                }
                var parsedOptions: [String] = []
                for optionIndex in rawOptions.indices {
                    guard let optionValue = optionsValue.objectAtIndexedSubscript(optionIndex),
                          optionValue.isString, let option = optionValue.toString() else {
                        return .failure(
                            .invalidManifest("\(prefix).options entries must be strings")
                        )
                    }
                    parsedOptions.append(option)
                }
                options = parsedOptions
            } else {
                guard !hasOptions else {
                    return .failure(
                        .invalidManifest("\(prefix).options is only allowed for choice fields")
                    )
                }
                options = nil
            }

            guard let rawDefault = value.forProperty("default"), !rawDefault.isUndefined else {
                return .failure(.invalidManifest("\(prefix).default is required"))
            }
            let defaultValue: ExtensionConfigValue
            switch type {
            case .boolean:
                guard rawDefault.isBoolean else {
                    return .failure(.invalidManifest("\(prefix).default must be a boolean"))
                }
                defaultValue = .boolean(rawDefault.toBool())
            case .number:
                guard rawDefault.isNumber else {
                    return .failure(.invalidManifest("\(prefix).default must be a number"))
                }
                let number = rawDefault.toDouble()
                guard number.isFinite else {
                    return .failure(
                        .invalidManifest("\(prefix).default must be a finite number")
                    )
                }
                defaultValue = .number(number)
            case .string, .choice:
                guard rawDefault.isString, let string = rawDefault.toString() else {
                    let expected = type == .choice ? "a string for a choice field" : "a string"
                    return .failure(.invalidManifest("\(prefix).default must be \(expected)"))
                }
                defaultValue = .string(string)
            }

            let field = ExtensionConfigField(
                key: key,
                type: type,
                label: label,
                defaultValue: defaultValue,
                options: options
            )
            if let message = field.validationMessage(at: index) {
                return .failure(.invalidManifest(message))
            }
            guard keys.insert(key).inserted else {
                return .failure(.invalidManifest("config keys must be unique"))
            }
            fields.append(field)
        }
        return .success(fields)
    }

    private static func hookFunctions(
        from registration: JSValue,
        context: JSContext
    ) -> Result<[String: JSValue], ExtensionError> {
        var hooks: [String: JSValue] = [:]
        for name in allHookNames {
            guard let value = registration.forProperty(name), !value.isUndefined else {
                continue
            }
            // JSObjectIsFunction has undefined behavior for primitive values.
            guard value.isObject,
                  JSObjectIsFunction(context.jsGlobalContextRef, value.jsValueRef) else {
                return .failure(.hookNotAFunction(name))
            }
            hooks[name] = value
        }
        return .success(hooks)
    }

    private static func stringProperty(_ name: String, in value: JSValue) -> String? {
        guard let property = value.forProperty(name), property.isString else {
            return nil
        }
        return property.toString()
    }

    private static func installConfig(
        _ settings: [String: ExtensionConfigValue],
        in context: JSContext
    ) {
        let config = JSValue(newObjectIn: context)
        for (key, value) in settings {
            switch value {
            case .boolean(let boolean):
                config?.setObject(boolean, forKeyedSubscript: key as NSString)
            case .number(let number):
                config?.setObject(number, forKeyedSubscript: key as NSString)
            case .string(let string):
                config?.setObject(string, forKeyedSubscript: key as NSString)
            }
        }
        context.setObject(config, forKeyedSubscript: "config" as NSString)
    }

    private static func callHook(
        _ hook: JSValue,
        in loaded: LoadedScript,
        clipType: String,
        text: String
    ) -> Result<String?, ExtensionError> {
        let clip = JSValue(newObjectIn: loaded.context)
        clip?.setObject(clipType, forKeyedSubscript: "type" as NSString)
        clip?.setObject(text, forKeyedSubscript: "text" as NSString)

        var exceptionMessage: String?
        loaded.context.exception = nil
        loaded.context.exceptionHandler = { _, exception in
            exceptionMessage = boundedExceptionMessage(exception)
        }
        let value = hook.call(withArguments: [clip as Any])
        loaded.context.exceptionHandler = nil
        if let exceptionMessage {
            loaded.context.exception = nil
            return .failure(.scriptException(exceptionMessage))
        }
        guard let value, value.isString, let string = value.toString() else {
            return .success(nil)
        }
        return .success(string)
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

    private static func sanitize(_ value: String?, for hook: String) -> String? {
        guard let value else { return nil }
        switch hook {
        case "badge":
            return sanitizeDisplayValue(value, maximumCharacters: maximumBadgeCharacters)
        case "label":
            return sanitizeDisplayValue(value, maximumCharacters: maximumLabelCharacters)
        case "title":
            return sanitizeDisplayValue(value, maximumCharacters: maximumTitleCharacters)
        case "subtitle":
            return sanitizeDisplayValue(value, maximumCharacters: maximumSubtitleCharacters)
        case "icon":
            return sanitizeIcon(value)
        case "color":
            return sanitizeColor(value)
        default:
            return nil
        }
    }

    private static func sanitizeDisplayValue(
        _ value: String,
        maximumCharacters: Int
    ) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        let scalars = trimmed.unicodeScalars.filter { !forbidden.contains($0) }
        let sanitized = String(String.UnicodeScalarView(scalars))
        guard !sanitized.isEmpty else { return nil }
        return String(sanitized.prefix(maximumCharacters))
    }

    private static func sanitizeIcon(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...maximumIconCharacters).contains(trimmed.count) else { return nil }
        let isValid = trimmed.unicodeScalars.allSatisfy { scalar in
            (97...122).contains(scalar.value)
                || (48...57).contains(scalar.value)
                || scalar.value == 46
        }
        return isValid ? trimmed : nil
    }

    private static func sanitizeColor(_ value: String) -> String? {
        let bytes = Array(value.utf8)
        guard bytes.count == 7, bytes[0] == 35 else { return nil }
        let isHex = bytes.dropFirst().allSatisfy { byte in
            (48...57).contains(byte)
                || (65...70).contains(byte)
                || (97...102).contains(byte)
        }
        return isHex ? value.uppercased() : nil
    }

    private static func setDecoration(
        _ value: String?,
        for hook: String,
        in decorations: inout CardDecorations
    ) {
        switch hook {
        case "badge": decorations.badge = value
        case "subtitle": decorations.subtitle = value
        case "icon": decorations.icon = value
        case "color": decorations.color = value
        case "title": decorations.title = value
        case "label": decorations.label = value
        default: break
        }
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
    let hooks: [String: JSValue]
}

private struct HostEvaluation<Value> {
    let result: Result<Value, ExtensionError>
    let hadFailure: Bool
}

private struct HookWorkerResult {
    let name: String
    let result: Result<String?, ExtensionError>
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

private final class CardWorkerState {
    private let load = LockedBox<Result<[String], ExtensionError>>()
    private let hook = LockedBox<HookWorkerResult>()

    func setLoad(_ value: Result<[String], ExtensionError>) {
        load.set(value)
    }

    func loadResult() -> Result<[String], ExtensionError>? {
        load.get()
    }

    func setHook(_ value: HookWorkerResult) {
        hook.set(value)
    }

    func hookResult() -> HookWorkerResult? {
        hook.get()
    }
}

private final class TransformWorkerState {
    private let load = LockedBox<Result<Bool, ExtensionError>>()
    private let transform = LockedBox<Result<String?, ExtensionError>>()

    func setLoad(_ value: Result<Bool, ExtensionError>) {
        load.set(value)
    }

    func loadResult() -> Result<Bool, ExtensionError>? {
        load.get()
    }

    func setTransform(_ value: Result<String?, ExtensionError>) {
        transform.set(value)
    }

    func transformResult() -> Result<String?, ExtensionError>? {
        transform.get()
    }
}
