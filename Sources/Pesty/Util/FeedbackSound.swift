import AppKit
import os.log

/// The short sounds that confirm a copy or a paste.
///
/// `NSSound(named:)` hands back a *shared, cached* instance rather than a
/// fresh one, and that instance can be left reporting `isPlaying` long after
/// the sound itself has finished. `NSSound.play()` refuses to start a sound
/// that already believes it is playing — it returns `false` and does nothing.
/// The result was that the first copy or paste after launch was audible and
/// every one after it was silent.
///
/// Resetting the instance before each play is what makes repeat feedback
/// reliable. It also gives a genuinely rapid second paste a fresh sound
/// rather than swallowing it, which is what you want from feedback: one
/// sound per action.
@MainActor
enum FeedbackSound {
    /// Confirms a paste.
    static let paste: NSSound.Name = "Pop"
    /// Confirms a copy. Deliberately distinct from `paste` so the two stay
    /// audibly apart.
    static let copy: NSSound.Name = "Tink"

    /// Returns whether playback actually started, so a caller — or a test —
    /// can tell silence apart from success.
    private static let log = Logger(subsystem: "com.alvst.pesty-alvie", category: "Sound")

    @discardableResult
    static func play(_ name: NSSound.Name) -> Bool {
        guard let sound = NSSound(named: name) else {
            log.error("no sound named \(name, privacy: .public)")
            return false
        }
        if sound.isPlaying { sound.stop() }
        let started = sound.play()
        log.debug("play \(name, privacy: .public) -> \(started)")
        return started
    }
}
