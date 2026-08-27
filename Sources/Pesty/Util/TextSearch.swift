import Foundation

/// Case-insensitive substring search that never allocates a folded copy of the
/// text being searched.
///
/// Search runs over every clip on every keystroke, and a clip can be
/// megabytes — pasting a large JSON file made the bar unresponsive. The case
/// that matters is a *miss*, because that is what a query does against every
/// clip it does not match. Measured on a 7 MB clip:
///
///     text.range(of: q, options: .caseInsensitive)     560 ms
///     text.lowercased().contains(q)                    243 ms
///     this                                              36 ms
///
/// The fast path folds ASCII bytes only, so it is taken only for ASCII
/// queries. Anything else falls back to Foundation, which is correct for every
/// script and is not the hot path. Byte-level matching is safe here because
/// UTF-8 is self-synchronizing: a byte sequence cannot match across a
/// character boundary without matching the characters themselves.
enum TextSearch {

    /// `query` must already be lowercased — callers lowercase once per search
    /// pass rather than once per clip.
    static func contains(_ haystack: String, lowercasedQuery query: String) -> Bool {
        guard !query.isEmpty else { return true }
        guard !haystack.isEmpty else { return false }

        let needle = Array(query.utf8)
        guard needle.allSatisfy({ $0 < 0x80 }) else {
            return haystack.range(of: query, options: .caseInsensitive) != nil
        }

        var utf8 = haystack.utf8
        if let found = utf8.withContiguousStorageIfAvailable({ scan($0, needle) }) {
            return found
        }
        return scan(Array(haystack.utf8)[...], needle)
    }

    private static func fold(_ byte: UInt8) -> UInt8 {
        // 'A'...'Z' -> 'a'...'z'
        (byte >= 0x41 && byte <= 0x5A) ? byte &+ 0x20 : byte
    }

    private static func scan<C: RandomAccessCollection>(_ haystack: C, _ needle: [UInt8]) -> Bool
    where C.Element == UInt8, C.Index == Int {
        let needleCount = needle.count
        guard haystack.count >= needleCount else { return false }
        let firstByte = needle[0]
        var index = haystack.startIndex
        let lastStart = haystack.endIndex - needleCount

        while index <= lastStart {
            if fold(haystack[index]) == firstByte {
                var offset = 1
                while offset < needleCount, fold(haystack[index + offset]) == needle[offset] {
                    offset += 1
                }
                if offset == needleCount { return true }
            }
            index += 1
        }
        return false
    }
}
