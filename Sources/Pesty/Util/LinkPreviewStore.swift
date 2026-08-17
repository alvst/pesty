import AppKit
import Foundation
import Observation

struct LinkPreview {
    var title: String?
    var icon: NSImage?
    var image: NSImage?
}

/// Ephemeral so nothing the previews fetch — cookies, cache — is ever written
/// to disk; the whole point of the opt-in is that Pesty leaves no trail.
private let previewSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    return URLSession(configuration: configuration)
}()

@Observable
@MainActor
final class LinkPreviewStore {
    static let shared = LinkPreviewStore()

    /// Bail out of a download once it exceeds these; a preview is never worth
    /// pulling an unbounded body.
    private static let maxPageBytes = 2 * 1024 * 1024
    private static let maxImageBytes = 5 * 1024 * 1024

    // Keyed by the full URL string, not the host — two different pages on the
    // same site have different titles and thumbnails.
    private var previews: [String: LinkPreview] = [:]
    private var inFlight: Set<String> = []
    private var completed: Set<String> = []

    private init() {}

    func preview(for url: URL?) -> LinkPreview? {
        guard let url else { return nil }
        return previews[url.absoluteString]
    }

    func load(for url: URL?) {
        guard Settings.shared.fetchLinkPreviews else { return }
        guard let url,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased() else { return }
        let key = url.absoluteString
        guard !inFlight.contains(key), !completed.contains(key) else { return }
        inFlight.insert(key)
        previews[key] = previews[key] ?? LinkPreview()

        var faviconComponents = URLComponents()
        faviconComponents.scheme = scheme
        faviconComponents.host = host
        faviconComponents.path = "/favicon.ico"
        let faviconURL = faviconComponents.url

        var request = URLRequest(url: url)
        request.setValue("Pesty/1.0", forHTTPHeaderField: "User-Agent")
        let pageRequest = request

        Task {
            async let pageData = Self.fetch(pageRequest, limit: Self.maxPageBytes)
            async let iconData: Data? = {
                guard let faviconURL else { return nil }
                return await Self.fetch(URLRequest(url: faviconURL), limit: Self.maxImageBytes)
            }()

            var succeeded = false
            if let metadata = await pageData.flatMap({ Self.pageMetadata(from: $0, relativeTo: url) }) {
                update(key: key, title: metadata.title, icon: nil, image: nil)
                succeeded = metadata.title != nil
                if let imageURL = metadata.imageURL,
                   let image = await Self.fetch(URLRequest(url: imageURL), limit: Self.maxImageBytes)
                       .flatMap(NSImage.init(data:)) {
                    update(key: key, title: nil, icon: nil, image: image)
                    succeeded = true
                }
            }
            if let icon = await iconData.flatMap(NSImage.init(data:)) {
                update(key: key, title: nil, icon: icon, image: nil)
                succeeded = true
            }

            // Always release the latch; only remember outright successes so a
            // transient failure can retry the next time the clip appears.
            inFlight.remove(key)
            if succeeded { completed.insert(key) }
        }
    }

    private func update(key: String, title: String?, icon: NSImage?, image: NSImage?) {
        var preview = previews[key] ?? LinkPreview()
        if let title, !title.isEmpty { preview.title = title }
        if let icon { preview.icon = icon }
        if let image { preview.image = image }
        previews[key] = preview
    }

    /// Downloads a body, giving up early once it grows past `limit` bytes (or
    /// the server announces a Content-Length beyond it).
    nonisolated private static func fetch(_ request: URLRequest, limit: Int) async -> Data? {
        guard let (bytes, response) = try? await previewSession.bytes(for: request) else { return nil }
        if response.expectedContentLength > Int64(limit) { return nil }
        var data = Data()
        data.reserveCapacity(min(max(Int(response.expectedContentLength), 0), limit))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { return nil }
            }
        } catch { return nil }
        return data
    }

    nonisolated private static func pageMetadata(from data: Data, relativeTo url: URL) -> (title: String?, imageURL: URL?)? {
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let expression = try? NSRegularExpression(pattern: "<title[^>]*>(.*?)</title>",
                                                        options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let title = html[range]
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let imagePattern = "<meta[^>]+(?:property|name)=[\\\"'](?:og:image|twitter:image)[\\\"'][^>]+content=[\\\"']([^\\\"']+)[\\\"']"
        let imageExpression = try? NSRegularExpression(pattern: imagePattern, options: [.caseInsensitive])
        let imageURL: URL? = imageExpression.flatMap { expression in
            guard let imageMatch = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let imageRange = Range(imageMatch.range(at: 1), in: html) else { return nil }
            return URL(string: String(html[imageRange]), relativeTo: url)?.absoluteURL
        }
        return (title.isEmpty ? nil : title, imageURL)
    }
}
