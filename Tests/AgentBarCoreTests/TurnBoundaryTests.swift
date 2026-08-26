import Foundation
import Testing

@testable import AgentBarCore

/// When a state move means a turn has ended.
///
/// A rule with one caller — the Codex quota reading, which spawns a child
/// process for every `true` — and therefore a rule where both directions matter.
/// It lived in the app target, where `swift test` could not reach it.
@Suite("Turn boundaries")
struct TurnBoundaryTests {

    private static func change(from: SessionState?, to: SessionState?) -> StateChange {
        StateChange(
            sessionId: SessionID("s"),
            provider: .codex,
            project: ProjectRef(
                id: ProjectID("p"), name: "p", root: URL(filePath: "/tmp/p")),
            from: from,
            to: to,
            at: Date(timeIntervalSince1970: 0))
    }

    @Test("Stopping and failing both end a turn")
    func idleAndFailedEndATurn() {
        #expect(Self.change(from: .working, to: .idle).endsATurn)
        #expect(Self.change(from: .working, to: .failed(reason: "boom")).endsATurn)
    }

    /// The expensive direction. `unknown` is the watchdog giving up on a silent
    /// session, which says nothing about whether a turn finished — and treating
    /// it as one would spawn a child process every time a session went quiet.
    @Test("The watchdog giving up does not end a turn")
    func unknownDoesNotEndATurn() {
        #expect(!Self.change(from: .working, to: .unknown).endsATurn)
    }

    @Test("A session appearing is not a turn ending")
    func registrationIsNotATurn() {
        #expect(!Self.change(from: nil, to: .idle).endsATurn)
    }

    @Test("A move into working or waiting is not a turn ending")
    func liveStatesAreNotATurnEnding() {
        #expect(!Self.change(from: .idle, to: .working).endsATurn)
        #expect(!Self.change(from: .working, to: .waitingInput(question: nil)).endsATurn)
    }

    /// A session leaving the store is a retirement, not a turn.
    @Test("A session leaving is not a turn ending")
    func departureIsNotATurnEnding() {
        #expect(!Self.change(from: .idle, to: nil).endsATurn)
    }
}
