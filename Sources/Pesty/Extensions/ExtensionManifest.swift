import Foundation

struct ExtensionManifest: Codable, Equatable {
    let id: String
    let name: String
    let version: String
    let api: Int
    let weight: Double
    let types: [String]?
    let hooks: [String]

    init(
        id: String,
        name: String,
        version: String,
        api: Int,
        weight: Double = 0,
        types: [String]? = nil,
        hooks: [String] = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.api = api
        self.weight = weight
        self.types = types
        self.hooks = hooks
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
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case version
        case api
        case weight
        case types
        case hooks
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

    var id: String { manifest.id }
}
