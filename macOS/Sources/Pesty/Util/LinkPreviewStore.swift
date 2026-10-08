import AppKit
import Foundation
import ImageIO
import Observation

struct LinkPreview {
    var title: String?
    var icon: NSImage?
    var image: NSImage?
}

@Observable
@MainActor
final class LinkPreviewStore {
    static let shared = LinkPreviewStore()

    private var previews: [String: LinkPreview] = [:]
    private var previewOrder: [String] = []
    private var loadingURLs: Set<String> = []
    private static let previewLimit = 128

    private init() {}

    func preview(for url: URL?) -> LinkPreview? {
        guard let url else { return nil }
        return previews[Self.key(for: url)]
    }

    func load(for url: URL?) {
        guard Settings.shared.generateLinkPreviews,
              let url,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(),
              url.user == nil, url.password == nil else { return }
        let key = Self.key(for: url)
        guard previews[key] == nil, !loadingURLs.contains(key) else { return }
        loadingURLs.insert(key)

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("Pesty/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let metadata = data.flatMap { Self.pageMetadata(from: $0, relativeTo: url) }
            DispatchQueue.main.async {
                self.update(key: key, title: metadata?.title, icon: nil, image: nil)
                self.loadingURLs.remove(key)
            }
            if let imageURL = metadata?.imageURL,
               imageURL.host?.lowercased() == host,
               ["http", "https"].contains(imageURL.scheme?.lowercased() ?? "") {
                URLSession.shared.dataTask(with: imageURL) { imageData, _, _ in
                    let image = imageData.flatMap {
                        $0.count <= 1_000_000 ? Self.thumbnail(from: $0, maxPixelSize: 640) : nil
                    }
                    DispatchQueue.main.async {
                        self.update(key: key, title: nil, icon: nil, image: image)
                    }
                }.resume()
            }
        }.resume()

        var faviconURL = URLComponents()
        faviconURL.scheme = scheme
        faviconURL.host = host
        faviconURL.path = "/favicon.ico"
        guard let iconURL = faviconURL.url else { return }
        URLSession.shared.dataTask(with: iconURL) { data, _, _ in
            let icon = data.flatMap {
                $0.count <= 256_000 ? Self.thumbnail(from: $0, maxPixelSize: 64) : nil
            }
            DispatchQueue.main.async {
                self.update(key: key, title: nil, icon: icon, image: nil)
            }
        }.resume()
    }

    private static func key(for url: URL) -> String { url.absoluteString }

    nonisolated private static func thumbnail(from data: Data, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
        ), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func update(key: String, title: String?, icon: NSImage?, image: NSImage?) {
        var preview = previews[key] ?? LinkPreview()
        if let title, !title.isEmpty { preview.title = title }
        if let icon { preview.icon = icon }
        if let image { preview.image = image }
        if previews[key] == nil { previewOrder.append(key) }
        previews[key] = preview
        while previewOrder.count > Self.previewLimit {
            previews.removeValue(forKey: previewOrder.removeFirst())
        }
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
