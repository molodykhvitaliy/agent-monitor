import AgentBarCore
import AppKit
import Testing

@testable import AgentBarUI

/// The status item answers "does anything need me?" before the panel is opened,
/// so its glyph and its sentence are the most important two things in the
/// product.
@MainActor
@Suite("Status item")
struct StatusItemTests {

    @Test("Every state draws a distinct template glyph")
    func glyphsAreDistinct() throws {
        var seen: [Data] = []
        for kind in SessionStateKind.allCases {
            let image = StatusItemGlyph.image(for: kind)
            #expect(image.isTemplate, "\(kind) is not a template image")
            #expect(image.size == NSSize(width: 18, height: 18))
            let data = try #require(
                image.representations.first.flatMap {
                    ($0 as? NSBitmapImageRep)?.representation(using: .png, properties: [:])
                        ?? bitmapData(of: image)
                })
            #expect(!seen.contains(data), "\(kind) draws the same glyph as another state")
            seen.append(data)
        }
    }

    /// Nothing running takes the resting glyph rather than no glyph: a status
    /// item with no image is an invisible, unclickable one.
    @Test("No sessions still draws something")
    func emptyStateDrawsIdle() {
        #expect(StatusItemGlyph.image(for: nil).size.width == 18)
    }

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

    private func bitmapData(of image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
