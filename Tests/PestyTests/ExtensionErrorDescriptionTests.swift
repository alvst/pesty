import XCTest
@testable import Pesty

final class ExtensionErrorDescriptionTests: XCTestCase {
    func testEveryErrorHasAUserDescription() {
        let errors: [ExtensionError] = [
            .noRegisterCall,
            .duplicateRegisterCall,
            .invalidManifest("invalid id"),
            .unsupportedAPI(2),
            .hookNotAFunction("badge"),
            .scriptException("example failure"),
            .timedOut
        ]

        for error in errors {
            XCTAssertFalse(error.userDescription.isEmpty, "Missing description for \(error)")
        }
    }

    func testScriptExceptionDescriptionIncludesItsMessage() {
        let message = "A specific script failure"

        XCTAssertTrue(ExtensionError.scriptException(message).userDescription.contains(message))
    }
}
