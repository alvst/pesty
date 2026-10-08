import Foundation

/// Keeps local files encrypted and unavailable until the device's first unlock,
/// then allows CloudKit and app extensions to persist changes on later locks.
enum LocalFileProtection {
    static let writingOptions: Data.WritingOptions = [
        .atomic, .completeFileProtectionUntilFirstUserAuthentication
    ]

    private static let migrationLock = NSLock()
    private static var migratedDirectories = Set<String>()

    static func prepareDirectory(at url: URL) throws {
        try requireFileURL(url)
        let manager = FileManager.default
        do {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw ProtectionError.unexpectedItem(url)
            }
        } catch where isMissingFile(error) {
            try manager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: directoryAttributes
            )
        }
        // An existing directory may still carry the previous complete
        // protection policy, which would block background atomic writes.
        try manager.setAttributes(directoryAttributes, ofItemAtPath: url.path)
    }

    static func prepareFile(at url: URL) throws {
        try requireFileURL(url)
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            // attributesOfItem inspects the link itself, so this never applies
            // permissions or protection settings to a symbolic-link target.
            throw ProtectionError.unexpectedItem(url)
        }
        try manager.setAttributes(fileAttributes, ofItemAtPath: url.path)
    }

    /// Upgrades metadata for files written by older builds without loading or
    /// rewriting their contents. Failed attempts remain retryable after unlock.
    static func prepareExistingFiles(in directory: URL) throws {
        try requireFileURL(directory)
        let key = directory.standardizedFileURL.path
        migrationLock.lock()
        defer { migrationLock.unlock() }
        guard !migratedDirectories.contains(key) else { return }

        try prepareDirectory(at: directory)
        let manager = FileManager.default
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw ProtectionError.cannotEnumerate(directory)
        }

        for case let url as URL in enumerator {
            do {
                let attributes = try manager.attributesOfItem(atPath: url.path)
                switch attributes[.type] as? FileAttributeType {
                case .typeSymbolicLink:
                    enumerator.skipDescendants()
                case .typeDirectory:
                    try manager.setAttributes(directoryAttributes, ofItemAtPath: url.path)
                case .typeRegular:
                    try manager.setAttributes(fileAttributes, ofItemAtPath: url.path)
                default:
                    break
                }
            } catch where isMissingFile(error) {
                // Another process may finish an atomic write or remove a
                // temporary cache file while migration enumerates it.
                continue
            }
        }
        if let enumerationError { throw enumerationError }
        migratedDirectories.insert(key)
    }

    private static var directoryAttributes: [FileAttributeKey: Any] {
        [.posixPermissions: 0o700,
         .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    }

    private static var fileAttributes: [FileAttributeKey: Any] {
        [.posixPermissions: 0o600,
         .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    }

    private static func requireFileURL(_ url: URL) throws {
        guard url.isFileURL else { throw ProtectionError.unexpectedItem(url) }
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
    }

    private enum ProtectionError: LocalizedError {
        case unexpectedItem(URL)
        case cannotEnumerate(URL)

        var errorDescription: String? {
            switch self {
            case .unexpectedItem(let url):
                "“\(url.lastPathComponent)” is not a supported local file or folder."
            case .cannotEnumerate(let url):
                "The files in “\(url.lastPathComponent)” could not be prepared for background access."
            }
        }
    }
}
