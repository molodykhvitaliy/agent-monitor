import AgentBarCore
import Foundation
import Testing

@testable import AgentBarNotifications

/// The router's own moving parts: the coalescing timer, `stop()`, and the test
/// button.
///
/// Split from `RouterTests`, which is about what a state change turns into. This
/// suite is about **when** — the only stateful part of the module, and the part
/// a decision test driving `flush()` by hand can never reach.
@MainActor
@Suite("Notification router lifecycle")
struct RouterLifecycleTests {

    private var shippedSounds: SoundLibrary { RouterHarness.shippedSounds }

    /// The scheduling itself, rather than the decision: everything else drives
    /// `flush()` by hand, so without this nothing would notice a window that
    /// never closes.
    @Test("A recorded change is delivered when the window closes, with nothing else called")
    func scheduledFlushFiresOnItsOwn() async throws {
        let presenter = RecordingPresenter()
        let router = await shortWindowRouter(presenter: presenter)
        router.record([Fixture.change()])
        #expect(presenter.posted.isEmpty)

        // Waited *for*, not slept through. The claim is that the flush happens
        // with nobody driving it, and a fixed sleep tests that claim against the
        // scheduler as well: the window is 40 ms, but under a saturated
        // cooperative pool — this suite runs alongside every other — the task
        // that closes it can be minutes of CPU-seconds away from its turn. That
        // is what made this the one test in the repository that failed under
        // parallel load, roughly one run in three, while the code was correct
        // every time.
        try await untilPosted(presenter, within: .seconds(5))
        #expect(presenter.posted.count == 1)
    }

    @Test("A human-required event bypasses even a long coalescing window")
    func urgentDeliveryIsImmediate() async throws {
        let presenter = RecordingPresenter()
        let router = NotificationRouter(
            presenter: presenter,
            store: InMemoryNotificationSettings(),
            sounds: shippedSounds,
            clock: ManualClock(),
            calendar: Calendar(identifier: .gregorian),
            coalescingWindow: .seconds(60))
        await router.start()

        router.record([Fixture.change(to: .waitingInput(question: "Which branch?"))])
        // This suite runs beside hundreds of tests on the cooperative pool, so
        // wall time is not a stable latency oracle. A sixty-second configured
        // window and a bounded wait prove the event took the zero-delay path;
        // the isolated acceptance probe measures the 100 ms product budget.
        try await untilPosted(presenter, within: .seconds(5))
        #expect(presenter.posted.count == 1)
        #expect(presenter.posted.first?.title.hasPrefix("Question") == true)
        router.stop()
    }

    @Test("A new urgent state prevents stale Finished from replacing its banner")
    func urgentStateInvalidatesPendingFinished() async throws {
        let presenter = RecordingPresenter()
        let router = NotificationRouter(
            presenter: presenter,
            store: InMemoryNotificationSettings(),
            sounds: shippedSounds,
            clock: ManualClock(),
            calendar: Calendar(identifier: .gregorian),
            coalescingWindow: .seconds(60))
        await router.start()
        router.record([
            Fixture.change(to: .idle, at: Fixture.epoch),
            Fixture.change(
                to: .waitingInput(question: "Continue?"),
                at: Fixture.epoch.addingTimeInterval(0.1)),
        ])

        try await untilPosted(presenter, within: .seconds(5))
        router.stop()
        await router.flush()

        #expect(presenter.posted.map(\.title) == ["Question · Claude Code · agentbar"])
    }

    /// Isolated wall-clock acceptance proof. The ordinary suite leaves this
    /// gated because hundreds of parallel tests can starve the cooperative pool
    /// without changing the router's timer-free path.
    ///
    /// Gated through a trait rather than an early `return`, so a run without the
    /// variable reports **skipped**. The guard this replaced reported *passed*,
    /// which is why the measurement went unnoticed and unmeasured in CI until
    /// `make timing-proofs` existed to supply the variable.
    ///
    /// The 100 ms bound is measured against 2.5-8.2 ms over five isolated runs
    /// on a developer Mac, and the queue is one async round trip — but it has
    /// never run on a three-core runner. If it starts failing there, the answer
    /// is the one `LatencyTests` documents, not a bigger number.
    @Test(
        "Urgent notification queue latency stays below 100 ms when isolated",
        .enabled(
            if: ProcessInfo.processInfo.environment["AGENTBAR_NOTIFICATION_LATENCY_PROOF"]
                == "1"))
    func urgentLatencyProof() async {
        let presenter = RecordingPresenter()
        let router = await RouterHarness.started(presenter: presenter, sounds: shippedSounds)
        let started = ContinuousClock.now

        router.record([
            Fixture.change(
                to: .waitingPermission(
                    PermissionRequestRef(id: PermissionRequestID("permission"))))
        ])
        let deadline = started + .seconds(1)
        while presenter.posted.isEmpty, ContinuousClock.now < deadline {
            await Task.yield()
        }
        let elapsed = ContinuousClock.now - started
        print("urgent notification queue latency: \(elapsed)")
        #expect(presenter.posted.count == 1)
        #expect(elapsed < .milliseconds(100))
        router.stop()
    }

