import XCTest
@testable import Pesty

/// Covers the behavior that made a large text clip freeze the bar: card
/// metadata that walked the entire clip on every render.
final class ClipItemLargeTextTests: XCTestCase {

    /// Roughly the shape of the clip that triggered this: megabytes of JSON
    /// across a couple of hundred thousand lines.
    private func largeJSON() -> String {
        let line = #"  { "name": "Depth Jump", "sets": 4, "reps": 8, "rest": 90 },"#
        return "[\n" + Array(repeating: line, count: 120_000).joined(separator: "\n") + "\n]"
    }

    private func item(_ text: String) -> ClipItem {
        ClipItem(type: .text, text: text)
    }

    // MARK: - Correctness

    func testDisplayTitleReturnsTheFirstLine() {
        XCTAssertEqual(item("first line\nsecond line").displayTitle, "first line")
    }

    /// The previous implementation used `split(whereSeparator:)`, which omits
    /// empty subsequences — so leading blank lines were skipped. The bounded
    /// scan has to skip them too.
    func testDisplayTitleSkipsLeadingNewlines() {
        XCTAssertEqual(item("\n\n\nactual content").displayTitle, "actual content")
    }

    func testDisplayTitleIsCappedAtSixtyCharacters() {
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(item(long).displayTitle.count, 60)
    }

    func testDisplayTitleFallsBackToTheTypeLabelWhenThereIsNoText() {
        XCTAssertEqual(item("").displayTitle, ClipType.text.label)
    }

    func testCardPreviewTextIsBounded() {
        let preview = item(largeJSON()).cardPreviewText
        XCTAssertLessThanOrEqual(preview.count, ClipItem.cardPreviewLimit)
        XCTAssertTrue(preview.hasPrefix("[\n  { \"name\""))
    }

    func testCardPreviewTextLeavesShortClipsWhole() {
        XCTAssertEqual(item("small").cardPreviewText, "small")
    }

    // MARK: - Matching

    func testMatchesFindsTextCaseInsensitively() {
        XCTAssertTrue(item("Depth Jump").matches(query: "depth"))
        XCTAssertFalse(item("Depth Jump").matches(query: "squat"))
    }

    func testMatchesSearchesTitleAndSourceApp() {
        var clip = item("body")
        clip.customTitle = "Plyometrics Backup"
        clip.sourceAppName = "Safari"
        XCTAssertTrue(clip.matches(query: "plyometrics"))
        XCTAssertTrue(clip.matches(query: "safari"))
    }

    func testAnEmptyQueryMatchesEverything() {
        XCTAssertTrue(item("anything").matches(query: ""))
    }

    // MARK: - Cost
    //
    // Generous bounds: the point is to catch a return to walking the whole
    // clip, not to pin down a millisecond figure on unknown hardware. The
    // implementations these replaced measured ~150 ms and ~400 ms on a 7 MB
    // clip; the bounded ones are effectively free.

    func testDisplayTitleDoesNotWalkTheWholeClip() {
        let clip = item(largeJSON())
        let started = Date()
        for _ in 0..<20 { _ = clip.displayTitle }
        let elapsed = -started.timeIntervalSinceNow
        XCTAssertLessThan(elapsed, 1.0,
                          "20 title reads took \(elapsed)s — displayTitle is scanning the whole clip again")
    }

    func testCardPreviewTextDoesNotCopyTheWholeClip() {
        let clip = item(largeJSON())
        let started = Date()
        for _ in 0..<20 { _ = clip.cardPreviewText }
        let elapsed = -started.timeIntervalSinceNow
        XCTAssertLessThan(elapsed, 1.0,
                          "20 preview reads took \(elapsed)s — the preview is no longer bounded")
    }

    /// A query that hits a cheap field must never reach the body.
    func testMatchingATitleDoesNotScanTheBody() {
        var clip = item(largeJSON())
        clip.customTitle = "Plyometrics Backup"
        let started = Date()
        for _ in 0..<20 { XCTAssertTrue(clip.matches(query: "plyometrics")) }
        let elapsed = -started.timeIntervalSinceNow
        XCTAssertLessThan(elapsed, 1.0,
                          "20 title matches took \(elapsed)s — cheap fields are no longer tried first")
    }
}

/// `TextSearch` replaces both `searchableText`'s lowercased copy and a
/// `range(of:options:.caseInsensitive)` attempt that was slower still.
final class TextSearchTests: XCTestCase {

    func testFindsASCIIRegardlessOfCase() {
        XCTAssertTrue(TextSearch.contains("Depth Jump", lowercasedQuery: "depth"))
        XCTAssertTrue(TextSearch.contains("DEPTH JUMP", lowercasedQuery: "jump"))
        XCTAssertTrue(TextSearch.contains("depth jump", lowercasedQuery: "h j"))
    }

