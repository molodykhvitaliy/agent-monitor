import Foundation
import Testing

@testable import AgentBarCore

/// A session stuck in `working` is the failure the watchdog exists to prevent:
/// it tells the user an agent is busy long after its process died, and it keeps
/// the Mac awake for ever doing it.
@Suite("Watchdog")
struct WatchdogTests {

    private func fixture() -> (SessionStore, ManualTimeSource) {
        let clock = ManualTimeSource()
        return (SessionStore(clock: clock), clock)
    }

    @Test("A working session with no tool call open goes unknown")
    func silentWorkGoesUnknown() async {
        let (store, clock) = fixture()
        await store.apply(Fixture.event(.turnStarted))

        clock.advance(by: .minutes(14))
        #expect(await store.snapshot().onlySession?.state == .working)

        clock.advance(by: .minutes(2))
        #expect(await store.snapshot().onlySession?.state == .unknown)
    }

    /// A single `Bash` running a test suite legitimately emits nothing for tens
    /// of minutes. Calling that session unknown would drop the power assertion
    /// in the middle of the build.
    @Test("A long-running tool call is not mistaken for a dead agent")
    func openToolCallBuysTime() async {
        let (store, clock) = fixture()
        await store.apply(Fixture.event(.toolStarted, tool: Fixture.bash, toolUseId: "tool-1"))

        clock.advance(by: .minutes(40))
        #expect(await store.snapshot().onlySession?.state == .working)

        clock.advance(by: .minutes(25))
        #expect(await store.snapshot().onlySession?.state == .unknown)
    }

    @Test("A tool call that returns puts the session back on the short leash")
    func closingToolRestoresShortAllowance() async {
        let (store, clock) = fixture()
        await store.apply(
            Fixture.event(.toolStarted, at: 1, tool: Fixture.bash, toolUseId: "tool-1"))
        await store.apply(
            Fixture.event(.toolFinished, at: 2, tool: Fixture.bash, toolUseId: "tool-1"))

        clock.advance(by: .minutes(16))
        #expect(await store.snapshot().onlySession?.state == .unknown)
    }

    @Test(
        "Silence is tolerated for as long as the state makes it plausible",
        arguments: [
            (EventKind.waitingInput(question: nil), Duration.hours(2)),
            (EventKind.turnFinished, Duration.minutes(10)),
            (EventKind.failed(reason: "overloaded_error"), Duration.minutes(10)),
        ]
    )
    func allowanceMatchesState(kind: EventKind, allowance: Duration) async {
        let (store, clock) = fixture()
        await store.apply(Fixture.event(kind))

        clock.advance(by: allowance - .minutes(1))
        #expect(await store.snapshot().onlySession?.state != .unknown)

        clock.advance(by: .minutes(2))
        #expect(await store.snapshot().onlySession?.state == .unknown)
    }