    /// Polls until the presenter has something, or gives up.
    ///
    /// Generous, because the deadline is not what is being measured — the
    /// alternative to waiting long enough is a suite that fails for reasons that
    /// have nothing to do with the code.
    private func untilPosted(
        _ presenter: RecordingPresenter, within limit: Duration
    ) async throws {
        let deadline = ContinuousClock.now + limit
        while presenter.posted.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// `try? await Task.sleep` swallows the cancellation, so a cancelled task
    /// runs on to its next statement. Without an explicit check that is an app
    /// announcing five agents on its way out.
    @Test("A stop during the window cancels the batch rather than posting it")
    func stopCancelsThePendingBatch() async throws {
        let presenter = RecordingPresenter()
        let router = await shortWindowRouter(presenter: presenter)
        router.record([Fixture.change()])
        router.stop()

        try await Task.sleep(for: .milliseconds(200))
        #expect(presenter.posted.isEmpty)
    }

    private func shortWindowRouter(presenter: RecordingPresenter) async -> NotificationRouter {
        let router = NotificationRouter(
            presenter: presenter,
            store: InMemoryNotificationSettings(),
            sounds: SoundLibrary(
                userDirectory: URL(filePath: "/nonexistent", directoryHint: .isDirectory)),
            clock: ManualClock(),
            calendar: Calendar(identifier: .gregorian),
            coalescingWindow: .milliseconds(40))
        await router.start()
        return router
    }

    @Test("A test sends one notification per enabled event")
    func testNotifications() async {
        let presenter = RecordingPresenter()
        let router = await RouterHarness.started(presenter: presenter, sounds: shippedSounds)
        let outcome = await router.sendTestNotifications(for: .claudeCode)

        #expect(outcome == .sent(count: NotificationEvent.allCases.count))
        #expect(presenter.posted.count == NotificationEvent.allCases.count)
        #expect(Set(presenter.posted.map(\.identifier)).count == NotificationEvent.allCases.count)
        #expect(presenter.posted.allSatisfy { $0.title.hasSuffix("AgentBar") })
    }

    /// The test shows what the user will actually get, so a disabled event sends
    /// nothing — unlike quiet hours, which are bypassed because the settings
    /// window is frontmost by definition.
    @Test("A test respects the matrix but not quiet hours")
    func testRespectsTheMatrix() async {
        var settings = NotificationSettings()
        settings.update(
            EventPreference(
                provider: .claudeCode, event: .finished, isEnabled: false, sound: .systemDefault))
        settings.quietHours = QuietHours(isEnabled: true, startMinute: 0, endMinute: 23 * 60 + 59)

        let presenter = RecordingPresenter()
        let router = await RouterHarness.started(
            presenter: presenter, settings: settings, sounds: shippedSounds)
        let outcome = await router.sendTestNotifications(for: .claudeCode)

        #expect(outcome == .sent(count: NotificationEvent.allCases.count - 1))
        #expect(presenter.posted.count == NotificationEvent.allCases.count - 1)
        #expect(!presenter.posted.contains { $0.title.hasPrefix("Finished") })
    }

    /// The button whose entire purpose is proving that notifications arrive
    /// must never report success having sent nothing — the exact position a user
    /// following the recovery in `platform-integration.md` §6.3 is in.
    @Test("A test that sends nothing says so, for each reason it could not")
    func testReportsWhyItSentNothing() async {
        let denied = RecordingPresenter(status: .denied)
        let unauthorised = RouterHarness.router(presenter: denied)
        await unauthorised.start()
        #expect(await unauthorised.sendTestNotifications(for: .claudeCode) == .notAuthorised)
        #expect(denied.posted.isEmpty)

        var off = NotificationSettings()
        off.isEnabled = false
        let switchedOff = await RouterHarness.started(
            presenter: RecordingPresenter(), settings: off, sounds: shippedSounds)
        #expect(await switchedOff.sendTestNotifications(for: .claudeCode) == .notificationsOff)

        var silentMatrix = NotificationSettings()
        for event in NotificationEvent.allCases {
            silentMatrix.update(
                EventPreference(
                    provider: .claudeCode, event: event, isEnabled: false,
                    sound: .systemDefault))
        }
        let allDisabled = await RouterHarness.started(
            presenter: RecordingPresenter(), settings: silentMatrix, sounds: shippedSounds)
        #expect(await allDisabled.sendTestNotifications(for: .claudeCode) == .everyEventDisabled)
    }

    @Test("A notification centre that refuses is reported, not counted as sent")
    func testReportsAPresenterFailure() async {
        let presenter = RecordingPresenter()
        presenter.failure = "delivery refused"
        let router = await RouterHarness.started(presenter: presenter, sounds: shippedSounds)
        #expect(
            await router.sendTestNotifications(for: .claudeCode)
                == .failed(reason: "delivery refused"))
    }
}