    func testReportsMisses() {
        XCTAssertFalse(TextSearch.contains("Depth Jump", lowercasedQuery: "squat"))
        XCTAssertFalse(TextSearch.contains("", lowercasedQuery: "squat"))
    }

    func testMatchesAtBothEnds() {
        XCTAssertTrue(TextSearch.contains("abcdef", lowercasedQuery: "abc"))
        XCTAssertTrue(TextSearch.contains("abcdef", lowercasedQuery: "def"))
        XCTAssertTrue(TextSearch.contains("abcdef", lowercasedQuery: "abcdef"))
        XCTAssertFalse(TextSearch.contains("abcdef", lowercasedQuery: "abcdefg"))
    }

    func testAnEmptyQueryAlwaysMatches() {
        XCTAssertTrue(TextSearch.contains("anything", lowercasedQuery: ""))
    }

    /// A partial match must not stop the scan — the real occurrence is later.
    func testRecoversFromAPartialMatch() {
        XCTAssertTrue(TextSearch.contains("aab", lowercasedQuery: "ab"))
        XCTAssertTrue(TextSearch.contains("xxaxxab", lowercasedQuery: "ab"))
    }

    /// Non-ASCII queries take the Foundation fallback, which must still work.
    func testNonASCIIQueriesStillMatch() {
        XCTAssertTrue(TextSearch.contains("Café Plyométrie", lowercasedQuery: "plyométrie"))
        XCTAssertTrue(TextSearch.contains("深蹲跳", lowercasedQuery: "深蹲"))
        XCTAssertFalse(TextSearch.contains("Café", lowercasedQuery: "thé"))
    }

    /// ASCII folding is byte-wise, so it must not fold anything above 0x7F and
    /// must not match across a multi-byte character's boundary.
    func testDoesNotCorruptMultibyteText() {
        XCTAssertTrue(TextSearch.contains("naïve JSON", lowercasedQuery: "json"))
        XCTAssertFalse(TextSearch.contains("é", lowercasedQuery: "e"))
    }

    func testPreparedQueryCanBeReusedAcrossFields() {
        let query = TextSearch.Query("depth")
        XCTAssertFalse(TextSearch.contains("Safari", query: query))
        XCTAssertTrue(TextSearch.contains("DEPTH JUMP", query: query))
        XCTAssertTrue(TextSearch.contains("training/depth-notes.txt", query: query))
    }

    func testIncrementalNarrowingStaysWithinASCIISemantics() {
        XCTAssertTrue(
            TextSearch.Query("depth").canNarrowResults(from: TextSearch.Query("dep"))
        )
        XCTAssertFalse(
            TextSearch.Query("de").canNarrowResults(from: TextSearch.Query("dep"))
        )
        XCTAssertFalse(
            TextSearch.Query("strasseé").canNarrowResults(from: TextSearch.Query("strasse"))
        )
        XCTAssertFalse(
            TextSearch.Query("café").canNarrowResults(from: TextSearch.Query("caf"))
        )
    }

    func testSearchContinuesPastEmbeddedNullBytes() {
        XCTAssertTrue(TextSearch.contains("before\0AFTER", lowercasedQuery: "after"))
    }

    func testASCIIScannerMatchesNaiveSearchAcrossFixedCorpus() {
        var state: UInt64 = 0xC0FFEE
        let alphabet = Array("aAbBcCdDeE xyzXYZ-_/0123456789".utf8) + [0, 9, 10]
        func makeString(maxLength: Int) -> String {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let length = Int(state % UInt64(maxLength + 1))
            let bytes = (0..<length).map { _ -> UInt8 in
                state = state &* 6_364_136_223_846_793_005 &+ 1
                return alphabet[Int(state % UInt64(alphabet.count))]
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        for _ in 0..<500 {
            let haystack = makeString(maxLength: 160)
            let query = makeString(maxLength: 12).lowercased()
            XCTAssertEqual(
                TextSearch.contains(haystack, lowercasedQuery: query),
                query.isEmpty || haystack.lowercased().contains(query),
                "scanner disagreed for haystack \(haystack.debugDescription), query \(query.debugDescription)"
            )
        }
    }

    func testAMissOnALargeStringStaysFast() {
        let large = String(repeating: "  { \"name\": \"Depth Jump\" },\n", count: 200_000)
        let started = Date()
        XCTAssertFalse(TextSearch.contains(large, lowercasedQuery: "zzznotpresent"))
        let elapsed = -started.timeIntervalSinceNow
        XCTAssertLessThan(elapsed, 0.25,
                          "a single miss took \(elapsed)s — search is allocating or using ICU again")
    }
}
