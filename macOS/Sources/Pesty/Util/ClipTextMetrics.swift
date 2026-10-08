import Foundation

/// Memoized counts over clip text.
///
/// `String.count` walks the whole string to count grapheme clusters — about
/// 15 ms for a 7 MB clip — and a card asks for it on every body evaluation,
/// which is per hover, per selection change, and per animation frame. The
/// number is exact and worth showing, so it is cached rather than
/// approximated.
///
/// Entries are keyed by clip ID and validated against the text's UTF-8 length,
/// so editing a clip re-counts it instead of showing a stale figure.
@MainActor
enum ClipTextMetrics {
    private struct Entry {
        let byteCount: Int
        let characterCount: Int
    }

    private static var cache: [UUID: Entry] = [:]

    /// Bounded so a long session cannot accumulate an entry per clip forever.
    /// Clips are capped in history anyway; this is a backstop.
    private static let capacity = 512

    static func characterCount(of item: ClipItem) -> Int {
        guard let text = item.text, !text.isEmpty else { return 0 }
        let bytes = text.utf8.count
        if let entry = cache[item.id], entry.byteCount == bytes {
            return entry.characterCount
        }
        let count = text.count
        if cache.count >= capacity { cache.removeAll(keepingCapacity: true) }
        cache[item.id] = Entry(byteCount: bytes, characterCount: count)
        return count
    }

    static func forget(_ id: UUID) {
        cache.removeValue(forKey: id)
    }
}
