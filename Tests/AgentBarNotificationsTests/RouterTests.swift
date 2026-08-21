import AgentBarCore
import Foundation
import Testing

@testable import AgentBarNotifications

/// The router as the app uses it: state changes in, notifications out.
///
/// Every suppression rule and every coalescing rule is tested in its own suite;
/// these are about the wiring between them, and about the three decisions the
/// router makes on its own — the identifier, the title's fallback, and what
/// happens when a chosen sound has gone.
@MainActor
@Suite("Notification router")
struct RouterTests {

    private func router(
        presenter: RecordingPresenter,
        settings: NotificationSettings = NotificationSettings(),
        sounds: SoundLibrary? = nil,
        attachments: StubAttachments = StubAttachments(),
        frontmost: StubFrontmostApplication = StubFrontmostApplication()
    ) -> NotificationRouter {
        RouterHarness.router(
            presenter: presenter, settings: settings, sounds: sounds,
            attachments: attachments, frontmost: frontmost)
    }

    /// Every test drains the coalescer by hand and stops the scheduled flush
    /// `record` created, so none leaves a live 1.5 s timer behind — and each of
    /// them thereby also asserts that cancelling the scheduled flush does not
    /// lose what was queued for it.
    private func startedRouter(
        presenter: RecordingPresenter,
        settings: NotificationSettings = NotificationSettings(),
        sounds: SoundLibrary? = nil,
        attachments: StubAttachments = StubAttachments(),
        frontmost: StubFrontmostApplication = StubFrontmostApplication()
    ) async -> NotificationRouter {
        await RouterHarness.started(
            presenter: presenter, settings: settings, sounds: sounds,
            attachments: attachments, frontmost: frontmost)
    }

    private var shippedSounds: SoundLibrary { RouterHarness.shippedSounds }

    @Test("A state change becomes one notification with every field filled")
    func deliversAChange() async throws {
        let presenter = RecordingPresenter()
        let router = await startedRouter(
            presenter: presenter, sounds: shippedSounds,
            attachments: StubAttachments(url: URL(filePath: "/tmp/badge.png")))
        router.record([Fixture.change(to: .waitingInput(question: "Which branch?"))])
        router.stop()
        await router.flush()

        let posted = try #require(presenter.posted.first)
        #expect(posted.title == "Question · agentbar")
        #expect(posted.body == "Which branch?")
        #expect(posted.categoryIdentifier == NotificationEvent.question.categoryIdentifier)
        #expect(posted.isTimeSensitive)
        #expect(posted.sound == .named("AgentBar Question.aiff"))
    }

    /// The session id, so the notification centre replaces a session's previous
    /// banner rather than stacking a second one beside it; the project id, so it
    /// groups a project's notifications together.
    @Test("The identifier is the session and the thread is the project")
    func identifiersGroupCorrectly() async throws {
        let presenter = RecordingPresenter()
        let router = await startedRouter(presenter: presenter)
        router.record([Fixture.change("session-9", project: "/Users/dev/web")])
        router.stop()
        await router.flush()

        let posted = try #require(presenter.posted.first)
        #expect(posted.identifier == "session-9")
        #expect(posted.threadIdentifier == Fixture.project("/Users/dev/web").id.value)
    }

    @Test("With art the title carries no provider; without it the title does")
    func providerFallsBackIntoTheTitle() async throws {
        let withArt = RecordingPresenter()
        let illustrated = await startedRouter(
            presenter: withArt,
            attachments: StubAttachments(url: URL(filePath: "/tmp/event.png")))
        illustrated.record([Fixture.change()])
        illustrated.stop()
        await illustrated.flush()
        #expect(withArt.posted.first?.title == "Finished · agentbar")
        #expect(withArt.posted.first?.attachment != nil)

        let without = RecordingPresenter()
        let bare = await startedRouter(presenter: without)
        bare.record([Fixture.change()])
        bare.stop()
        await bare.flush()
        #expect(without.posted.first?.title == "Finished · Claude Code · agentbar")
    }

