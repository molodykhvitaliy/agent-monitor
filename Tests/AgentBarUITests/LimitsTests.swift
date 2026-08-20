import AgentBarCore
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
            provider: .codex,
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

/// Which service a bar belongs to.
///
/// The section used to render a bare `Weekly` under a bare `Limits`, which with
/// two providers installed left the panel refusing to say whose week it was —
/// and a bar close to full says nothing useful until you know which
/// subscription it is describing.
@MainActor
@Suite("Limits grouping")
struct LimitsGroupingTests {

    private func window(_ provider: Provider, _ name: String) -> UsageWindow {
        UsageWindow(provider: provider, name: name, fractionUsed: 0.5, resetsAt: nil)
    }

    /// The permanent one. Claude Code reports no windows and never will, but
    /// the note about it is part of the section rather than a fault, so its
    /// heading has to survive having nothing under it.
    @Test("With no windows at all, Claude Code is still named")
    func claudeCodeIsPermanent() {
        let groups = LimitsSectionView.groups(from: [])
        #expect(groups == [LimitsGroup(provider: .claudeCode, windows: [])])
    }

    /// The other direction: a provider with no reading is absent, not an empty
    /// heading. No reading is not an error and must not be styled as one.
    @Test("A provider that reported nothing has no heading")
    func silentProviderIsAbsent() {
        let groups = LimitsSectionView.groups(from: [window(.codex, "Weekly")])
        #expect(groups.map(\.provider) == [.codex, .claudeCode])
        #expect(groups[0].windows.map(\.displayName) == ["Weekly"])
        #expect(groups[1].windows.isEmpty)
    }

    @Test("Every window lands under its own provider, in the order it arrived")
    func groupsByProvider() {
        let windows = [
            window(.codex, "Weekly"), window(.claudeCode, "Daily"), window(.codex, "Extra"),
        ]
        let groups = LimitsSectionView.groups(from: windows)
        #expect(groups.map(\.provider) == [.codex, .claudeCode])
        #expect(groups[0].windows.map(\.displayName) == ["Weekly", "Extra"])
        #expect(groups[1].windows.map(\.displayName) == ["Daily"])
    }

    /// Codex carries the numbers; the Claude Code note is a footnote to the
    /// section and belongs under them.
    @Test("Codex is rendered first and Claude Code last")
    func fixedOrder() {
        #expect(LimitsSectionView.providerOrder == [.codex, .claudeCode])
    }

    /// The order is hand-written, and `groups(from:)` iterates it — so a
    /// provider missing from it is a provider whose quota **disappears from the
    /// panel** with no heading, no row and no log line. That is the silent
    /// failure the project forbids, and it costs one assertion to make it a
    /// test failure the day a third provider is added instead.
    @Test("Every provider the domain has appears in the order")
    func coversEveryProvider() {
        #expect(Set(LimitsSectionView.providerOrder) == Set(Provider.allCases))
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

/// What a usage window is called.
///
/// Every rule here is a rule about not inventing a label. Codex has sent
/// `limitName: null` in every live reading taken, so the fallbacks are the
/// common path rather than the edge — and the design mocked exactly what they
/// produce: `5 hours` above `Weekly`.
@Suite("Usage window naming")
struct UsageWindowNamingTests {

    @Test(
        "A round window is named by the word people use for it",
        arguments: [
            (60, "Hourly"),
            (1440, "Daily"),
            (10080, "Weekly"),
            (43200, "Monthly"),
        ])
    func namesTheRoundWindows(minutes: Int, expected: String) {
        #expect(DurationText.window(.seconds(minutes * 60)) == expected)
    }

    @Test(
        "Anything else is spelled out in its largest whole unit",
        arguments: [
            (300, "5 hours"),
            (2880, "2 days"),
            (90, "90 minutes"),
            (30, "30 minutes"),
        ])
    func spellsOutTheRest(minutes: Int, expected: String) {
        #expect(DurationText.window(.seconds(minutes * 60)) == expected)
    }

    @Test("A window of no length has no name")
    func refusesAZeroWindow() {
        #expect(DurationText.window(.zero) == nil)
        #expect(DurationText.window(.seconds(-60)) == nil)
    }

    /// The provider's own name wins, verbatim — that is what the design spec
    /// asks for and it is the only label AgentBar did not compose.
    @Test("A named bucket keeps its name")
    func prefersTheProvidersName() {
        #expect(
            UsageWindow.label(name: "Pro limit", windowDuration: nil, identifier: "codex")
                == "Pro limit")
    }

    /// The live case: no name, a weekly window, and the label the design mocked.
    @Test("An unnamed bucket is named by its window")
    func fallsBackToTheWindowLength() {
        #expect(
            UsageWindow.label(
                name: nil, windowDuration: .seconds(10080 * 60), identifier: "codex") == "Weekly")
    }

    /// A bucket with a name *and* two windows would otherwise render two
    /// identical rows, which is the one case joining exists for.
    @Test("A name and a length are joined rather than one replacing the other")
    func joinsBothWhenBothExist() {
        #expect(
            UsageWindow.label(
                name: "Pro limit", windowDuration: .seconds(300 * 60), identifier: "codex")
                == "Pro limit · 5 hours")
    }

    /// Last, because `codex` is an identifier rather than a name and reads as
    /// one — but it beats saying nothing.
    @Test("The identifier is the last resort")
    func fallsBackToTheIdentifier() {
        #expect(UsageWindow.label(name: nil, windowDuration: nil, identifier: "codex") == "codex")
    }

    /// Nothing is invented. With none of the three the row falls back to the
    /// design's own `Usage`.
    @Test("With nothing to go on there is no label at all")
    func inventsNothing() {
        #expect(UsageWindow.label(name: nil, windowDuration: nil, identifier: nil) == nil)
        #expect(UsageWindow.label(name: "", windowDuration: nil, identifier: "") == nil)
        #expect(
            UsageWindow(provider: .codex, name: nil, fractionUsed: nil, resetsAt: nil)
                .displayName == "Usage")
    }
}
