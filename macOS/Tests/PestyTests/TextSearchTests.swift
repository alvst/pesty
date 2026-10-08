import XCTest
@testable import Pesty

final class TextSearchUnicodeTests: XCTestCase {
    func testLongUnicodeMissAndCanonicalMatch() {
        let longText = String(repeating: "plain text with some café\n", count: 5_000)
        XCTAssertFalse(TextSearch.contains(longText, query: .init("不存在")))
        XCTAssertTrue(TextSearch.contains(longText, query: .init("CAFE\u{301}".lowercased())))
    }

    func testFoldedCandidateStillUsesFoundationForPartialLigature() {
        let longText = String(repeating: "ordinary content ", count: 6_000) + "ﬃ"
        XCTAssertFalse(TextSearch.contains(longText, query: .init("ﬁ")))
    }

    func testUnicodeQueryDoesNotNarrowFromASCIIResults() {
        XCTAssertFalse(TextSearch.Query("café").canNarrowResults(from: .init("caf")))
    }
}