    /// The slot that was unused before v2. It is what freed the attachment
    /// square to say *what happened* instead of repeating which app this is.
    @Test("The subtitle always names the provider")
    func subtitleNamesTheProvider() async throws {
        for provider in Provider.allCases {
            let presenter = RecordingPresenter()
            let router = await startedRouter(
                presenter: presenter,
                attachments: StubAttachments(url: URL(filePath: "/tmp/event.png")))
            router.record([Fixture.change(provider: provider)])
            router.stop()
            await router.flush()
            let posted = try #require(presenter.posted.first)
            #expect(posted.subtitle == provider.displayName)
            // And nothing more. A session ordinal has no honest source here, and
            // an invented number is the one thing the copy rules forbid outright.
            #expect(!posted.subtitle.contains("session"))
        }
    }

    @Test("Changes that fire nothing reach no presenter")
    func silentChangesPostNothing() async {
        let presenter = RecordingPresenter()
        let router = await startedRouter(presenter: presenter)
        router.record([
            Fixture.change(from: nil, to: .idle),
            Fixture.change("b", from: .working, to: nil),
            Fixture.change("c", from: .idle, to: .working),
            Fixture.change("d", from: .working, to: .unknown),
        ])
        router.stop()
        await router.flush()
        #expect(presenter.posted.isEmpty)
    }

    @Test("A suppressed notification is decided before the presenter is asked")
    func suppressionStopsTheSend() async {
        var settings = NotificationSettings()
        settings.isEnabled = false
        let presenter = RecordingPresenter()
        let router = await startedRouter(presenter: presenter, settings: settings)
        router.record([Fixture.change()])
        router.stop()
        await router.flush()
        #expect(presenter.posted.isEmpty)
    }

    @Test("Nothing is posted while authorisation is missing")
    func unauthorizedPostsNothing() async {
        let presenter = RecordingPresenter(status: .denied)
        let router = router(presenter: presenter)
        await router.start()
        router.record([Fixture.change()])
        router.stop()
        await router.flush()
        #expect(presenter.posted.isEmpty)
    }

    /// A refusal is final until the user changes it in System Settings.
    /// Re-prompting every launch would teach them to dismiss it faster.
    @Test("Permission is asked for once, and never again after an answer")
    func asksOnce() async {
        let fresh = RecordingPresenter(status: .notDetermined)
        await router(presenter: fresh).start()
        #expect(fresh.authorizationRequests == 1)

        let answered = RecordingPresenter(status: .denied)
        await router(presenter: answered).start()
        #expect(answered.authorizationRequests == 0)
    }

