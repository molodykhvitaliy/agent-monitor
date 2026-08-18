import Foundation
import Testing

@testable import AgentBarCore

/// Claude Code posts its hooks asynchronously, so the order they arrive in is
/// not the order they happened in.
@Suite("Out-of-order deliveries")
struct EventOrderingTests {

    @Test("A tool call that lands after the turn ended does not restart it")
    func lateToolEventDoesNotRestartTurn() async {
        let store = SessionStore(clock: ManualTimeSource())
        await store.apply(Fixture.event(.turnStarted, at: 1))
        await store.apply(Fixture.event(.turnFinished, at: 5))

        let late = await store.apply(
            Fixture.event(.toolStarted, at: 3, tool: Fixture.bash, toolUseId: "tool-1"))

        #expect(late.ignoreReason == .outOfOrder)
        #expect(await store.snapshot().onlySession?.state == .idle)
    }

    /// The alternative is a ghost session sitting on the list until the
    /// watchdog notices, for no gain: an end is terminal and idempotent.
    @Test("A farewell is honoured even when it arrives out of order")
    func lateSessionEndIsHonoured() async {
        let store = SessionStore(clock: ManualTimeSource())
        await store.apply(Fixture.event(.sessionStarted, at: 1))
        await store.apply(Fixture.event(.toolStarted, at: 9, toolUseId: "tool-1"))

        let farewell = await store.apply(Fixture.event(.sessionEnded, at: 5))

        #expect(farewell.stateChange?.to == nil)
        #expect(await store.snapshot().sessions.isEmpty)
    }

    @Test("An event stamped before the farewell cannot revive a finished session")
    func straggleAfterEndIsIgnored() async {
        let store = SessionStore(clock: ManualTimeSource())
        await store.apply(Fixture.event(.turnStarted, at: 1))
        await store.apply(Fixture.event(.sessionEnded, at: 5))

        let straggler = await store.apply(Fixture.event(.toolStarted, at: 4, toolUseId: "tool-1"))

        #expect(straggler.ignoreReason == .sessionAlreadyEnded)
        #expect(await store.snapshot().sessions.isEmpty)
    }

    /// Claude Code reuses the session id when a session is resumed, so an id
    /// that ended is not finished for ever.
    @Test("A resumed session with a reused id starts again")
    func resumedSessionIsReadmitted() async {
        let store = SessionStore(clock: ManualTimeSource())
        await store.apply(Fixture.event(.turnStarted, at: 1))
        await store.apply(Fixture.event(.sessionEnded, at: 5))

        let resumed = await store.apply(Fixture.event(.sessionStarted, at: 6))

        #expect(resumed.stateChange?.from == nil)
        #expect(await store.snapshot().sessions.count == 1)
        #expect(await store.snapshot().finished.count == 1)
    }

    /// The predecessor's farewell must not kill the session that came back.
    @Test("A farewell that predates the running session is refused")
    func farewellOlderThanSessionIsRefused() async {
        let store = SessionStore(clock: ManualTimeSource())
        await store.apply(Fixture.event(.sessionStarted, at: 10))
        await store.apply(Fixture.event(.turnStarted, at: 11))

        let stale = await store.apply(Fixture.event(.sessionEnded, at: 4))

        #expect(stale.ignoreReason == .outOfOrder)
        #expect(await store.snapshot().onlySession?.state == .working)
    }

    /// The late-farewell branch is exactly the situation where the farewell's
    /// own stamp is below events that were already applied. Dating the end from
    /// that stamp would leave every event in between able to re-admit the
    /// session, and the same id would sit in the history and on the live list
    /// at once — holding a power assertion for an agent that is gone.
    @Test("A late farewell still buries every event that outran it")
    func lateFarewellBarriesEventsThatOutranIt() async {
        let store = SessionStore(clock: ManualTimeSource())
        await store.apply(Fixture.event(.sessionStarted, at: 1))
        await store.apply(Fixture.event(.toolStarted, at: 9, toolUseId: "tool-1"))
        await store.apply(Fixture.event(.sessionEnded, at: 5))

        let straggler = await store.apply(Fixture.event(.toolFinished, at: 6, toolUseId: "tool-1"))

        #expect(straggler.ignoreReason == .sessionAlreadyEnded)
        #expect(await store.snapshot().sessions.isEmpty)
        #expect(await store.snapshot().finished.first?.endedAt == Fixture.date(9))
    }

    /// Diagnostics have to name the right cause, or an ingest log reads as
    /// noise.
    @Test("A repeated farewell is reported as arriving after the end")
    func repeatedFarewellIsNamedCorrectly() async {
        let store = SessionStore(clock: ManualTimeSource())
        await store.apply(Fixture.event(.turnStarted, at: 1))
        await store.apply(Fixture.event(.sessionEnded, at: 5))

        let repeated = await store.apply(Fixture.event(.sessionEnded, at: 5))
        #expect(repeated.ignoreReason == .sessionAlreadyEnded)
    }

    @Test("A straggler cannot keep a dead session believed")
    func stragglersDoNotRenewTheWatchdog() async {
        let clock = ManualTimeSource()
        let store = SessionStore(clock: clock)
        await store.apply(Fixture.event(.turnStarted, at: 10))

        clock.advance(by: .minutes(10))
        #expect(await store.apply(Fixture.event(.turnStarted, at: 4)).ignoreReason == .outOfOrder)
        clock.advance(by: .minutes(10))

        #expect(await store.snapshot().onlySession?.state == .unknown)
    }

    /// Both providers run on this machine and the adapters stamp on receipt, so
    /// a timestamp from the future is a fault. It has to be refused at the door:
    /// the timestamp is a high-water mark, and one bad value would make every
    /// genuine event that followed look stale.
    @Test("An event stamped in the future is refused")
    func futureStampedEventIsRefused() async {
        let clock = ManualTimeSource()
        let store = SessionStore(clock: clock)
        await store.apply(Fixture.event(.turnStarted, at: 1))

        let ahead = await store.apply(Fixture.event(.toolStarted, at: 86_400, toolUseId: "t-1"))

        #expect(ahead.ignoreReason == .implausibleTimestamp)
        #expect(await store.snapshot().onlySession?.state == .working)
        #expect(await store.apply(Fixture.event(.turnFinished, at: 2)).stateChange?.to == .idle)
    }

    /// Belt and braces for the same fault: even if a bad stamp were somehow
    /// applied, a session that refuses everything afterwards must still be able
    /// to go quiet rather than hold `working` — and the power assertion — for
    /// the rest of the day.
    @Test("A session that refuses every later event is still retired")
    func sessionRefusingEverythingIsStillRetired() async {
        let clock = ManualTimeSource()
        let store = SessionStore(clock: clock)
        clock.advance(by: .hours(24))
        await store.apply(Fixture.event(.turnStarted, at: 86_400))

        for minute in 1...5 {
            clock.advance(by: .minutes(1))
            let stale = await store.apply(
                Fixture.event(.toolStarted, at: 60, toolUseId: "t-\(minute)"))
            #expect(stale.ignoreReason == .outOfOrder)
        }

        clock.advance(by: .minutes(20))
        #expect(await store.snapshot().onlySession?.state == .unknown)
        #expect(!(await store.snapshot().isAnyAgentWorking))
    }
}
