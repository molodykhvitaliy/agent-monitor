import Foundation
import Testing

@testable import AgentBarUI

/// Every field of a usage window is independently optional and degrades by
/// **omission**, never by a placeholder: a bar drawn at 0 % says "you have used
/// none of it", which is a different and possibly false claim.
@Suite("Usage windows")
struct UsageWindowTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(
        name: String? = "Weekly", percent: Double? = 0.34, resetsIn: TimeInterval? = 7800
    ) -> UsageWindow {
        UsageWindow(
            name: name,
            fractionUsed: percent,
            resetsAt: resetsIn.map { Self.now.addingTimeInterval($0) })
    }

    @Test("Both halves present")
    func full() {
        #expect(window().meta(now: Self.now) == "34% · resets in 2h 10m")
    }

    @Test("No percentage leaves a standalone reset line, capitalised")
    func withoutPercent() {
        #expect(window(percent: nil).meta(now: Self.now) == "Resets in 2h 10m")
    }

    @Test("No reset leaves a bare percentage, and drops the separator with it")
    func withoutReset() {
        #expect(window(resetsIn: nil).meta(now: Self.now) == "34%")
    }

    @Test("Neither leaves no line at all rather than an empty one")
    func withoutEither() {
        #expect(window(percent: nil, resetsIn: nil).meta(now: Self.now) == nil)
    }

    @Test("An unnamed window is called Usage")
    func unnamed() {
        #expect(window(name: nil).displayName == "Usage")
    }

    /// A window whose reset has already passed reads as due now rather than as
    /// a negative.
    @Test("A reset in the past does not read as a negative")
    func pastReset() {
        #expect(window(percent: nil, resetsIn: -600).meta(now: Self.now) == "Resets in 0s")
    }

    @Test("A percentage outside 0…1 is clamped rather than rendered")
    func clampsPercentage() {
        #expect(window(percent: 1.4, resetsIn: nil).meta(now: Self.now) == "100%")
        #expect(window(percent: -0.2, resetsIn: nil).meta(now: Self.now) == "0%")
    }
}

/// The card's coexistence line. `.other` is the *common* case — any foreign
/// handler on an event AgentBar watches — so it needs a real noun rather than
/// being folded into the first two.
@Suite("Coexistence")
struct CoexistenceTests {

    @Test("A family with no members is simply absent")
    func omitsEmptyFamilies() {
        #expect(CoexistenceSummary(notifiers: 2, others: 3).summary == "2 notifiers, 3 others")
        #expect(CoexistenceSummary(keepAwake: 1).summary == "1 keep-awake")
    }

    @Test("One of a family is singular")
    func singular() {
        #expect(CoexistenceSummary(notifiers: 1).summary == "1 notifier")
    }

    @Test("Nothing at all is empty rather than a line saying nothing")
    func nothing() {
        #expect(CoexistenceSummary().isEmpty)
    }
}
