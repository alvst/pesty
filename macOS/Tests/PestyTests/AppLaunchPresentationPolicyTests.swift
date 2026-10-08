import XCTest
@testable import Pesty

final class AppLaunchPresentationPolicyTests: XCTestCase {
    func testFirstEverLaunchShowsBar() {
        XCTAssertTrue(
            AppLaunchPresentationPolicy.shouldShowInitialBar(hasOnboarded: false)
        )
    }

    func testLaterColdLaunchStaysHidden() {
        XCTAssertFalse(
            AppLaunchPresentationPolicy.shouldShowInitialBar(hasOnboarded: true)
        )
    }
}
