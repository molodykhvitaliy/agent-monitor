import AgentBarCore
import AppKit
import Testing

@testable import AgentBarUI

/// The status item answers "does anything need me?" before the panel is opened.
/// The glyph itself is covered by `StatusItemGlyphTests`; this suite is the
/// sentence VoiceOver reads instead of it.
@MainActor
@Suite("Status item")
struct StatusItemTests {

    /// The project is named only when exactly one session is in the leading
    /// state; otherwise the count carries it.
    @Test("The accessibility sentence names a project only when one is meant")
    func accessibilitySentence() {
        #expect(StatusItemLabel.describe(.empty) == "AgentBar: nothing running")

        let one = UIFixture.snapshot([
            UIFixture.session("a", state: .waitingInput(question: nil))
        ])
        #expect(StatusItemLabel.describe(one) == "AgentBar: 1 session waiting in agentbar")

        let two = UIFixture.snapshot([
            UIFixture.session("a", state: .waitingInput(question: nil)),
            UIFixture.session("b", state: .waitingInput(question: nil)),
        ])
        #expect(StatusItemLabel.describe(two) == "AgentBar: 2 sessions waiting")
    }

    /// The sentence names a project, so it moves when neither the glyph nor the
    /// count does. An early-out keyed on the aggregate alone would leave
    /// VoiceOver naming a project whose session was answered minutes ago.
    @Test("The sentence changes when only the leading project changes")
    func sentenceFollowsTheProject() {
        let first = UIFixture.snapshot([
            UIFixture.session(
                "a", project: "/Users/dev/agentbar-web",
                state: .waitingInput(question: nil))
        ])
        let second = UIFixture.snapshot([
            UIFixture.session(
                "b", project: "/Users/dev/growth-scripts",
                state: .waitingInput(question: nil))
        ])
        #expect(first.mostUrgentState == second.mostUrgentState)
        #expect(first.waitingSessionCount == second.waitingSessionCount)
        #expect(StatusItemLabel.describe(first) != StatusItemLabel.describe(second))
    }

    /// Waiting → Failed → Working → Unknown → Idle, which is `attentionRank`
    /// and nothing the UI decides for itself.
    @Test("The sentence describes the most urgent state present")
    func urgencyWins() {
        let mixed = UIFixture.snapshot([
            UIFixture.session("a", state: .working),
            UIFixture.session(
                "b", project: "/Users/dev/other", state: .failed(reason: "Server error")),
        ])
        #expect(StatusItemLabel.describe(mixed) == "AgentBar: 1 session failed in other")
    }

    /// A collision is disambiguated in the sentence too — rendering the label
    /// only in the header would leave a VoiceOver user with two identical
    /// `app`s.
    @Test("An ambiguous project is disambiguated in the sentence as well")
    func disambiguatesInTheSentence() {
        let snapshot = UIFixture.snapshot([
            UIFixture.session("a", project: "/Users/dev/code/app", state: .idle),
            UIFixture.session(
                "b", project: "/Users/dev/worktrees/feature-x/app",
                state: .failed(reason: "x")),
        ])
        #expect(
            StatusItemLabel.describe(snapshot)
                == "AgentBar: 1 session failed in app · feature-x")
    }

}
