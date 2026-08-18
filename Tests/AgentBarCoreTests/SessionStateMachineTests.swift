import Foundation
import Testing

@testable import AgentBarCore

/// Every transition in the table in docs/dev/architecture.md, one test each.
@Suite("Session state machine")
struct SessionStateMachineTests {

    private func store() -> SessionStore {
        SessionStore(clock: ManualTimeSource())
    }

    @Test("A session announcement registers an idle session")
    func sessionStartedRegisters() async {
        let store = store()
        let outcome = await store.apply(Fixture.event(.sessionStarted))

        #expect(outcome.stateChange?.from == nil)
        #expect(outcome.stateChange?.to == .idle)
        #expect(await store.snapshot().onlySession?.state == .idle)
    }

    @Test("A submitted prompt puts the session to work")
    func promptStartsWork() async {
        let store = store()
        await store.apply(Fixture.event(.sessionStarted))
        await store.apply(Fixture.event(.turnStarted, at: 1))

        #expect(await store.snapshot().onlySession?.state == .working)
    }

    @Test("A tool call is shown while it runs and forgotten when it returns")
    func toolCallIsShownWhileRunning() async {
        let store = store()
        await store.apply(Fixture.event(.turnStarted))
        await store.apply(
            Fixture.event(.toolStarted, at: 1, tool: Fixture.bash, toolUseId: "tool-1"))

        #expect(await store.snapshot().onlySession?.currentTool == Fixture.bash)

        await store.apply(
            Fixture.event(.toolFinished, at: 2, tool: Fixture.bash, toolUseId: "tool-1"))

        let session = await store.snapshot().onlySession
        #expect(session?.currentTool == nil)
        #expect(session?.state == .working)
    }

    @Test("The newest of several open tool calls is the current one")
    func newestOpenToolWins() async {
        let store = store()
        await store.apply(
            Fixture.event(.toolStarted, at: 1, tool: Fixture.bash, toolUseId: "tool-1"))
        await store.apply(
            Fixture.event(.toolStarted, at: 2, tool: Fixture.edit, toolUseId: "tool-2"))
        #expect(await store.snapshot().onlySession?.currentTool == Fixture.edit)

        await store.apply(
            Fixture.event(.toolFinished, at: 3, tool: Fixture.edit, toolUseId: "tool-2"))
        #expect(await store.snapshot().onlySession?.currentTool == Fixture.bash)
    }

    @Test("An idle prompt makes the session wait for the human")
    func idlePromptWaits() async {
        let store = store()
        await store.apply(Fixture.event(.turnStarted))
        await store.apply(Fixture.event(.waitingInput, at: 1))

        #expect(await store.snapshot().onlySession?.state == .waitingInput)
    }

    /// There is no "resumed" event: recovery has to ride on the next ordinary
    /// heartbeat, or a session answered in the terminal waits for ever.
    @Test(
        "Waiting ends on the next ordinary event",
        arguments: [EventKind.toolStarted, .toolFinished, .turnStarted]
    )
    func waitingRecovers(on kind: EventKind) async {
        let store = store()
        await store.apply(Fixture.event(.waitingInput))
        #expect(await store.snapshot().onlySession?.state == .waitingInput)

        await store.apply(Fixture.event(kind, at: 1, toolUseId: "tool-1"))
        #expect(await store.snapshot().onlySession?.state == .working)
    }

    @Test("A permission request is reachable and recovers the same way")
    func permissionWaitIsReachable() async {
        let store = store()
        let request = PermissionRequestRef(id: PermissionRequestID("req-1"), summary: "rm -rf")
        await store.apply(Fixture.event(.waitingPermission(request)))

        #expect(await store.snapshot().onlySession?.state == .waitingPermission(request))
        #expect(await store.snapshot().onlySession?.state.kind == .waiting)

        await store.apply(Fixture.event(.toolFinished, at: 1, toolUseId: "tool-1"))
        #expect(await store.snapshot().onlySession?.state == .working)
    }

