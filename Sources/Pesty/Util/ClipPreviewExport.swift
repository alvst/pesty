import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A save-ready representation of a preview. Preparing or exporting it never
/// changes the clip, the clipboard, or Pesty's managed image files.
@MainActor
struct ClipPreviewExport {
    let suggestedFileName: String
    let contentType: UTType?
    private let payload: Payload

    private enum Payload {
        case data(Data)
        case file(URL, isDirectory: Bool)
    }

    static func prepare(for item: ClipItem, store: ClipboardStore) throws -> [ClipPreviewExport] {
        switch item.type {
        case .file:
            guard !item.fileURLs.isEmpty else { throw ExportError.missingContent }
            return try item.fileURLs.map { value in
                guard let source = URL(string: value), source.isFileURL else {
                    throw ExportError.invalidFileURL
                }
                do {
                    return try originalFile(at: source)
                } catch {
                    // Image-file clips can remain previewable after their
                    // original screenshot moves or becomes sandbox-inaccessible.
                    if item.fileURLs.count == 1, item.imageFileName != nil {
                        return try cachedImage(for: item, store: store,
                                               title: source.deletingPathExtension().lastPathComponent)
                    }
                    throw ExportError.unreadableFile(source.lastPathComponent)
                }
            }
        case .image:
            return [try cachedImage(for: item, store: store, title: item.displayTitle)]
        case .richText:
            if let rtf = item.rtfData, !rtf.isEmpty {
                return [dataExport(rtf, title: item.displayTitle, type: .rtf)]
            }
            if let html = item.htmlData, !html.isEmpty {
                return [dataExport(html, title: item.displayTitle, type: .html)]
            }
            fallthrough
        case .text, .link, .color:
            guard let text = item.plainText else { throw ExportError.missingContent }
            return [dataExport(Data(text.utf8), title: item.displayTitle, type: .plainText)]
        }
    }

    func write(to destination: URL) throws {
        guard destination.isFileURL else { throw ExportError.invalidFileURL }
        do {
            switch payload {
            case let .data(data):
                try data.write(to: destination, options: .atomic)
            case let .file(source, isDirectory):
                let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
                let destinationPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
                // Selecting the original in Save is harmless and should not
                // replace it, alter its metadata, or copy a folder into itself.
                if sourcePath == destinationPath { return }
                guard !sourcePath.hasPrefix(destinationPath + "/"),
                      !isDirectory || !destinationPath.hasPrefix(sourcePath + "/") else {
                    throw ExportError.overlappingFolder
                }

                let manager = FileManager.default
                let stagingDirectory = try manager.url(for: .itemReplacementDirectory,
                                                       in: .userDomainMask,
                                                       appropriateFor: destination,
                                                       create: true)
                defer { try? manager.removeItem(at: stagingDirectory) }
                let staged = stagingDirectory.appendingPathComponent(source.lastPathComponent)
                try manager.copyItem(at: source, to: staged)
                if manager.fileExists(atPath: destination.path) {
                    _ = try manager.replaceItemAt(destination, withItemAt: staged)
                } else {
                    try manager.moveItem(at: staged, to: destination)
                }
            }
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.writeFailed(destination.lastPathComponent, error.localizedDescription)
        }
    }

    private static func originalFile(at source: URL) throws -> ClipPreviewExport {
        let properties = try source.resolvingSymlinksInPath()
            .resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        let isDirectory = properties.isDirectory == true
        guard isDirectory || properties.isRegularFile == true,
              FileManager.default.isReadableFile(atPath: source.path) else {
            throw ExportError.unreadableFile(source.lastPathComponent)
        }
        if !isDirectory {
            // Confirm access before displaying Save, so cached screenshot
            // pixels can be used when a sandbox denies the original file.
            let handle = try FileHandle(forReadingFrom: source)
            try handle.close()
        }
        return ClipPreviewExport(suggestedFileName: source.lastPathComponent,
                                 contentType: isDirectory ? nil : UTType(filenameExtension: source.pathExtension),
                                 payload: .file(source, isDirectory: isDirectory))
    }

    private static func cachedImage(for item: ClipItem, store: ClipboardStore,
                                    title: String) throws -> ClipPreviewExport {
        guard let source = store.imageURL(for: item),
              let data = try? Data(contentsOf: source),
              let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(imageSource) > 0,
              let identifier = CGImageSourceGetType(imageSource),
              let type = UTType(identifier as String),
              type.conforms(to: .image) else { throw ExportError.unavailableImage }
        // Managed filenames always end in .png, but imported image-file
        // snapshots may contain another format. Preserve bytes and name the
        // exported file using its actual format.
        return dataExport(data, title: title, type: type)
    }

    private static func dataExport(_ data: Data, title: String, type: UTType) -> ClipPreviewExport {
        let fileExtension = type == .plainText ? "txt" : (type.preferredFilenameExtension ?? "data")
        var name = title
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        let existingExtension = (name as NSString).pathExtension
        if let existingType = UTType(filenameExtension: existingExtension), existingType == type {
            name = (name as NSString).deletingPathExtension
        }
        name = String(name.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        // Filesystems limit names in bytes, while a single visible character
        // can contain several multi-byte scalars (emoji in particular).
        while name.utf8.count > 200 { name.removeLast() }
        if name.isEmpty { name = "Clip" }
        return ClipPreviewExport(suggestedFileName: "\(name).\(fileExtension)",
                                 contentType: type, payload: .data(data))
    }

    private enum ExportError: LocalizedError {
        case missingContent
        case invalidFileURL
        case unreadableFile(String)
        case unavailableImage
        case overlappingFolder
        case writeFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .missingContent:
                return "This clip has no content to save."
            case .invalidFileURL:
                return "This clip does not contain a valid local file."
            case let .unreadableFile(name):
                return "“\(name)” is no longer available or cannot be read."
            case .unavailableImage:
                return "The original image is no longer available to save."
            case .overlappingFolder:
                return "Choose a location outside the original folder to save a copy."
            case let .writeFailed(name, reason):
                return "“\(name)” could not be saved. \(reason)"
            }
        }
    }
}
