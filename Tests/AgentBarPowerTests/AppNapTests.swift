import AgentBarCore
import Foundation
import Testing

@testable import AgentBarPower

/// App Nap, and the renewal loop it would otherwise throttle.
///
/// > **Why this is not theatre.** AgentBar is `LSUIElement` with no visible
/// > window for most of its life, which is textbook App Nap eligibility, and App
/// > Nap throttles timers. The lease is a hundred and fifty seconds against a
/// > thirty-second renewal, so five throttled periods still fit — but nothing
/// > measured that, and the failure mode is the Mac sleeping under a running
/// > build, which is the one thing the feature exists to prevent. An activity
/// > held for exactly as long as a hold is wanted removes the question.
@MainActor
@Suite("App Nap")
struct AppNapTests {

    private func controller(
        assertion: RecordingAssertion, appNap: RecordingAppNapSuppression
    ) -> CaffeineController {
        CaffeineController(
            assertion: assertion,
            settings: InMemoryCaffeineSettings(),
            appNap: appNap,
            renewalInterval: .milliseconds(20),
            lease: .milliseconds(200))
    }

    @Test("Nothing is suppressed while nothing is working")
    func idleAppNaps() async {
        let appNap = RecordingAppNapSuppression()
        let controller = controller(assertion: RecordingAssertion(), appNap: appNap)
        defer { controller.stop() }

        let store = SessionStore(clock: ManualTimeSource())
        await controller.start { await store.snapshot() }
        #expect(!appNap.isSuppressing)
        #expect(appNap.beginCount == 0)
    }

    @Test("A working session suppresses it, and stopping gives it back")
    func aHoldSuppressesAppNap() async {
        let clock = ManualTimeSource()
        let store = SessionStore(clock: clock)
        let appNap = RecordingAppNapSuppression()
        let controller = controller(assertion: RecordingAssertion(), appNap: appNap)
        defer { controller.stop() }

        await store.apply(Fixture.event(.turnStarted, at: 1))
        await controller.start { await store.snapshot() }
        #expect(appNap.isSuppressing)
        #expect(appNap.lastReason == CaffeineController.assertionName)

        await store.apply(Fixture.event(.turnFinished, at: 2))
        await controller.evaluate()
        #expect(!appNap.isSuppressing)
    }

    /// A renewal is not a second activity: the suppression is a state, and an
    /// unbalanced begin would leave App Nap off for the life of the process.
    @Test("Renewals do not stack activities")
    func renewalsDoNotStack() async {
        let clock = ManualTimeSource()
        let store = SessionStore(clock: clock)
        let appNap = RecordingAppNapSuppression()
        let controller = controller(assertion: RecordingAssertion(), appNap: appNap)
        defer { controller.stop() }

        await store.apply(Fixture.event(.turnStarted, at: 1))
        await controller.start { await store.snapshot() }
        await controller.evaluate()
        await controller.evaluate()
        #expect(appNap.beginCount == 1)
        #expect(appNap.endCount == 0)
    }

    /// The path a quit takes. Leaving the activity behind would be the same
    /// class of leak as leaving the assertion behind.
    @Test("Stopping ends the activity as well as the assertion")
    func stoppingEndsTheActivity() async {
        let clock = ManualTimeSource()
        let store = SessionStore(clock: clock)
        let appNap = RecordingAppNapSuppression()
        let assertion = RecordingAssertion()
        let controller = controller(assertion: assertion, appNap: appNap)

        await store.apply(Fixture.event(.turnStarted, at: 1))
        await controller.start { await store.snapshot() }
        #expect(appNap.isSuppressing)

        controller.stop()
        #expect(!appNap.isSuppressing)
        #expect(!assertion.isHeld)
    }
}
