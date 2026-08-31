import Foundation

enum ExtensionConfigValue: Codable, Equatable, Sendable {
    case boolean(Bool)
    case number(Double)
    case string(String)

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case boolean = "b"
        case number = "n"
        case string = "s"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keys = CodingKeys.allCases.filter(container.contains)
        guard keys.count == 1, let key = keys.first else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Extension config values require exactly one value"
                )
            )
        }

        switch key {
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: key))
        case .number:
            let value = try container.decode(Double.self, forKey: key)
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "Extension config numbers must be finite"
                )
            }
            self = .number(value)
        case .string:
            self = .string(try container.decode(String.self, forKey: key))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .boolean(let value):
            try container.encode(value, forKey: .boolean)
        case .number(let value):
            try container.encode(value, forKey: .number)
        case .string(let value):
            try container.encode(value, forKey: .string)
        }
    }
}

enum ExtensionConfigFieldType: String, Codable, Equatable, Sendable {
    case boolean
    case number
    case string
    case choice
}

struct ExtensionConfigField: Codable, Equatable, Identifiable, Sendable {
    static let maximumStringCharacters = 200

    let key: String
    let type: ExtensionConfigFieldType
    let label: String
    let defaultValue: ExtensionConfigValue
    let options: [String]?

    var id: String { key }

    init(
        key: String,
        type: ExtensionConfigFieldType,
        label: String,
        defaultValue: ExtensionConfigValue,
        options: [String]? = nil
    ) {
        self.key = key
        self.type = type
        self.label = label
        self.defaultValue = defaultValue
        self.options = options
    }

    func accepts(_ value: ExtensionConfigValue) -> Bool {
        switch (type, value) {
        case (.boolean, .boolean):
            true
        case (.number, .number(let value)):
            value.isFinite
        case (.string, .string(let value)):
            value.count <= Self.maximumStringCharacters
        case (.choice, .string(let value)):
            options?.contains(value) == true
        default:
            false
        }
    }

    func validationMessage(at index: Int) -> String? {
        let prefix = "config[\(index)]"
        let keyIsValid = (1...32).contains(key.count) && key.unicodeScalars.allSatisfy {
            (97...122).contains($0.value)
                || (48...57).contains($0.value)
                || $0.value == 95
                || $0.value == 45
        }
        guard keyIsValid else {
            return "\(prefix).key must be 1-32 lowercase ASCII letters, digits, underscores, or hyphens"
        }

        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, trimmedLabel.count <= 40 else {
            return "\(prefix).label must be non-empty after trimming and at most 40 characters"
        }

        switch type {
        case .boolean:
            guard options == nil else {
                return "\(prefix).options is only allowed for choice fields"
            }
            guard case .boolean = defaultValue else {
                return "\(prefix).default must be a boolean"
            }
        case .number:
            guard options == nil else {
                return "\(prefix).options is only allowed for choice fields"
            }
            guard case .number(let value) = defaultValue else {
                return "\(prefix).default must be a number"
            }
            guard value.isFinite else {
                return "\(prefix).default must be a finite number"
            }
        case .string:
            guard options == nil else {
                return "\(prefix).options is only allowed for choice fields"
            }
            guard case .string(let value) = defaultValue else {
                return "\(prefix).default must be a string"
            }
            guard value.count <= Self.maximumStringCharacters else {
                return "\(prefix).default must be at most 200 characters"
            }
        case .choice:
            guard let options, (2...10).contains(options.count) else {
                return "\(prefix).options must contain 2-10 strings for a choice field"
            }
            guard options.allSatisfy({ !$0.isEmpty && $0.count <= 30 }) else {
                return "\(prefix).options entries must be non-empty strings of at most 30 characters"
            }
            guard Set(options).count == options.count else {
                return "\(prefix).options entries must be unique"
            }
            guard case .string(let value) = defaultValue else {
                return "\(prefix).default must be a string for a choice field"
            }
            guard options.contains(value) else {
                return "\(prefix).default must be one of the choice options"
            }
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case type
        case label
        case defaultValue = "default"
        case options
    }
}

enum ExtensionMenuVerb: String, Codable, Equatable, Sendable {
    case copyTransformed
    case revealInFinder
}

struct ExtensionMenuItem: Codable, Equatable, Sendable {
    let title: String
    let verb: ExtensionMenuVerb

    static func sanitizedTitle(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        let scalars = trimmed.unicodeScalars.filter { !forbidden.contains($0) }
        let sanitized = String(String.UnicodeScalarView(scalars))
        guard (1...30).contains(sanitized.count) else { return nil }
        return sanitized
    }

    func validationMessage(at index: Int) -> String? {
        guard Self.sanitizedTitle(title) != nil else {
            return "menuItems[\(index)].title must contain 1-30 display characters"
        }
        return nil
    }
}

struct ExtensionManifest: Codable, Equatable {
    let id: String
    let name: String
    let version: String
    let api: Int
    let weight: Double
    let types: [String]?
    let hooks: [String]
    let config: [ExtensionConfigField]
    let menuItems: [ExtensionMenuItem]

    init(
        id: String,
        name: String,
        version: String,
        api: Int,
        weight: Double = 0,
        types: [String]? = nil,
        hooks: [String] = [],
        config: [ExtensionConfigField] = [],
        menuItems: [ExtensionMenuItem] = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.api = api
        self.weight = weight
        self.types = types
        self.hooks = hooks
        self.config = config
        self.menuItems = menuItems
    }

