import Foundation
import Testing

@testable import AgentBarCore

/// A morning's work, played through the store in one go.
///
/// The unit suites each pin one rule; this one exists because the rules have to
/// hold together. It is the closest thing to the question the whole module
/// answers: given everything that happened, what is on the list right now?
@Suite("A scripted morning")
struct ScriptedSessionTests {

    private static let repository = "/Users/dev/code/agentbar"
    private static let website = "/Users/dev/code/agentbar-web"

    /// Advances the clock alongside the timestamps so measured durations and
    /// stated times tell the same story.
    private func play(
        _ events: [AgentEvent], into store: SessionStore, on clock: ManualTimeSource
    ) async {
        for event in events {
            clock.advance(by: .seconds(1))
            await store.apply(event)
        }
    }

    private func script() -> [AgentEvent] {
        let permission = PermissionRequestRef(
            id: PermissionRequestID("req-7"), summary: "Bash(rm -rf build)")
        return [
            // A review session in the repository: prompt, tools, a subagent,
            // and finally a question for the human.
            Fixture.event(.sessionStarted, session: "cc-review", cwd: Self.repository, at: 1),
            Fixture.event(.turnStarted, session: "cc-review", cwd: Self.repository, at: 2),
            Fixture.event(
                .toolStarted, session: "cc-review", cwd: Self.repository, at: 3,
                tool: Fixture.bash, toolUseId: "t-1"),
            Fixture.event(
                .toolFinished, session: "cc-review", cwd: Self.repository, at: 4,
                tool: Fixture.bash, toolUseId: "t-1"),
            Fixture.event(
                .subagentStarted, session: "cc-review", cwd: Self.repository, at: 5,
                agent: Fixture.subagent("sub-1")),
            // The hook was delivered twice; the subagent must still count once.
            Fixture.event(
                .subagentStarted, session: "cc-review", cwd: Self.repository, at: 5,
                agent: Fixture.subagent("sub-1")),
            Fixture.event(
                .subagentStopped, session: "cc-review", cwd: Self.repository, at: 6,
                agent: Fixture.subagent("sub-1")),
            Fixture.event(
                .waitingPermission(permission), session: "cc-review", cwd: Self.repository, at: 7),

            // A second agent in the same repository, running a long build.
            Fixture.event(.sessionStarted, session: "cc-build", cwd: Self.repository, at: 8),
            Fixture.event(.turnStarted, session: "cc-build", cwd: Self.repository, at: 9),
            Fixture.event(
                .toolStarted, session: "cc-build", cwd: Self.repository, at: 10,
                tool: Fixture.bash, toolUseId: "t-9"),

            // A Codex session on the website that finishes cleanly.
            Fixture.event(
                .turnStarted, session: "cx-done", provider: .codex, cwd: Self.website, at: 11),
            Fixture.event(
                .turnFinished, session: "cx-done", provider: .codex, cwd: Self.website, at: 12),
            Fixture.event(
                .sessionEnded, session: "cx-done", provider: .codex, cwd: Self.website, at: 13),

            // And one whose terminal was closed without warning.
            Fixture.event(
                .turnStarted, session: "cx-lost", provider: .codex, cwd: Self.website, at: 14),
        ]
    }

    @Test("The morning produces exactly the expected list")
    func scriptedMorningProducesExpectedList() async {
        let clock = ManualTimeSource()
        let store = SessionStore(clock: clock)
        await play(script(), into: store, on: clock)

        // Twenty minutes later: long enough for a silent agent to stop being
        // believed, not long enough to doubt a build or an unanswered question.
        clock.advance(by: .minutes(20))
        let snapshot = await store.snapshot()

        #expect(snapshot.projects.map(\.project.name) == ["agentbar", "agentbar-web"])
        #expect(snapshot.projects.map(\.sessions.count) == [2, 1])
        #expect(snapshot.mostUrgentState == .waiting)
        #expect(snapshot.isAnyAgentWorking)
        #expect(snapshot.waitingSessionCount == 1)

        let review = snapshot.session("cc-review")
        #expect(review?.state.kind == .waiting)
        #expect(review?.activeSubagentCount == 0)
        #expect(review?.currentTool == nil)
        #expect(review?.provider == .claudeCode)

        let build = snapshot.session("cc-build")
        #expect(build?.state == .working)
        #expect(build?.currentTool == Fixture.bash)

        let lost = snapshot.session("cx-lost")
        #expect(lost?.state == .unknown)
        #expect(lost?.provider == .codex)

        #expect(snapshot.session("cx-done") == nil)
        #expect(snapshot.finished.map(\.sessionId.value) == ["cx-done"])
        #expect(snapshot.finished.first?.outcome == .ended)
    }

    @Test("Replaying the same morning twice changes nothing")
    func scriptIsIdempotentUnderRedelivery() async {
        let clock = ManualTimeSource()
        let store = SessionStore(clock: clock)
        let events = script()
        await play(events, into: store, on: clock)
        let once = await store.snapshot()

        for event in events {
            await store.apply(event)
        }
        let twice = await store.snapshot()

        #expect(once.sessions.map(\.id) == twice.sessions.map(\.id))
        #expect(once.sessions.map(\.state) == twice.sessions.map(\.state))
        #expect(
            once.sessions.map(\.activeSubagentCount)
                == twice.sessions.map(\.activeSubagentCount))
        #expect(twice.finished.count == 1)
    }
}
