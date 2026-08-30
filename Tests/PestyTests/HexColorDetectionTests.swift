import XCTest
@testable import Pesty

final class HexColorDetectionTests: XCTestCase {
    func testSixDigitHexBecomesAColor() {
        XCTAssertEqual(ClipboardMonitor.hexColor(in: "#f9cb06"), "#F9CB06")
        XCTAssertEqual(ClipboardMonitor.hexColor(in: "#F9CB06"), "#F9CB06")
    }

    func testEightDigitHexIsAcceptedAndNormalizedToRGB() {
        XCTAssertEqual(ClipboardMonitor.hexColor(in: "#F9CB06FF"), "#F9CB06")
    }

    func testTextThatMerelyContainsAHexIsNotAColor() {
        XCTAssertNil(ClipboardMonitor.hexColor(in: "use #F9CB06 for the accent"))
        XCTAssertNil(ClipboardMonitor.hexColor(in: "#F9CB06\n#000000"))
    }

    func testBareHexAndShortFormsAreLeftAsText() {
        XCTAssertNil(ClipboardMonitor.hexColor(in: "F9CB06"))
        XCTAssertNil(ClipboardMonitor.hexColor(in: "decade"))
        XCTAssertNil(ClipboardMonitor.hexColor(in: "#FFF"))
        XCTAssertNil(ClipboardMonitor.hexColor(in: "#GGGGGG"))
    }
}
