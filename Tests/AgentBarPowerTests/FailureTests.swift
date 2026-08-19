import AgentBarCore
import Testing

@testable import AgentBarPower

/// What the interface is told when the system will not co-operate.
///
/// An indicator claiming to keep the Mac awake while the assertion was refused
/// is worse than no indicator: the only other symptom is a Mac that went to
/// sleep during a build, hours later, with nothing to connect the two.
@MainActor
@Suite("Caffeine failures")
struct FailureTests {

    private func controller(
        _ assertion: RecordingAssertion
    ) -> CaffeineController {
        CaffeineController(assertion: assertion, settings: InMemoryCaffeineSettings())
    }

    @Test("A refused assertion is reported and never claimed")
    func refusedTakeIsReported() async {
        let assertion = RecordingAssertion()
        assertion.refusesTake = PowerAssertionError(
            operation: "IOPMAssertionCreateWithProperties", code: -536_870_206)
        let store = SessionStore(clock: ManualTimeSource())
        let controller = controller(assertion)
        await controller.start { await store.snapshot() }

        await store.apply(Fixture.event(.turnStarted, at: 1))
        await controller.evaluate()

        #expect(!assertion.isHeld)
        #expect(!controller.reading.isHolding)
        #expect(controller.reading.failure != nil)
    }

    /// A lease that failed to re-arm is an assertion held now and gone shortly.
    /// The reading has to be able to say both things at once.
    @Test("A refused renewal keeps the hold and still reports the fault")
    func refusedRenewalIsReported() async {
        let assertion = RecordingAssertion()
        let store = SessionStore(clock: ManualTimeSource())
        let controller = controller(assertion)
        await controller.start { await store.snapshot() }

        await store.apply(Fixture.event(.turnStarted, at: 1))
        await controller.evaluate()
        #expect(controller.reading.isHolding)
        #expect(controller.reading.failure == nil)

        assertion.refusesRenew = PowerAssertionError(
            operation: "IOPMAssertionSetProperty(Timeout)", code: -536_870_206)
        await controller.evaluate()
        #expect(controller.reading.isHolding)
        #expect(controller.reading.failure != nil)
    }

    @Test("A fault clears once the system co-operates again")
    func faultClears() async {
        let assertion = RecordingAssertion()
        assertion.refusesTake = PowerAssertionError(operation: "take", code: -1)
        let store = SessionStore(clock: ManualTimeSource())
        let controller = controller(assertion)
        await controller.start { await store.snapshot() }

        await store.apply(Fixture.event(.turnStarted, at: 1))
        await controller.evaluate()
        #expect(controller.reading.failure != nil)

        assertion.refusesTake = nil
        await controller.evaluate()
        #expect(controller.reading.isHolding)
        #expect(controller.reading.failure == nil)
    }

    /// The holder drops the id whatever the release returned, so a refusal
    /// cannot leave the controller believing it still holds something it can no
    /// longer let go of.
    @Test("A refused release still leaves nothing held")
    func refusedReleaseStillClears() async {
        let assertion = RecordingAssertion()
        assertion.refusesRelease = PowerAssertionError(
            operation: "IOPMAssertionRelease", code: -536_870_206)
        let store = SessionStore(clock: ManualTimeSource())
        let controller = controller(assertion)
        await controller.start { await store.snapshot() }

        await store.apply(Fixture.event(.turnStarted, at: 1))
        await controller.evaluate()
        #expect(assertion.isHeld)

        await store.apply(Fixture.event(.turnFinished, at: 2))
        await controller.evaluate()
        #expect(!assertion.isHeld)
        #expect(!controller.reading.isHolding)
        #expect(controller.reading.failure != nil)
    }
}
