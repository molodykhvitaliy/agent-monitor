import AgentBarCore
import Foundation
import Testing

@testable import AgentBarPower

/// The controller against a **real** `SessionStore` on a hand-driven clock.
///
/// Deliberately not against a hand-built snapshot: the step's central claim is
/// that the watchdog is what stops a stuck session holding the Mac awake for
/// ever, and a fixture snapshot would prove nothing about it. What is faked is
/// the assertion and the clock; the domain is the real one.
@MainActor
@Suite("Caffeine lifecycle")
struct LifecycleTests {

    private struct Harness {
        let store: SessionStore
        let clock: ManualTimeSource
        let assertion: RecordingAssertion
        let controller: CaffeineController
    }

    private func harness(mode: CaffeineMode = .whileWorking) async -> Harness {
        let clock = ManualTimeSource()
        let store = SessionStore(clock: clock)
        let assertion = RecordingAssertion()
        let controller = CaffeineController(
            assertion: assertion,
            settings: InMemoryCaffeineSettings(CaffeineSettings(mode: mode)))
        // Awaited rather than fired and forgotten, so the first evaluation is
        // over before the test's own begin. `start` is awaited in the app too.
        await controller.start { await store.snapshot() }
        return Harness(store: store, clock: clock, assertion: assertion, controller: controller)
    }

    // MARK: - The ordinary arc

    @Test("A turn beginning takes the assertion, and its end gives it back")
    func turnHoldsAndReleases() async {
        let harness = await harness()
        await harness.store.apply(Fixture.event(.turnStarted, at: 1))
        await harness.controller.evaluate()
        #expect(harness.assertion.isHeld)
        #expect(harness.controller.reading.isHolding)
        #expect(harness.assertion.lastDetails == "1 agent session working in agentbar")

        await harness.store.apply(Fixture.event(.turnFinished, at: 2))
        await harness.controller.evaluate()
        #expect(!harness.assertion.isHeld)
        #expect(!harness.controller.reading.isHolding)
    }

    @Test("A session waiting on a person is not worth staying awake for")
    func waitingReleases() async {
        let harness = await harness()
        await harness.store.apply(Fixture.event(.turnStarted, at: 1))
        await harness.controller.evaluate()
        #expect(harness.assertion.isHeld)

        await harness.store.apply(
            Fixture.event(.waitingInput(question: "Which branch?"), at: 2))
        await harness.controller.evaluate()
        #expect(!harness.assertion.isHeld)
    }

    @Test("The assertion survives one session of several finishing")
    func lastWorkerReleases() async {
        let harness = await harness()
        await harness.store.apply(Fixture.event(.turnStarted, session: "a", at: 1))
        await harness.store.apply(
            Fixture.event(.turnStarted, session: "b", cwd: "/Users/dev/other", at: 1))
        await harness.controller.evaluate()
        #expect(harness.assertion.isHeld)
        #expect(harness.assertion.lastDetails == "2 agent sessions working")

        await harness.store.apply(Fixture.event(.turnFinished, session: "a", at: 2))
        await harness.controller.evaluate()
        #expect(harness.assertion.isHeld)

        await harness.store.apply(Fixture.event(.turnFinished, session: "b", at: 3))
        await harness.controller.evaluate()
        #expect(!harness.assertion.isHeld)
    }

    @Test("A session that ends without finishing its turn still gives it back")
    func sessionEndReleases() async {
        let harness = await harness()
        await harness.store.apply(Fixture.event(.turnStarted, at: 1))
        await harness.controller.evaluate()
        #expect(harness.assertion.isHeld)

        await harness.store.apply(Fixture.event(.sessionEnded, at: 2))
        await harness.controller.evaluate()
        #expect(!harness.assertion.isHeld)
    }

    // MARK: - The failure the step exists to prevent

    /// The requirement in one test: a session stuck in `working` must not hold
    /// the assertion for ever. Nothing is sweeping here on purpose — `unknown`
    /// is derived on every read, so the watchdog reaches the assertion whether
    /// or not anyone retires the session.
    @Test("A session stuck in `working` loses the assertion when the watchdog gives up")
    func stuckWorkingLosesTheAssertion() async {
        let harness = await harness()
        await harness.store.apply(Fixture.event(.turnStarted, at: 1))
        await harness.controller.evaluate()
        #expect(harness.assertion.isHeld)

        harness.clock.advance(by: .minutes(14))
        await harness.controller.evaluate()
        #expect(harness.assertion.isHeld, "the allowance for silent work is fifteen minutes")

        harness.clock.advance(by: .minutes(2))
        await harness.controller.evaluate()
        #expect(!harness.assertion.isHeld)
        #expect(!harness.controller.reading.isHolding)
    }

    /// The generous tier, and the reason it exists: one `Bash` running a full
    /// build emits nothing for tens of minutes, and dropping the assertion
    /// there would put the Mac to sleep under the build.
    @Test("A long-running tool call keeps the Mac awake, but not for ever")
    func openToolCallExtendsTheHold() async {
        let harness = await harness()
        await harness.store.apply(
            Fixture.event(.toolStarted, at: 1, tool: Fixture.bash, toolUseId: "tool-1"))
        await harness.controller.evaluate()
        #expect(harness.assertion.isHeld)

        harness.clock.advance(by: .minutes(45))
        await harness.controller.evaluate()
        #expect(harness.assertion.isHeld, "an open tool call is believed for an hour")

        harness.clock.advance(by: .minutes(20))
        await harness.controller.evaluate()
        #expect(!harness.assertion.isHeld)
    }

