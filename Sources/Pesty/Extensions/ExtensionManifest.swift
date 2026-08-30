import Foundation

struct ExtensionManifest: Codable, Equatable {
    let id: String
    let name: String
    let version: String
    let api: Int

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
}

enum ExtensionError: Error, Equatable {
    case noRegisterCall
    case duplicateRegisterCall
    case invalidManifest(String)
    case unsupportedAPI(Int)
    case badgeNotAFunction
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
        case .badgeNotAFunction:
            "The extension must provide a badge function."
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
