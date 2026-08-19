import AppKit
import Foundation
import os

/// Plays a sound so the user can hear what they just chose.
///
/// `NSSound` rather than posting a real notification: an audition must not
/// depend on notification authorisation, must not be swallowed by quiet hours,
/// and must not leave a banner in Notification Center. It is the one place in
/// AgentBar that makes a noise outside the notification system, and it makes it
/// only when a person presses a button.
///
/// This is also the honest answer to the platform's worst property here —
/// `UNNotificationSound(named:)` falls back to the default without saying so.
/// Validation proves a file is *loadable*; only a person can confirm it is the
/// sound they wanted.
@MainActor
public final class SoundPreview {
    private static let logger = Logger(
        subsystem: "com.molodykhvitalii.AgentBar", category: "sounds")

    /// Held so a second press stops the first sound rather than layering on it.
    private var playing: NSSound?

    public init() {}

    /// Returns whether the file could be loaded at all — which is a weaker
    /// claim than `SoundValidator` makes, and a different one: this says
    /// AppKit read it, not that the notification centre will accept it.
    @discardableResult
    public func play(_ file: SoundFile) -> Bool {
        stop()
        guard let sound = NSSound(contentsOf: file.url, byReference: true) else {
            Self.logger.error(
                "sound could not be loaded for preview: \(file.name, privacy: .public)")
            return false
        }
        playing = sound
        return sound.play()
    }

    public func stop() {
        playing?.stop()
        playing = nil
    }
}
