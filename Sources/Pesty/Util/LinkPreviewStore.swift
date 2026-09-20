import AppKit
import Foundation
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
    private var loadingHosts: Set<String> = []

    private init() {}

    func preview(for url: URL?) -> LinkPreview? {
        guard let host = url?.host?.lowercased() else { return nil }
        return previews[host]
    }

    func load(for url: URL?) {
        guard let url,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(),
              !loadingHosts.contains(host) else { return }
        loadingHosts.insert(host)
        previews[host] = previews[host] ?? LinkPreview()

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("Pesty/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let metadata = data.flatMap { Self.pageMetadata(from: $0, relativeTo: url) }
            DispatchQueue.main.async {
                self.update(host: host, title: metadata?.title, icon: nil, image: nil, finished: false)
            }
            if let imageURL = metadata?.imageURL {
                URLSession.shared.dataTask(with: imageURL) { imageData, _, _ in
                    let image = imageData.flatMap(NSImage.init(data:))
                    DispatchQueue.main.async {
                        self.update(host: host, title: nil, icon: nil, image: image, finished: false)
                    }
                }.resume()
            }
        }.resume()

        var faviconURL = URLComponents()
        faviconURL.scheme = scheme
        faviconURL.host = host
        faviconURL.path = "/favicon.ico"
        guard let iconURL = faviconURL.url else {
            loadingHosts.remove(host)
            return
        }
        URLSession.shared.dataTask(with: iconURL) { data, _, _ in
            let icon = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                self.update(host: host, title: nil, icon: icon, image: nil, finished: true)
            }
        }.resume()
    }

    private func update(host: String, title: String?, icon: NSImage?, image: NSImage?, finished: Bool) {
        var preview = previews[host] ?? LinkPreview()
        if let title, !title.isEmpty { preview.title = title }
        if let icon { preview.icon = icon }
        if let image { preview.image = image }
        previews[host] = preview
        if finished { loadingHosts.remove(host) }
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