    @Test("An unknown session is retired rather than accumulating for ever")
    func unknownSessionIsEvicted() async {
        let (store, clock) = fixture()
        await store.apply(Fixture.event(.turnStarted))

        clock.advance(by: .minutes(16))
        let marked = await store.sweep()
        #expect(marked.count == 1)
        #expect(marked.first?.to == .unknown)

        clock.advance(by: .minutes(61))
        let evicted = await store.sweep()
        #expect(evicted.count == 1)
        #expect(evicted.first?.from == .unknown)
        #expect(evicted.first?.to == nil)

        let snapshot = await store.snapshot()
        #expect(snapshot.sessions.isEmpty)
        #expect(snapshot.finished.first?.outcome == .lost)
        #expect(
            snapshot.finished.first?.finalState == .working,
            "the panel showed unknown; what the session was doing is still worth recording")
    }

    /// A failed turn that decays over eight hours must not enter the history as
    /// a shrug — the reason is the only thing a dashboard could show.
    @Test("A retired session keeps the reason it failed for")
    func evictionKeepsTheFailureReason() async {
        let (store, clock) = fixture()
        await store.apply(Fixture.event(.failed(reason: "overloaded_error")))

        clock.advance(by: .hours(10))
        await store.sweep()

        let finished = await store.snapshot().finished.first
        #expect(finished?.finalState == .failed(reason: "overloaded_error"))
        #expect(finished?.outcome == .lost)
    }

    /// After an overnight sleep, "when the sweep noticed" is hours away from
    /// when the session actually stopped.
    @Test("A retired session is dated when it last spoke")
    func evictionIsDatedWhenTheSessionLastSpoke() async {
        let (store, clock) = fixture()
        await store.apply(Fixture.event(.turnStarted, at: 30))

        clock.advance(by: .hours(9))
        await store.sweep()

        #expect(await store.snapshot().finished.first?.endedAt == Fixture.date(30))
    }

    /// The one case the plan calls out: an agent killed without a `SessionEnd`.
    @Test("A session that never says goodbye is retired anyway")
    func sessionWithoutFarewellIsRetired() async {
        let (store, clock) = fixture()
        await store.apply(Fixture.event(.sessionStarted))
        await store.apply(Fixture.event(.turnStarted, at: 1))

        clock.advance(by: .hours(2))
        await store.sweep()

        #expect(await store.snapshot().sessions.isEmpty)
        #expect(await store.snapshot().finished.first?.outcome == .lost)
    }

    /// `ContinuousClock` keeps counting while the Mac is asleep, so a single
    /// large jump is exactly what the store sees on wake.
    @Test("A machine that slept for hours wakes to a truthful list")
    func sleepAndWakeIsHandled() async {
        let (store, clock) = fixture()
        await store.apply(Fixture.event(.toolStarted, tool: Fixture.bash, toolUseId: "tool-1"))

        clock.advance(by: .hours(9))

        let changes = await store.sweep()
        #expect(changes.count == 1)
        #expect(changes.first?.to == nil, "nine hours is past unknown and past eviction")
        #expect(await store.snapshot().sessions.isEmpty)
    }

    @Test("An unknown session comes back the moment it says something")
    func unknownSessionRecovers() async {
        let (store, clock) = fixture()
        await store.apply(Fixture.event(.turnStarted))
        clock.advance(by: .minutes(20))
        await store.sweep()
        #expect(await store.snapshot().onlySession?.state == .unknown)

        let recovery = await store.apply(
            Fixture.event(.toolStarted, at: 1_300, tool: Fixture.bash, toolUseId: "tool-1"))

        #expect(recovery.stateChange?.from == .unknown)
        #expect(await store.snapshot().onlySession?.state == .working)
    }

    /// The store has no timer of its own, so a reading taken between sweeps
    /// must not disagree with one taken after. The interval is chosen to land
    /// every session inside its own window — one derived `unknown`, one still
    /// waiting, one still building, one idle — because a sweep that evicts
    /// everything would make the comparison vacuous.
    ///
    /// The resting session is registered *after* the jump rather than before it:
    /// a resting allowance is ten minutes and there is no band beyond it in
    /// which a finished session is doubted rather than retired, so the only way
    /// to have one on the list at all is for it to be recent.
    @Test("A reading taken before a sweep matches the one taken after")
    func snapshotAgreesWithSweep() async {
        let (store, clock) = fixture()
        await store.apply(Fixture.event(.turnStarted, session: "quiet"))
        await store.apply(
            Fixture.event(.waitingInput(question: nil), session: "asking", cwd: "/Users/dev/other"))
        await store.apply(
            Fixture.event(
                .toolStarted, session: "building", tool: Fixture.bash, toolUseId: "tool-1"))

        clock.advance(by: .minutes(30))
        await store.apply(Fixture.event(.turnFinished, session: "resting", at: 1_800))

        let before = await store.snapshot()
        let changes = await store.sweep()
        let after = await store.snapshot()

        #expect(before == after, "a sweep must not change what a reading says")
        #expect(before.session("quiet")?.state == .unknown)
        #expect(before.session("asking")?.state == .waitingInput(question: nil))
        #expect(before.session("building")?.state == .working)
        #expect(before.session("resting")?.state == .idle)
        #expect(changes.map(\.sessionId.value) == ["quiet"], "only the quiet one moved")
    }

    /// The one thing a sweep does change is retiring what the watchdog has
    /// given up on — and an unswept store must still account for it.
    @Test("A session past retirement is still on the list until it is swept")
    func evictionOnlyHappensOnSweep() async {
        let (store, clock) = fixture()
        await store.apply(Fixture.event(.turnStarted))
        clock.advance(by: .hours(3))

        #expect(await store.snapshot().onlySession?.state == .unknown)
        #expect(await store.snapshot().finished.isEmpty)

        await store.sweep()
        #expect(await store.snapshot().sessions.isEmpty)
        #expect(await store.snapshot().finished.count == 1)
    }

    /// A recovery must be announced once. If the flag survived the event that
    /// cleared it, the next sweep would announce the same recovery again.
    @Test("A recovery is announced exactly once")
    func recoveryIsAnnouncedOnce() async {
        let (store, clock) = fixture()
        await store.apply(Fixture.event(.turnStarted))
        clock.advance(by: .minutes(20))
        #expect(await store.sweep().first?.to == .unknown)

        let recovery = await store.apply(Fixture.event(.turnStarted, at: 1_300))
        #expect(recovery.stateChange?.from == .unknown)
        #expect(await store.sweep().isEmpty, "the recovery was already announced")
    }

    /// And a session that goes quiet again must be announced again.
    @Test("A second silence is announced again")
    func secondSilenceIsAnnouncedAgain() async {
        let (store, clock) = fixture()
        await store.apply(Fixture.event(.turnStarted))
        clock.advance(by: .minutes(20))
        #expect(await store.sweep().count == 1)

        // The event itself announces the recovery, so there is nothing left for
        // a sweep to say until the session goes quiet a second time.
        let recovery = await store.apply(Fixture.event(.turnStarted, at: 1_300))
        #expect(recovery.stateChange?.from == .unknown)

        clock.advance(by: .minutes(20))
        let second = await store.sweep()
        #expect(second.first?.from == .working)
        #expect(second.first?.to == .unknown)
        #expect(await store.sweep().isEmpty)
    }

    /// A session announced as quiet that then says goodbye must report the move
    /// the rest of the app can actually follow.
    @Test("A farewell after silence is reported from unknown")
    func farewellAfterSilenceIsReportedFromUnknown() async {
        let (store, clock) = fixture()
        await store.apply(Fixture.event(.turnStarted))
        clock.advance(by: .minutes(20))
        await store.sweep()

        let farewell = await store.apply(Fixture.event(.sessionEnded, at: 1_300))

        #expect(farewell.stateChange?.from == .unknown)
        #expect(farewell.stateChange?.to == nil)
        #expect(await store.snapshot().finished.first?.outcome == .ended)
    }

    /// An announcement about a session already running is a heartbeat, but a
    /// heartbeat is exactly what a session announced as quiet needs.
    @Test("A repeated announcement brings back a session announced as quiet")
    func announcementRevivesAnnouncedSession() async {
        let (store, clock) = fixture()
        await store.apply(Fixture.event(.turnStarted))
        clock.advance(by: .minutes(20))
        await store.sweep()

        let outcome = await store.apply(Fixture.event(.sessionStarted, at: 1_300))

        #expect(outcome.stateChange?.from == .unknown)
        #expect(outcome.stateChange?.to == .working)
        #expect(await store.snapshot().onlySession?.state == .working)
    }

    @Test("Watchdog transitions are reported in a stable order")
    func sweepIsDeterministic() async {
        let (store, clock) = fixture()
        for name in ["c", "a", "b"] {
            await store.apply(Fixture.event(.turnStarted, session: name))
        }
        clock.advance(by: .minutes(20))

        let changes = await store.sweep()
        #expect(changes.map(\.sessionId.value) == ["a", "b", "c"])
    }

    @Test("A sweep with nothing to do reports nothing")
    func quietSweepIsSilent() async {
        let (store, clock) = fixture()
        await store.apply(Fixture.event(.turnStarted))
        clock.advance(by: .minutes(20))

        #expect(await store.sweep().count == 1)
        #expect(await store.sweep().isEmpty, "the second sweep must not report the same move")
    }

    /// Durations come from the monotonic clock, so NTP corrections and a user
    /// changing the date cannot make a session look stale or fresh.
    @Test("Moving the wall clock does not move the watchdog")
    func wallClockSkewIsIgnored() async {
        let (store, clock) = fixture()
        await store.apply(Fixture.event(.turnStarted))

        clock.skewWallClock(by: .hours(-5))
        #expect(await store.snapshot().onlySession?.state == .working)

        clock.skewWallClock(by: .hours(10))
        #expect(await store.snapshot().onlySession?.state == .working)

        clock.advance(by: .minutes(16))
        #expect(await store.snapshot().onlySession?.state == .unknown)
    }

    @Test("An unknown session reports how long it has been silent")
    func unknownSessionReportsSilence() async {
        let (store, clock) = fixture()
        await store.apply(Fixture.event(.turnStarted))
        clock.advance(by: .minutes(21))

        let session = await store.snapshot().onlySession
        #expect(session?.timeSinceLastEvent == .minutes(21))
        #expect(session?.timeInState == .minutes(6), "unknown began when the allowance ran out")
    }
}