    @Test("Every event's category is registered at start")
    func registersCategories() async {
        let presenter = RecordingPresenter()
        await router(presenter: presenter).start()
        #expect(
            Set(presenter.registeredCategories)
                == Set(NotificationEvent.allCases.map(\.categoryIdentifier)))
    }

    /// A misconfigured sound must not also cost the user the notification's
    /// arrival — so it falls back to the default, not to silence, and says so.
    @Test("A sound that has gone falls back to the default and is reported")
    func missingSoundIsReportedNotSilent() async throws {
        var settings = NotificationSettings()
        settings.update(
            EventPreference(
                provider: .claudeCode, event: .finished, isEnabled: true,
                sound: .named("Gone.aiff")))
        let presenter = RecordingPresenter()
        let router = await startedRouter(presenter: presenter, settings: settings)

        router.record([Fixture.change()])
        router.stop()
        await router.flush()

        #expect(presenter.posted.first?.sound == .systemDefault)
        // Reported to the user by the settings window, which recomputes every
        // cell's problem from the same library on each read.
        #expect(router.sounds.problem(with: .named("Gone.aiff")) == .missing(name: "Gone.aiff"))
    }

    @Test("Silence is a choice, not a fault")
    func silentSelectionStaysSilent() async {
        var settings = NotificationSettings()
        settings.update(
            EventPreference(
                provider: .claudeCode, event: .finished, isEnabled: true, sound: .silent))
        let presenter = RecordingPresenter()
        let router = await startedRouter(presenter: presenter, settings: settings)
        router.record([Fixture.change()])
        router.stop()
        await router.flush()

        #expect(presenter.posted.first?.sound == .silent)
        #expect(router.sounds.problem(with: .silent) == nil)
    }

    @Test("A burst on one session reaches the presenter once")
    func burstIsCoalesced() async {
        let presenter = RecordingPresenter()
        let router = await startedRouter(presenter: presenter)
        router.record([
            Fixture.change(to: .waitingInput(question: nil), at: Fixture.epoch),
            Fixture.change(to: .failed(reason: "boom"), at: Fixture.epoch.addingTimeInterval(0.1)),
            Fixture.change(to: .idle, at: Fixture.epoch.addingTimeInterval(0.2)),
        ])
        router.stop()
        await router.flush()

        #expect(presenter.posted.count == 1)
        #expect(presenter.posted.first?.title.hasPrefix("Finished") == true)
    }

    @Test("Settings are persisted through the store, and re-read on the way back")
    func settingsRoundTrip() {
        let store = InMemoryNotificationSettings()
        let router = NotificationRouter(presenter: RecordingPresenter(), store: store)
        var settings = router.settings
        settings.quietHours = QuietHours(isEnabled: true, startMinute: 60, endMinute: 120)
        router.update(settings)

        #expect(store.load().quietHours.isEnabled)
        #expect(router.settings.quietHours.startMinute == 60)
    }

    /// A repeat is dropped by the router, not inside the drain, so the reason is
    /// reportable and so the window starts only when something was delivered.
    @Test("An identical change moments later is not delivered twice")
    func repeatIsNotDeliveredTwice() async {
        let presenter = RecordingPresenter()
        let router = await startedRouter(presenter: presenter)

        for _ in 0..<2 {
            router.record([Fixture.change(to: .waitingInput(question: "Which branch?"))])
            router.stop()
            await router.flush()
        }
        #expect(presenter.posted.count == 1)

        // A different question is news, and gets through.
        router.record([Fixture.change(to: .waitingInput(question: "Overwrite it?"))])
        router.stop()
        await router.flush()
        #expect(presenter.posted.count == 2)
    }

    /// A draft the gate refused was never delivered, so it must not start a
    /// repeat window that then refuses the same news for a second reason.
    @Test("A suppressed draft starts no repeat window")
    func suppressionDoesNotStartTheRepeatWindow() async {
        var quiet = NotificationSettings()
        quiet.quietHours = QuietHours(isEnabled: true, startMinute: 0, endMinute: 23 * 60 + 59)
        let presenter = RecordingPresenter()
        let router = await startedRouter(
            presenter: presenter, settings: quiet, sounds: shippedSounds)

        router.record([Fixture.change(to: .failed(reason: "boom"))])
        router.stop()
        await router.flush()
        #expect(presenter.posted.isEmpty)

        // Quiet hours lifted; the same news must still arrive.
        var loud = quiet
        loud.quietHours = QuietHours(isEnabled: false)
        router.update(loud)
        router.record([Fixture.change(to: .failed(reason: "boom"))])
        router.stop()
        await router.flush()
        #expect(presenter.posted.count == 1)
    }

    /// The badge file can be found and still be refused by the notification
    /// centre, so the provider-naming title travels with every notification
    /// rather than being chosen once, up front.
    @Test("The provider-naming title is carried even when a badge was found")
    func fallbackTitleAlwaysTravels() async throws {
        let presenter = RecordingPresenter()
        let router = await startedRouter(
            presenter: presenter,
            attachments: StubAttachments(url: URL(filePath: "/tmp/badge.png")))
        router.record([Fixture.change()])
        router.stop()
        await router.flush()

        let posted = try #require(presenter.posted.first)
        #expect(posted.title == "Finished · agentbar")
        #expect(posted.titleWithoutBadge == "Finished · Claude Code · agentbar")
    }
}
