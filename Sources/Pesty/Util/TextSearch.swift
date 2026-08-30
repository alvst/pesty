import Darwin
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

    /// Compiles the normalized query once for a whole filtering pass. Search
    /// checks several fields on every clip, so rebuilding these bytes in each
    /// `contains` call creates hundreds of tiny allocations per keystroke.
    struct Query {
        let text: String
        fileprivate let asciiNeedle: [UInt8]?
        fileprivate let anchorIndex: Int
        var usesASCIIFastPath: Bool { asciiNeedle != nil }

        /// A longer ASCII substring can only match an item that matched its
        /// ASCII prefix. Foundation's Unicode case folding has broader
        /// equivalences, so crossing into that path must restart from all
        /// source items instead of reusing a potentially incomplete subset.
        func canNarrowResults(from previous: Query) -> Bool {
            usesASCIIFastPath
                && previous.usesASCIIFastPath
                && !previous.text.isEmpty
                && text.hasPrefix(previous.text)
        }

        init(_ lowercasedText: String) {
            text = lowercasedText
            let bytes = Array(lowercasedText.utf8)
            if bytes.allSatisfy({ $0 < 0x80 }) {
                asciiNeedle = bytes
                // Start from the least common byte in the query. Darwin's
                // vectorized memchr then skips most of a large miss in native
                // code instead of walking it byte-by-byte in debug Swift.
                anchorIndex = bytes.indices.min {
                    Self.frequencyRank(bytes[$0]) < Self.frequencyRank(bytes[$1])
                } ?? 0
            } else {
                asciiNeedle = nil
                anchorIndex = 0
            }
        }

        private static let frequencyOrder = Array("zqjxkvbpygfwmucldrhsnioate \t\n\r".utf8)

        private static func frequencyRank(_ byte: UInt8) -> Int {
            frequencyOrder.firstIndex(of: byte) ?? -1
        }
    }

    /// `query` must already be lowercased — callers lowercase once per search
    /// pass rather than once per clip.
    static func contains(_ haystack: String, lowercasedQuery query: String) -> Bool {
        contains(haystack, query: Query(query))
    }

    static func contains(_ haystack: String, query: Query) -> Bool {
        guard !query.text.isEmpty else { return true }
        guard !haystack.isEmpty else { return false }

        guard let needle = query.asciiNeedle else {
            return haystack.range(of: query.text, options: .caseInsensitive) != nil
        }

        if let found = haystack.utf8.withContiguousStorageIfAvailable({
            scan($0, needle: needle, anchorIndex: query.anchorIndex)
        }) {
            return found
        }
        return Array(haystack.utf8).withUnsafeBufferPointer {
            scan($0, needle: needle, anchorIndex: query.anchorIndex)
        }
    }

    private static func fold(_ byte: UInt8) -> UInt8 {
        // 'A'...'Z' -> 'a'...'z'
        (byte >= 0x41 && byte <= 0x5A) ? byte &+ 0x20 : byte
    }

    private static func scan(_ haystack: UnsafeBufferPointer<UInt8>,
                             needle: [UInt8],
                             anchorIndex: Int) -> Bool {
        guard haystack.count >= needle.count,
              let base = haystack.baseAddress else { return false }

        let anchorByte = needle[anchorIndex]
        if scan(haystack,
                needle: needle,
                anchorIndex: anchorIndex,
                anchorByte: anchorByte,
                base: base) {
            return true
        }
        if anchorByte >= 0x61, anchorByte <= 0x7A {
            return scan(haystack,
                        needle: needle,
                        anchorIndex: anchorIndex,
                        anchorByte: anchorByte - 0x20,
                        base: base)
        }
        return false
    }

    /// Search every occurrence of one exact anchor byte with Darwin's native
    /// vectorized scanner, then verify the complete candidate with the same
    /// ASCII-only case folding as before. Lowercase and uppercase anchors are
    /// scanned separately, so their combined work stays linear.
    private static func scan(_ haystack: UnsafeBufferPointer<UInt8>,
                             needle: [UInt8],
                             anchorIndex: Int,
                             anchorByte: UInt8,
                             base: UnsafePointer<UInt8>) -> Bool {
        let minimumAnchor = anchorIndex
        let maximumAnchor = haystack.count - needle.count + anchorIndex
        var cursor = minimumAnchor

        while cursor <= maximumAnchor {
            let remaining = maximumAnchor - cursor + 1
            guard let rawMatch = memchr(base + cursor, Int32(anchorByte), remaining) else {
                return false
            }
            let foundIndex = base.distance(
                to: rawMatch.assumingMemoryBound(to: UInt8.self)
            )
            let candidateStart = foundIndex - anchorIndex
            var offset = 0
            while offset < needle.count,
                  fold(base[candidateStart + offset]) == needle[offset] {
                offset += 1
            }
            if offset == needle.count { return true }
            cursor = foundIndex + 1
        }
        return false
    }
}