    var effectiveHooks: [String] {
        hooks.isEmpty ? ["badge"] : hooks
    }

    func supports(clipType: String) -> Bool {
        types?.contains(clipType) ?? true
    }

    func validationError() -> ExtensionError? {
        if api != 1 {
            return .unsupportedAPI(api)
        }

        let idScalars = id.unicodeScalars
        let containsLetter = idScalars.contains {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }
        let allowedID = idScalars.allSatisfy {
            (48...57).contains($0.value)
                || (65...90).contains($0.value)
                || (97...122).contains($0.value)
                || $0.value == 45
                || $0.value == 46
        }
        guard (3...64).contains(id.count), allowedID, containsLetter else {
            return .invalidManifest("id must be 3-64 ASCII letters, digits, dots, or hyphens and contain a letter")
        }

        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 40 else {
            return .invalidManifest("name must be non-empty and at most 40 characters")
        }
        guard !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              version.count <= 16 else {
            return .invalidManifest("version must be non-empty and at most 16 characters")
        }
        guard config.count <= 8 else {
            return .invalidManifest("config must contain at most 8 fields")
        }
        var configKeys: Set<String> = []
        for (index, field) in config.enumerated() {
            if let message = field.validationMessage(at: index) {
                return .invalidManifest(message)
            }
            guard configKeys.insert(field.key).inserted else {
                return .invalidManifest("config keys must be unique")
            }
        }
        guard menuItems.count <= 3 else {
            return .invalidManifest("menuItems must contain at most 3 entries")
        }
        for (index, menuItem) in menuItems.enumerated() {
            if let message = menuItem.validationMessage(at: index) {
                return .invalidManifest(message)
            }
        }
        return nil
    }

    func menuHookValidationError() -> ExtensionError? {
        guard menuItems.contains(where: { $0.verb == .copyTransformed }),
              !hooks.contains("transform") else { return nil }
        return .invalidManifest("copyTransformed menu items require a transform hook")
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case version
        case api
        case weight
        case types
        case hooks
        case config
        case menuItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        api = try container.decode(Int.self, forKey: .api)
        weight = try container.decodeIfPresent(Double.self, forKey: .weight) ?? 0
        types = try container.decodeIfPresent([String].self, forKey: .types)
        hooks = try container.decodeIfPresent([String].self, forKey: .hooks) ?? []
        config = try container.decodeIfPresent([ExtensionConfigField].self, forKey: .config) ?? []
        menuItems = try container.decodeIfPresent(
            [ExtensionMenuItem].self,
            forKey: .menuItems
        ) ?? []
    }
}

struct CardDecorations: Equatable {
    var badge: String?
    var subtitle: String?
    var icon: String?
    var color: String?
    var title: String?
    var label: String?

    init(
        badge: String? = nil,
        subtitle: String? = nil,
        icon: String? = nil,
        color: String? = nil,
        title: String? = nil,
        label: String? = nil
    ) {
        self.badge = badge
        self.subtitle = subtitle
        self.icon = icon
        self.color = color
        self.title = title
        self.label = label
    }
}

enum ExtensionError: Error, Equatable {
    case noRegisterCall
    case duplicateRegisterCall
    case invalidManifest(String)
    case unsupportedAPI(Int)
    case hookNotAFunction(String)
    case scriptException(String)
    case timedOut

    var userDescription: String {
        switch self {
        case .noRegisterCall:
            "The script did not call pesty.register."
        case .duplicateRegisterCall:
            "The script called pesty.register more than once."
        case .invalidManifest(let message):
            "The extension manifest is invalid: \(message)"
        case .unsupportedAPI(let api):
            "Extension API \(api) is not supported."
        case .hookNotAFunction(let hook):
            "The extension hook \(hook) must be a function."
        case .scriptException(let message):
            "The script failed: \(message)"
        case .timedOut:
            "The script exceeded the execution time limit."
        }
    }
}

struct InstalledExtension: Codable, Equatable, Identifiable {
    var manifest: ExtensionManifest
    var source: String
    var enabled: Bool
    var isBundled: Bool
    var installedAt: Date
    var autoDisabledAt: Date? = nil
    var settings: [String: ExtensionConfigValue] = [:]

    var id: String { manifest.id }

    init(
        manifest: ExtensionManifest,
        source: String,
        enabled: Bool,
        isBundled: Bool,
        installedAt: Date,
        autoDisabledAt: Date? = nil,
        settings: [String: ExtensionConfigValue] = [:]
    ) {
        self.manifest = manifest
        self.source = source
        self.enabled = enabled
        self.isBundled = isBundled
        self.installedAt = installedAt
        self.autoDisabledAt = autoDisabledAt
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey {
        case manifest
        case source
        case enabled
        case isBundled
        case installedAt
        case autoDisabledAt
        case settings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manifest = try container.decode(ExtensionManifest.self, forKey: .manifest)
        source = try container.decode(String.self, forKey: .source)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        isBundled = try container.decode(Bool.self, forKey: .isBundled)
        installedAt = try container.decode(Date.self, forKey: .installedAt)
        autoDisabledAt = try container.decodeIfPresent(Date.self, forKey: .autoDisabledAt)
        settings = try container.decodeIfPresent(
            [String: ExtensionConfigValue].self,
            forKey: .settings
        ) ?? [:]
    }
}
