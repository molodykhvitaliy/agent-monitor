import Foundation
import Testing

@testable import AgentBarCore

/// What a working day leaves behind.
///
/// This suite exists because of a real failure: over half a day of ordinary use
/// the panel filled with sessions that had finished hours earlier, and an app
/// that renders every row on a one-second clock turned that list into sustained
/// CPU. The store was doing exactly what it was told — a finished session was
/// given eight hours of silence and then an hour of `unknown` on top — and
/// nothing anywhere asserted that the list came back down.
///
/// So these are bounds rather than behaviours. Each one fails if the retirement
/// rule is loosened, whatever else still passes.
@Suite("Accumulation")
struct AccumulationTests {

    private func fixture() -> (SessionStore, ManualTimeSource) {
        let clock = ManualTimeSource()
        return (SessionStore(clock: clock), clock)
    }

    @Test("A finished turn is retired ten minutes after it goes quiet")
    func idleSessionRetiresInTenMinutes() async {
        let (store, clock) = fixture()
        await store.apply(Fixture.event(.turnFinished))

        clock.advance(by: .minutes(9))
        await store.sweep()
        #expect(await store.snapshot().onlySession?.state == .idle, "still recent enough to show")

        clock.advance(by: .minutes(2))
        let changes = await store.sweep()

        #expect(changes.map(\.to) == [nil], "it leaves the list rather than turning unknown")
        #expect(await store.snapshot().sessions.isEmpty)
        #expect(await store.snapshot().finished.first?.outcome == .lost)
    }

    /// The failure state rests too: the notification has already fired, and a
    /// row still reporting a failure from this morning is not news.
    @Test("A failed turn is retired on the same clock as a finished one")
    func failedSessionRetiresInTenMinutes() async {
        let (store, clock) = fixture()
        await store.apply(Fixture.event(.failed(reason: "overloaded_error")))

        clock.advance(by: .minutes(11))
        await store.sweep()

        #expect(await store.snapshot().sessions.isEmpty)
        #expect(
            await store.snapshot().finished.first?.finalState == .failed(reason: "overloaded_error")
        )
    }

    /// The rule must not reach the states it was never about. A session in the
    /// middle of a long build is silent for exactly the same reason a dead one
    /// is, and telling them apart is the whole job of the separate allowances.
    @Test("Retirement does not touch a session that is still working or waiting")
    func restingRuleDoesNotShortenTheOthers() async {
        let (store, clock) = fixture()
        await store.apply(
            Fixture.event(
                .toolStarted, session: "building", tool: Fixture.bash, toolUseId: "tool-1"))
        await store.apply(
            Fixture.event(.waitingInput(question: nil), session: "asking", cwd: "/Users/dev/other"))

        clock.advance(by: .minutes(45))
        await store.sweep()

        let snapshot = await store.snapshot()
        #expect(snapshot.session("building")?.state == .working, "an hour is a legitimate build")
        #expect(snapshot.session("asking")?.state == .waitingInput(question: nil))
    }

    /// A session left idle while its output is read comes back the moment the
    /// human types, which is the cost the ten minutes buys and the reason it is
    /// affordable.
    @Test("A retired session returns the moment it says something")
    func retiredSessionIsReadmitted() async {
        let (store, clock) = fixture()
        await store.apply(Fixture.event(.turnFinished))
        clock.advance(by: .minutes(11))
        await store.sweep()
        #expect(await store.snapshot().sessions.isEmpty)

        await store.apply(Fixture.event(.turnStarted, at: 700))

        #expect(await store.snapshot().onlySession?.state == .working)
    }

    /// The shape of the day that produced the defect: a new session every ten
    /// minutes across eight hours, none of which ever says goodbye, with a sweep
    /// on the closed panel's own cadence.
    ///
    /// What is asserted is a **bound**, not a number: at no point may the store
    /// be holding more sessions than the last few could account for. Before the
    /// retirement rule this reached forty-eight, which is what the panel was
    /// rendering.
    @Test("A day of sessions that never say goodbye does not accumulate")
    func aDayOfSessionsStaysBounded() async {
        let (store, clock) = fixture()
        var highWaterMark = 0
        var elapsed = 0

        for index in 0..<48 {
            await store.apply(
                Fixture.event(
                    .turnStarted, session: "session-\(index)", at: TimeInterval(elapsed)))
            await store.apply(
                Fixture.event(
                    .turnFinished, session: "session-\(index)", at: TimeInterval(elapsed + 60)))

            // Ten minutes, swept the way the closed panel sweeps it.
            for _ in 0..<13 {
                clock.advance(by: .seconds(45))
                elapsed += 45
                await store.sweep()
                highWaterMark = max(highWaterMark, await store.snapshot().sessions.count)
            }
        }

        #expect(
            highWaterMark <= 2,
            """
            a session that finished is retired ten minutes later, so at most the \
            current one and its predecessor can be on the list at once
            """)
        #expect(await store.snapshot().sessions.count <= 2)
    }

    /// **Reading is not retiring.** The store owns no timer, so a session past
    /// its allowance stays on the list — correctly labelled `unknown`, because
    /// that is derived on every read — until somebody sweeps. Whoever owns the
    /// run loop therefore has to sweep on *every* cadence it runs, and the panel
    /// being open is not an exception: leaving it open used to mean nothing
    /// retired for as long as it stayed up.
    @Test("A reading alone never retires anything, however long it is left")
    func readingWithoutSweepingRetiresNothing() async {
        let (store, clock) = fixture()
        await store.apply(Fixture.event(.turnFinished))

        clock.advance(by: .hours(3))
        for _ in 0..<20 {
            #expect(await store.snapshot().onlySession?.state == .unknown)
        }

        await store.sweep()
        #expect(await store.snapshot().sessions.isEmpty, "only the sweep can retire it")
    }

    /// The history is the other half of the same question: it is what a retired
    /// session becomes, and an unbounded one would trade a growing list for a
    /// growing array behind it.
    @Test("The finished history is bounded whatever the day does")
    func historyStaysBounded() async {
        let (store, clock) = fixture()
        for index in 0..<400 {
            await store.apply(
                Fixture.event(.turnFinished, session: "session-\(index)", at: TimeInterval(index)))
            clock.advance(by: .minutes(11))
            await store.sweep()
        }

        #expect(await store.snapshot().finished.count == 100)
        #expect(await store.snapshot().sessions.isEmpty)
    }
}
