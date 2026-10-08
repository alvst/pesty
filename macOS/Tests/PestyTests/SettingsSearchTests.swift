import XCTest
@testable import Pesty

final class SettingsSearchTests: XCTestCase {
    func testSearchFindsNestedSettingsInsteadOfOnlySections() {
        let expectedMatches: [(String, String)] = [
            ("concealed passwords", "concealed"),
            ("always paste as plain text", "paste-plain"),
            ("bar height", "bar-height"),
            ("ignore transient content", "transient"),
            ("quick paste", "quick-paste"),
            ("install extension", "extensions-install"),
            ("sync clipboard", "sync")
        ]

        for (query, expectedID) in expectedMatches {
            XCTAssertTrue(
                SettingsSearchIndex.results(for: query).contains { $0.id == expectedID },
                "Expected \(query) to find \(expectedID)"
            )
        }
    }

    func testSearchToleratesACommonMisspelling() {
        XCTAssertTrue(
            SettingsSearchIndex.results(for: "ocncelied passwords").contains { $0.id == "concealed" }
        )
    }

    func testEveryIndexedSettingCanFindItself() {
        for item in SettingsSearchIndex.items {
            XCTAssertTrue(
                SettingsSearchIndex.results(for: item.title).contains { $0.id == item.id },
                "Could not find indexed setting named \(item.title)"
            )
        }
    }
}
