import AgentBarCore
import Foundation
import Testing

@testable import AgentBarPower

/// The renewal loop, driven by itself.
///
/// Every other suite steps the controller by calling `evaluate()`. The running
/// app has no such caller: once the assertion is held, the loop is the **only**
/// thing that re-reads the store, because a session stuck in `working` produces
/// no events by definition and the menu bar's clock does not reach this module.
/// So the step's central claim — a stuck session cannot hold the Mac awake for
/// ever — is only proven here.
///
/// The timings are shortened through the initialiser rather than waited out. The
/// sleeps are real and deliberately generous: these assert that something
/// happens, or that nothing does, not when.
@MainActor
@Suite("Caffeine renewal")
struct RenewalTests {

    private static let interval: Duration = .milliseconds(20)
    /// Several intervals, so a test that waits this long has given the loop
    /// every chance to run.
    private static let settle: Duration = .milliseconds(250)

    private func controller(
        store: SessionStore, assertion: RecordingAssertion
    ) -> CaffeineController {
        CaffeineController(
            assertion: assertion,
            settings: InMemoryCaffeineSettings(),
            renewalInterval: Self.interval,
            lease: .milliseconds(200))
    }

    /// The requirement, proven against the path the app actually takes: nothing
    /// calls `evaluate()` after the hold begins.
    @Test("A stuck session loses the assertion with nobody driving the controller")
    func loopCarriesTheWatchdogVerdict() async throws {
        let clock = ManualTimeSource()
        let store = SessionStore(clock: clock)
        let assertion = RecordingAssertion()
        let controller = controller(store: store, assertion: assertion)
        defer { controller.stop() }

        await store.apply(Fixture.event(.turnStarted, at: 1))
        await controller.start { await store.snapshot() }
        #expect(assertion.isHeld)

        // Past the fifteen minutes a silent working session is allowed. From
        // here nothing external touches the controller.
        clock.advance(by: .minutes(20))
        try await Task.sleep(for: Self.settle)
        #expect(!assertion.isHeld)
        #expect(!controller.reading.isHolding)
    }

    @Test("The loop stops when the assertion is given back")
    func loopStopsAfterRelease() async throws {
        let clock = ManualTimeSource()
        let store = SessionStore(clock: clock)
        let assertion = RecordingAssertion()
        let controller = controller(store: store, assertion: assertion)
        defer { controller.stop() }

        await store.apply(Fixture.event(.turnStarted, at: 1))
        await controller.start { await store.snapshot() }
        await store.apply(Fixture.event(.turnFinished, at: 2))
        await controller.evaluate()
        #expect(!assertion.isHeld)

        let settled = assertion.calls.count
        try await Task.sleep(for: Self.settle)
        #expect(
            assertion.calls.count == settled,
            "a released assertion left a timer waking the process for nothing")
    }

    @Test("Stopping ends the loop")
    func stopEndsTheLoop() async throws {
        let store = SessionStore(clock: ManualTimeSource())
        let assertion = RecordingAssertion()
        let controller = controller(store: store, assertion: assertion)

        await store.apply(Fixture.event(.turnStarted, at: 1))
        await controller.start { await store.snapshot() }
        #expect(assertion.isHeld)

        controller.stop()
        let settled = assertion.calls.count
        try await Task.sleep(for: Self.settle)
        #expect(assertion.calls.count == settled)
        #expect(!assertion.isHeld)
    }

    /// A refusal must not be final. A session in the middle of a long `Bash`
    /// call is entitled to an hour of silence, so "retry on the next event"
    /// means "sleep through the build".
    @Test("A refused assertion is retried without waiting for another event")
    func refusalIsRetried() async throws {
        let store = SessionStore(clock: ManualTimeSource())
        let assertion = RecordingAssertion()
        assertion.refusesTake = PowerAssertionError(operation: "take", code: -1)
        let controller = controller(store: store, assertion: assertion)
        defer { controller.stop() }

        await store.apply(Fixture.event(.turnStarted, at: 1))
        await controller.start { await store.snapshot() }
        #expect(!assertion.isHeld)
        #expect(controller.reading.failure != nil)

        assertion.refusesTake = nil
        try await Task.sleep(for: Self.settle)
        #expect(assertion.isHeld, "the controller never tried again")
        #expect(controller.reading.failure == nil)
    }

    /// Repeated evaluations must not stack loops: two would double the wake-ups
    /// and the IOKit traffic, in the module whose subject is battery.
    @Test("Evaluating repeatedly does not stack renewal loops")
    func loopIsNotStacked() async throws {
        let store = SessionStore(clock: ManualTimeSource())
        let assertion = RecordingAssertion()
        let controller = controller(store: store, assertion: assertion)
        defer { controller.stop() }

        await store.apply(Fixture.event(.turnStarted, at: 1))
        await controller.start { await store.snapshot() }
        for _ in 0..<5 { await controller.evaluate() }

        let before = assertion.renewals
        try await Task.sleep(for: Self.settle)
        let ticks = assertion.renewals - before
        // A single loop at 20 ms over 250 ms is about a dozen; two would be
        // about two dozen. The bound is deliberately loose — this is about
        // whether a second loop exists, not about scheduler precision.
        #expect(ticks > 0, "the loop is not running at all")
        #expect(ticks < 25, "more than one renewal loop is running")
    }
}
