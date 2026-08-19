import Foundation
import Testing

@testable import AgentBarUI

@Suite("Duration text")
struct DurationTextTests {

    @Test(
        "Reads at most two units, largest first, never zero-padded",
        arguments: [
            (Duration.seconds(0), "0s"),
            (Duration.seconds(38), "38s"),
            (Duration.seconds(60), "1m"),
            (Duration.seconds(63), "1m 3s"),
            (Duration.seconds(252), "4m 12s"),
            (Duration.seconds(600), "10m"),
            (Duration.seconds(14 * 60 + 30), "14m"),
            (Duration.seconds(3600), "1h"),
            (Duration.seconds(4800), "1h 20m"),
            (Duration.seconds(3 * 86400), "3d"),
        ])
    func compactForms(duration: Duration, expected: String) {
        #expect(DurationText.compact(duration) == expected)
    }

    /// The store hands out a signed `Duration`, and a reading taken microseconds
    /// apart on two clocks can produce a small negative. `-3s` in a row is a
    /// bug the user sees.
    @Test("A negative duration reads as zero rather than as a negative")
    func clampsNegatives() {
        #expect(DurationText.compact(.seconds(-5)) == "0s")
    }

    /// `4m 12s` is read out as letters, so VoiceOver gets words.
    @Test(
        "The spoken form spells the units",
        arguments: [
            (Duration.seconds(1), "1 second"),
            (Duration.seconds(38), "38 seconds"),
            (Duration.seconds(63), "1 minute 3 seconds"),
            (Duration.seconds(4800), "1 hour 20 minutes"),
        ])
    func spokenForms(duration: Duration, expected: String) {
        #expect(DurationText.spoken(duration) == expected)
    }

    @Test("A reset time takes the same units with a preposition")
    func resetForm() {
        #expect(DurationText.resets(in: .seconds(7800)) == "resets in 2h 10m")
    }
}
