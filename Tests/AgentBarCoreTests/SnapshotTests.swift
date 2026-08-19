import Foundation
import Testing

@testable import AgentBarCore

@Suite("Snapshots")
struct SnapshotTests {

    @Test("An empty store reports an empty snapshot")
    func emptyStoreIsEmpty() async {
        let snapshot = await SessionStore(clock: ManualTimeSource()).snapshot()

        #expect(snapshot.isEmpty)
        #expect(snapshot.mostUrgentState == nil)
        #expect(!snapshot.isAnyAgentWorking)
        #expect(snapshot.waitingSessionCount == 0)
    }

    /// The status-bar icon shows one state for the whole machine, and the
    /// design system fixes which one wins.
    @Test("The most urgent state present is the one reported")
    func urgencyOrderIsRespected() async {
        let store = SessionStore(clock: ManualTimeSource())
        await store.apply(Fixture.event(.turnFinished, session: "idle"))
        await store.apply(Fixture.event(.turnStarted, session: "busy"))
        #expect(await store.snapshot().mostUrgentState == .working)

        await store.apply(Fixture.event(.failed(reason: "api"), session: "broken"))
        #expect(await store.snapshot().mostUrgentState == .failed)

        await store.apply(Fixture.event(.waitingInput(question: nil), session: "asking"))
        #expect(await store.snapshot().mostUrgentState == .waiting)
    }

    @Test("Sessions waiting on the human are counted for the icon's badge")
    func waitingSessionsAreCounted() async {
        let store = SessionStore(clock: ManualTimeSource())
        await store.apply(Fixture.event(.waitingInput(question: nil), session: "a"))
        let request = PermissionRequestRef(id: PermissionRequestID("req"))
        await store.apply(Fixture.event(.waitingPermission(request), session: "b"))
        await store.apply(Fixture.event(.turnStarted, session: "c"))

        #expect(await store.snapshot().waitingSessionCount == 2)
    }

    /// What Caffeine keys off. A session that is merely idle must never hold
    /// the Mac awake.
    @Test("Only a working session counts as work in progress")
    func workInProgressIsOnlyWorking() async {
        let store = SessionStore(clock: ManualTimeSource())
        await store.apply(Fixture.event(.waitingInput(question: nil), session: "asking"))
        await store.apply(Fixture.event(.turnFinished, session: "idle"))
        #expect(!(await store.snapshot().isAnyAgentWorking))

        await store.apply(Fixture.event(.turnStarted, session: "busy"))
        #expect(await store.snapshot().isAnyAgentWorking)
    }

    @Test("A tool is only shown while the session is working")
    func toolIsHiddenWhenNotWorking() async {
        let store = SessionStore(clock: ManualTimeSource())
        await store.apply(Fixture.event(.toolStarted, tool: Fixture.bash, toolUseId: "tool-1"))
        #expect(await store.snapshot().onlySession?.currentTool == Fixture.bash)

        await store.apply(Fixture.event(.waitingInput(question: nil), at: 1))
        #expect(await store.snapshot().onlySession?.currentTool == nil)
    }

    @Test("Durations are measured, not derived from timestamps")
    func durationsComeFromTheMonotonicClock() async {
        let clock = ManualTimeSource()
        let store = SessionStore(clock: clock)
        await store.apply(Fixture.event(.turnStarted))
        clock.advance(by: .minutes(4))
        await store.apply(Fixture.event(.waitingInput(question: nil), at: 240))
        clock.advance(by: .minutes(1))

        let session = await store.snapshot().onlySession
        #expect(session?.uptime == .minutes(5))
        #expect(session?.timeInState == .minutes(1))
        #expect(session?.timeSinceLastEvent == .minutes(1))
    }

    @Test("Sessions in a group are ordered oldest first")
    func sessionsAreOrderedOldestFirst() async {
        let store = SessionStore(clock: ManualTimeSource())
        await store.apply(Fixture.event(.turnStarted, session: "second", at: 20))
        await store.apply(Fixture.event(.turnStarted, session: "first", at: 10))

        let ids = await store.snapshot().sessions.map(\.id.value)
        #expect(ids == ["first", "second"])
    }

    @Test("Finished sessions are remembered, most recent first")
    func historyIsMostRecentFirst() async {
        let store = SessionStore(clock: ManualTimeSource())
        for name in ["a", "b"] {
            await store.apply(Fixture.event(.turnStarted, session: name))
            await store.apply(Fixture.event(.sessionEnded, session: name, at: 10))
        }

        let finished = await store.snapshot().finished
        #expect(finished.map(\.sessionId.value) == ["b", "a"])
        #expect(finished.first?.endedAt == Fixture.date(10))
    }

    /// The store is long-lived and a busy day is hundreds of sessions.
    @Test("The history is bounded")
    func historyIsBounded() async {
        let store = SessionStore(clock: ManualTimeSource(), historyLimit: 32)
        for index in 0..<50 {
            let name = "session-\(index)"
            await store.apply(Fixture.event(.turnStarted, session: name))
            await store.apply(Fixture.event(.sessionEnded, session: name, at: 1))
        }

        let finished = await store.snapshot().finished
        #expect(finished.count == 32)
        #expect(finished.first?.sessionId == SessionID("session-49"))
    }

    @Test("A history limit below the floor is raised to it")
    func historyLimitHasAFloor() async {
        let store = SessionStore(clock: ManualTimeSource(), historyLimit: 5)
        for index in 0..<40 {
            let name = "session-\(index)"
            await store.apply(Fixture.event(.turnStarted, session: name))
            await store.apply(Fixture.event(.sessionEnded, session: name, at: 1))
        }

        #expect(
            await store.snapshot().finished.count == SessionStore.minimumHistoryLimit,
            "the history is also the guard against reviving an ended session")
    }

    @Test("A batch of events is applied in order")
    func batchApplyIsOrdered() async {
        let store = SessionStore(clock: ManualTimeSource())
        let outcomes = await store.apply(contentsOf: [
            Fixture.event(.sessionStarted, at: 1),
            Fixture.event(.turnStarted, at: 2),
            Fixture.event(.turnFinished, at: 3),
        ])

        #expect(outcomes.count == 3)
        #expect(outcomes.compactMap(\.stateChange?.to) == [.idle, .working, .idle])
        #expect(await store.snapshot().onlySession?.state == .idle)
    }

    @Test("A diagnostic payload is kept but bounded")
    func rawPayloadIsBounded() {
        let payload = RawPayload(summary: String(repeating: "x", count: 4096))

        #expect(payload.diagnosticSummary.count == RawPayload.summaryLimit)
        #expect(!payload.isEmpty)
        #expect(RawPayload.empty.isEmpty)
    }
}