    @Test("Subagents are counted while they run")
    func subagentsAreCounted() async {
        let store = store()
        await store.apply(Fixture.event(.turnStarted))
        await store.apply(Fixture.event(.subagentStarted, at: 1, agent: Fixture.subagent("a")))
        await store.apply(Fixture.event(.subagentStarted, at: 2, agent: Fixture.subagent("b")))
        #expect(await store.snapshot().onlySession?.activeSubagentCount == 2)

        await store.apply(Fixture.event(.subagentStopped, at: 3, agent: Fixture.subagent("a")))
        let session = await store.snapshot().onlySession
        #expect(session?.activeSubagentCount == 1)
        #expect(session?.state == .working)
    }

    @Test("The end of a turn closes everything the turn opened")
    func turnEndClosesEverything() async {
        let store = store()
        await store.apply(Fixture.event(.turnStarted))
        await store.apply(
            Fixture.event(.toolStarted, at: 1, tool: Fixture.bash, toolUseId: "tool-1"))
        await store.apply(Fixture.event(.subagentStarted, at: 2, agent: Fixture.subagent("a")))
        await store.apply(Fixture.event(.turnFinished, at: 3))

        let session = await store.snapshot().onlySession
        #expect(session?.state == .idle)
        #expect(session?.currentTool == nil)
        #expect(session?.activeSubagentCount == 0)
    }

    @Test("A failed turn keeps its reason")
    func failureKeepsItsReason() async {
        let store = store()
        await store.apply(Fixture.event(.turnStarted))
        await store.apply(Fixture.event(.failed(reason: "overloaded_error"), at: 1))

        #expect(await store.snapshot().onlySession?.state == .failed(reason: "overloaded_error"))
        #expect(await store.snapshot().onlySession?.state.kind == .failed)
    }

    @Test("A session that ends leaves the list and enters the history")
    func sessionEndRemoves() async {
        let store = store()
        await store.apply(Fixture.event(.turnStarted))
        let outcome = await store.apply(Fixture.event(.sessionEnded, at: 5))

        #expect(outcome.stateChange?.to == nil)
        #expect(outcome.stateChange?.from == .working)

        let snapshot = await store.snapshot()
        #expect(snapshot.sessions.isEmpty)
        #expect(snapshot.finished.count == 1)
        #expect(snapshot.finished.first?.outcome == .ended)
        #expect(snapshot.finished.first?.finalState == .working)
    }

    /// `SessionStart` fires again on resume, clear, compact and fork — and
    /// compaction happens mid-turn. Treating it as a fresh start would report a
    /// working agent as idle every time its context is compacted.
    @Test("A repeated announcement does not interrupt a running turn")
    func repeatedAnnouncementDoesNotReset() async {
        let store = store()
        await store.apply(Fixture.event(.sessionStarted))
        await store.apply(Fixture.event(.turnStarted, at: 1))
        let outcome = await store.apply(Fixture.event(.sessionStarted, at: 2))

        #expect(outcome.isUnchanged)
        #expect(await store.snapshot().onlySession?.state == .working)
    }

    /// AgentBar is usually launched while agents are already running.
    @Test("A session first seen mid-flight is adopted, not dropped")
    func unknownSessionIsAdopted() async {
        let store = store()
        let outcome = await store.apply(
            Fixture.event(.toolStarted, tool: Fixture.bash, toolUseId: "tool-1"))

        #expect(outcome.stateChange?.from == nil)
        #expect(await store.snapshot().onlySession?.state == .working)
    }

    @Test("A farewell for a session never seen is ignored")
    func unknownSessionEndIsIgnored() async {
        let store = store()
        let outcome = await store.apply(Fixture.event(.sessionEnded))

        #expect(outcome.ignoreReason == .unknownSession)
        #expect(await store.snapshot().sessions.isEmpty)
        #expect(await store.snapshot().finished.isEmpty)
    }
}

