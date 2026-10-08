import AppKit
import QuickLookThumbnailing

/// Quick Look thumbnails for file clips, so a card shows what the file *is*
/// rather than which application opens it — a folder of models or PDFs is
/// otherwise a wall of identical type icons.
@MainActor
final class FileThumbnailProvider {
    static let shared = FileThumbnailProvider()

    private var cache: [String: NSImage] = [:]
    /// Paths whose generation already failed, so a file the system has no
    /// preview for isn't retried on every card render.
    private var unavailable: Set<String> = []

    private init() {}

    func cached(for url: URL) -> NSImage? { cache[url.path] }

    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        let key = url.path
        if let cached = cache[key] { return cached }
        guard !unavailable.contains(key) else { return nil }

        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: size,
                                                   scale: scale,
                                                   representationTypes: .thumbnail)
        let representation: QLThumbnailRepresentation? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation)
            }
        }

        guard let representation else {
            unavailable.insert(key)
            return nil
        }
        let image = representation.nsImage
        cache[key] = image
        return image
    }
}