    /// A night's sleep with an agent left running: the machine wakes, the store
    /// reads hours of silence, and nothing may re-take the assertion on the way
    /// past. `ContinuousClock` keeps counting while the Mac is asleep, which is
    /// what makes the jump visible at all.
    @Test("Waking from a long sleep does not resurrect the hold")
    func longSleepDoesNotResurrect() async {
        let harness = await harness()
        await harness.store.apply(Fixture.event(.turnStarted, at: 1))
        await harness.controller.evaluate()
        #expect(harness.assertion.isHeld)

        harness.clock.advance(by: .hours(9))
        await harness.controller.evaluate()
        #expect(!harness.assertion.isHeld)
        #expect(harness.assertion.releases == 1)

        // And the session having been retired changes nothing.
        await harness.store.sweep()
        await harness.controller.evaluate()
        #expect(!harness.assertion.isHeld)
        #expect(harness.assertion.takes == 1, "nothing may take a second assertion")
    }

    /// A sign of life undoes the decay, because `unknown` is derived rather than
    /// stored — so the assertion has to come back with it.
    @Test("An agent that speaks again gets the assertion back")
    func recoveryRetakes() async {
        let harness = await harness()
        await harness.store.apply(Fixture.event(.turnStarted, at: 1))
        await harness.controller.evaluate()

        harness.clock.advance(by: .minutes(20))
        await harness.controller.evaluate()
        #expect(!harness.assertion.isHeld)

        await harness.store.apply(
            Fixture.event(.toolStarted, at: 2, tool: Fixture.bash, toolUseId: "tool-1"))
        await harness.controller.evaluate()
        #expect(harness.assertion.isHeld)
        #expect(harness.assertion.takes == 2)
    }

    // MARK: - Idempotence

    @Test("Evaluating repeatedly renews rather than taking a second assertion")
    func repeatedEvaluationRenews() async {
        let harness = await harness()
        await harness.store.apply(Fixture.event(.turnStarted, at: 1))
        for _ in 0..<4 { await harness.controller.evaluate() }
        #expect(harness.assertion.takes == 1)
        #expect(harness.assertion.renewals == 3)
        #expect(harness.assertion.leases.allSatisfy { $0 == CaffeineController.defaultLease })
    }

    @Test("Evaluating with nothing running releases nothing twice")
    func repeatedReleaseIsQuiet() async {
        let harness = await harness()
        for _ in 0..<3 { await harness.controller.evaluate() }
        #expect(harness.assertion.takes == 0)
        #expect(harness.assertion.releases == 0)
    }

    /// The lease exists for the failure the other two mechanisms leave open — a
    /// live process that has stopped evaluating. It is only a safety net if it
    /// is shorter than for ever and longer than the gap between renewals.
    @Test("The lease outlives several renewal intervals and is finite")
    func leaseIsASafetyNet() {
        #expect(CaffeineController.defaultLease > CaffeineController.defaultRenewalInterval * 3)
        #expect(CaffeineController.defaultLease < .minutes(10))
    }

    // MARK: - Stopping

    @Test("Stopping gives the assertion back and refuses to take another")
    func stopReleasesForGood() async {
        let harness = await harness()
        await harness.store.apply(Fixture.event(.turnStarted, at: 1))
        await harness.controller.evaluate()
        #expect(harness.assertion.isHeld)

        harness.controller.stop()
        #expect(!harness.assertion.isHeld)

        // A push in flight during termination must not revive it.
        harness.controller.stateDidChange()
        await harness.controller.evaluate()
        #expect(!harness.assertion.isHeld)
        #expect(harness.assertion.takes == 1)
    }

    /// The window between reading the store and acting on it. `stop()` landing
    /// inside it must not be followed by a take: the app is on its way out, and
    /// an assertion granted a moment later has nothing left to release it but
    /// the kernel.
    @Test("An evaluation still reading the store when the app quits takes nothing")
    func stopBeatsAnEvaluationInFlight() async {
        let store = SessionStore(clock: ManualTimeSource())
        await store.apply(Fixture.event(.turnStarted, at: 1))
        let assertion = RecordingAssertion()
        let controller = CaffeineController(
            assertion: assertion, settings: InMemoryCaffeineSettings())
        let source = GatedSnapshotSource(store: store)
        await controller.start { await source.read() }
        #expect(assertion.isHeld)

        source.isGated = true
        let pending = Task { await controller.evaluate() }
        await source.waitUntilReading()

        controller.stop()
        #expect(!assertion.isHeld)

        source.resume()
        await pending.value
        #expect(!assertion.isHeld)
        #expect(assertion.takes == 1, "the assertion was taken again after the app stopped")
    }

    @Test("A controller nobody started holds nothing")
    func unstartedControllerIsInert() async {
        let assertion = RecordingAssertion()
        let controller = CaffeineController(
            assertion: assertion, settings: InMemoryCaffeineSettings())
        await controller.evaluate()
        controller.stateDidChange()
        #expect(assertion.calls.isEmpty)
        #expect(!controller.reading.isHolding)
    }
}