/// Codex documents no equivalent of `tool_use_id`, so the whole nil-id path is
/// a first-class case rather than a fallback nobody reaches.
@Suite("Tool calls without an identifier")
struct UnidentifiedToolCallTests {

    private func store() -> SessionStore {
        SessionStore(clock: ManualTimeSource())
    }

    @Test("An unidentified tool call is shown and then closed by name")
    func unidentifiedToolIsClosedByName() async {
        let store = store()
        await store.apply(Fixture.event(.toolStarted, at: 1, tool: Fixture.bash))
        #expect(await store.snapshot().onlySession?.currentTool == Fixture.bash)

        await store.apply(Fixture.event(.toolFinished, at: 2, tool: Fixture.bash))
        #expect(await store.snapshot().onlySession?.currentTool == nil)
    }

    @Test("The newest matching call is the one closed")
    func newestMatchingCallIsClosed() async {
        let store = store()
        await store.apply(Fixture.event(.toolStarted, at: 1, tool: Fixture.bash))
        await store.apply(Fixture.event(.toolStarted, at: 2, tool: Fixture.edit))
        await store.apply(Fixture.event(.toolFinished, at: 3, tool: Fixture.edit))

        #expect(await store.snapshot().onlySession?.currentTool == Fixture.bash)
    }

    /// Closing nothing would leave the watchdog believing a tool is running for
    /// ever, which is the worse of the two mistakes available here.
    @Test("A finish that matches nothing still closes the newest call")
    func unmatchedFinishClosesTheNewestCall() async {
        let store = store()
        await store.apply(Fixture.event(.toolStarted, at: 1, tool: Fixture.bash))
        await store.apply(Fixture.event(.toolFinished, at: 2, tool: ToolRef(name: "Grep")))

        #expect(await store.snapshot().onlySession?.currentTool == nil)
    }

    @Test("A finish naming a call that never started changes nothing")
    func finishForUnknownIdentifierIsHarmless() async {
        let store = store()
        await store.apply(
            Fixture.event(.toolStarted, at: 1, tool: Fixture.bash, toolUseId: "tool-1"))
        await store.apply(
            Fixture.event(.toolFinished, at: 2, tool: Fixture.edit, toolUseId: "tool-9"))

        #expect(await store.snapshot().onlySession?.currentTool == Fixture.bash)
    }

    /// Without an identifier nothing can recognise a repeat, so a doubly
    /// delivered start leaves a tool open. The turn boundary is what bounds it.
    @Test("A turn boundary closes tool calls no finish ever matched")
    func turnBoundaryClosesLeakedCalls() async {
        let store = store()
        let start = Fixture.event(.toolStarted, at: 1, tool: Fixture.bash)
        await store.apply(start)
        await store.apply(start)
        await store.apply(Fixture.event(.toolFinished, at: 2, tool: Fixture.bash))
        #expect(await store.snapshot().onlySession?.currentTool == Fixture.bash)

        await store.apply(Fixture.event(.turnFinished, at: 3))
        #expect(await store.snapshot().onlySession?.currentTool == nil)
    }

    @Test("The list of open calls is bounded")
    func openCallsAreBounded() async {
        let clock = ManualTimeSource()
        let store = SessionStore(clock: clock)
        for index in 0..<(SessionRecord.openToolLimit + 20) {
            await store.apply(
                Fixture.event(
                    .toolStarted, at: TimeInterval(index),
                    tool: ToolRef(name: "Tool\(index)"), toolUseId: "tool-\(index)"))
        }

        // The newest call is still the one shown, and the oldest were dropped
        // rather than accumulating for the life of the session.
        let expected = ToolRef(name: "Tool\(SessionRecord.openToolLimit + 19)")
        #expect(await store.snapshot().onlySession?.currentTool == expected)
    }
}
