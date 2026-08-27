import AppKit
import XCTest
@testable import Pesty

@MainActor
final class FeedbackSoundTests: XCTestCase {

    /// The regression: `NSSound(named:)` returns a shared cached instance, and
    /// once it is left reporting `isPlaying` every later `play()` returns false
    /// and is silent. Before the fix the first paste after launch was audible
    /// and none of the others were.
    func testRepeatedPlaysAllStart() {
        for attempt in 1...4 {
            XCTAssertTrue(FeedbackSound.play(FeedbackSound.paste),
                          "play #\(attempt) was silent — a cached NSSound left mid-play "
                          + "must not stop later sounds from starting")
        }
    }

    func testCopyAndPasteUseDistinctSounds() {
        XCTAssertNotEqual(FeedbackSound.copy, FeedbackSound.paste)
    }

    func testAnUnknownSoundReportsFailureRatherThanCrashing() {
        XCTAssertFalse(FeedbackSound.play("PestyNoSuchSound"))
    }

    /// Documents the AppKit behavior the helper exists to work around, so a
    /// future "simplification" back to `NSSound(named:)?.play()` fails here.
    func testRawNSSoundRefusesToReplayItsCachedInstance() {
        let sound = NSSound(named: FeedbackSound.paste)
        XCTAssertNotNil(sound)
        XCTAssertTrue(sound === NSSound(named: FeedbackSound.paste),
                      "NSSound(named:) is expected to be a shared cached instance")
        sound?.stop()
        XCTAssertTrue(sound?.play() ?? false)
        XCTAssertFalse(sound?.play() ?? true,
                       "a second play() on the same instance is expected to be refused")
    }
}
