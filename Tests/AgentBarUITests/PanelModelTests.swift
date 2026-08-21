import AgentBarCore
import Foundation
import Testing

@testable import AgentBarUI

/// The model holds the snapshot **and** an integration status per provider,
/// because neither alone decides what the panel shows — and it refreshes them on
/// different schedules, because they cost different things.
@MainActor
@Suite("Panel model")
struct PanelModelTests {

    private func model(_ services: StubServices) -> PanelModel {
        PanelModel(services: services)
    }

    /// `report(for:)` is disk I/O and must never run on a timer.
    @Test("A snapshot refresh does not touch the disk")
    func snapshotRefreshIsCheap() async {
        let services = StubServices()
        let model = model(services)
        await model.refreshSnapshot()
        #expect(services.snapshots == 1)
        #expect(services.statusReads == 0)
    }

    /// Nothing else retires a session whose agent died, and the power assertion
    /// in step 08 depends on that happening.
    ///
    /// Both clocks call this, and that was not always true: the open clock used
    /// to only re-read, so a panel left on screen kept every session the
    /// watchdog had given up on, labelled `Unknown` and unable to leave.
    @Test("A tick sweeps before it reads")
    func sweepThenRead() async {
        let services = StubServices()
        let model = model(services)
        await model.sweepAndRefresh()
        #expect(services.sweeps == 1)
        #expect(services.snapshots == 1)
    }

    @Test("Content follows the snapshot and the integrations together")
    func contentFollowsBoth() async {
        let services = StubServices()
        services.storedStatuses = [UIFixture.status(.claudeCode, .notConnected)]
        let model = model(services)
        await model.refreshIntegrations()
        #expect(model.content == .onboarding)

        services.storedStatuses = [UIFixture.status(.claudeCode, .connected)]
        await model.refreshIntegrations()
        #expect(model.content == .allQuiet)

        services.storedSnapshot = UIFixture.snapshot([UIFixture.session()])
        await model.refreshSnapshot()
        #expect(model.content == .sessions)
    }

    /// Pressing the footer status opens the card at any time, not only on first
    /// run — that is the answer to "why is nothing appearing?".
    @Test("Asking for the card overrides the precedence")
    func cardOnDemand() async {
        let services = StubServices()
        services.storedSnapshot = UIFixture.snapshot([UIFixture.session()])
        let model = model(services)
        await model.refreshSnapshot()
        model.showsIntegrationCard = true
        #expect(model.content == .onboarding)
    }

    /// A no-op must not look like a failure.
    @Test("A write that changed nothing says so, transiently")
    func unchangedIsNotAFailure() async {
        let services = StubServices()
        services.result = .unchanged
        let model = model(services)
        await model.perform(.connect, for: .claudeCode)

        #expect(services.performed.map(\.action) == [.connect])
        let line = model.resultLine(for: .claudeCode)
        #expect(line?.text == "Nothing to change")
        #expect(line?.isFault == false)
    }

    @Test("A thrown error becomes the row's second line, in fault colour")
    func failureIsShown() async {
        let services = StubServices()
        services.result = .failed("~/.claude does not exist")
        let model = model(services)
        await model.perform(.connect, for: .claudeCode)

        let line = model.resultLine(for: .claudeCode)
        #expect(line?.text == "~/.claude does not exist")
        #expect(line?.isFault == true)
    }

    /// A successful write leaves no line: the row simply takes whatever its next
    /// report says.
    @Test("A successful write leaves no transient line")
    func successLeavesNothing() async {
        let services = StubServices()
        services.result = .changed
        let model = model(services)
        await model.perform(.repair, for: .claudeCode)
        #expect(model.resultLine(for: .claudeCode) == nil)
    }

    /// The line is *transient*, and nothing else clears it: the next report is
    /// the thing that supersedes it. A `Nothing to change` still pinned under a
    /// healthy row tomorrow would be worse than never having shown it.
    @Test("The action line does not survive the next refresh")
    func resultLineIsTransient() async {
        let services = StubServices()
        services.result = .unchanged
        let model = model(services)
        await model.perform(.connect, for: .claudeCode)
        #expect(model.resultLine(for: .claudeCode) != nil)

        await model.refreshIntegrations()
        #expect(model.resultLine(for: .claudeCode) == nil)
    }

    /// `Nothing to change` explains a no-op **write**. Revealing a file in
    /// Finder is not a write, and the one row that offers it is the row where
    /// AgentBar has explicitly refused to write anything.
    @Test("An action that attempts no write leaves no line")
    func acknowledgedLeavesNothing() async {
        let services = StubServices()
        services.result = .acknowledged
        let model = model(services)
        await model.perform(.revealInFinder, for: .claudeCode)
        #expect(model.resultLine(for: .claudeCode) == nil)
    }

    /// The report is re-read whatever happened: a failed write can still have
    /// changed what the file says about itself.
    @Test("Every action re-reads the reports")
    func actionRefreshesReports() async {
        let services = StubServices()
        services.result = .failed("nope")
        let model = model(services)
        await model.perform(.connect, for: .claudeCode)
        #expect(services.statusReads == 1)
    }

    /// The card's buttons are one click away from writing to a file the user
    /// owns. A double-press must not become two writes.
    @Test("An action already in flight is not started twice")
    func actionIsNotReentrant() async {
        let services = StubServices()
        let model = model(services)
        async let first: Void = model.perform(.connect, for: .claudeCode)
        async let second: Void = model.perform(.connect, for: .claudeCode)
        _ = await (first, second)
        #expect(services.performed.count == 1)
    }

    /// Two providers are not each other's business, though.
    @Test("A different provider's action is not blocked")
    func actionsAreNotBlockedAcrossProviders() async {
        let services = StubServices()
        let model = model(services)
        await model.perform(.connect, for: .claudeCode)
        await model.perform(.trust, for: .codex)
        #expect(services.performed.map(\.provider) == [.claudeCode, .codex])
    }

    /// One computed labelling for the whole snapshot, so the header, the tooltip
    /// and the accessibility label cannot disagree.
    @Test("Labels are computed from the snapshot the panel is showing")
    func labelsFollowTheSnapshot() async {
        let services = StubServices()
        services.storedSnapshot = UIFixture.snapshot([
            UIFixture.session("a", project: "/Users/dev/code/app"),
            UIFixture.session("b", project: "/Users/dev/worktrees/feature-x/app"),
        ])
        let model = model(services)
        await model.refreshSnapshot()

        let labels = model.labels
        let names = model.snapshot.projects.map { labels.label(for: $0.project) }
        #expect(Set(names) == ["app · code", "app · feature-x"])
    }

    /// The request and the reading are deliberately not the same reading: the
    /// request is for the *next* one and lands seconds later, while the display
    /// is of the last one to have landed. Anything else would make the open
    /// panel wait on a child process once a second.
    @Test("Watching asks for a fresh reading and shows the one already there")
    func watchUsageAsksAndShows() async {
        let services = StubServices()
        services.storedWindows = [
            UsageWindow(provider: .codex, name: "Weekly", fractionUsed: 0.5, resetsAt: nil)
        ]
        let model = PanelModel(services: services)

        await model.watchUsage()

        #expect(services.usageRefreshRequests == 1)
        #expect(model.usage.map(\.displayName) == ["Weekly"])
    }

    /// Reading alone must not ask. Every install action and every integration
    /// refresh go through `refreshUsage`, and a request from there would be a
    /// child process taken because somebody pressed Install — while the panel's
    /// closed-panel clock, which sweeps and re-reads the store, asks for
    /// neither.
    @Test("Reading the windows without watching asks for nothing")
    func refreshUsageDoesNotAsk() async {
        let services = StubServices()
        let model = PanelModel(services: services)

        await model.refreshUsage()
        await model.refreshIntegrations()

        #expect(services.usageRefreshRequests == 0)
    }
}

/// What the open panel's one-second clock decides.
///
/// The panel does not close by itself — `hidesOnDeactivate` is false and it is
/// never key on the mouse path, so switching apps or Spaces leaves it up, which
/// was verified against the running app. Without a bound, "ask while the user
/// is watching" is a child process a minute for as long as a forgotten panel
/// stays on screen.
@MainActor
@Suite("Open-panel tick")
struct OpenPanelTickTests {

    @Test("A panel just opened is being watched")
    func watchesAtFirst() {
        #expect(MenuBarController.tick(isVisible: true, openFor: .zero) == .watch)
        #expect(MenuBarController.tick(isVisible: true, openFor: .seconds(60)) == .watch)
    }

    @Test("A panel left open stops asking, and goes on showing")
    func stopsEventually() {
        #expect(
            MenuBarController.tick(isVisible: true, openFor: MenuBarController.watchingWindow)
                == .show)
        #expect(MenuBarController.tick(isVisible: true, openFor: .seconds(60 * 60)) == .show)
        #expect(MenuBarController.tick(isVisible: true, openFor: .seconds(24 * 60 * 60)) == .show)
    }

    /// The one the previous version could not answer: a panel taken off screen
    /// by something that did not go through a dismissal path — `NSApp.hide` is
    /// the one this app itself reaches for. Controller state would still say
    /// "open", and the watching leg would go on spawning a child a minute with
    /// nothing on screen.
    @Test("A panel that is not on screen is not being watched, whatever the clock says")
    func retiresWhenNotVisible() {
        #expect(MenuBarController.tick(isVisible: false, openFor: .zero) == .retire)
        #expect(MenuBarController.tick(isVisible: false, openFor: .seconds(60)) == .retire)
        // And with no opening time recorded at all, which is what every
        // dismissal path leaves behind.
        #expect(MenuBarController.tick(isVisible: true, openFor: nil) == .retire)
    }

    /// A clock that ran backwards must not mean "watch for ever". It cannot
    /// come from `ContinuousClock`, which is exactly why the guard is here
    /// rather than trusted to be unreachable.
    @Test("Negative elapsed time stops the watching rather than restarting it")
    func negativeElapsed() {
        #expect(MenuBarController.tick(isVisible: true, openFor: .seconds(-1)) == .show)
        #expect(MenuBarController.tick(isVisible: true, openFor: .seconds(-60 * 60)) == .show)
    }

    /// The bound only means something if it is comfortably longer than the gap
    /// it governs — a window shorter than a few gaps would ask once or twice and
    /// read as broken — and short enough that a forgotten panel costs nothing.
    ///
    /// The gap is `QuotaSettings.watchingSpacing`, 60 seconds, which
    /// `AgentBarUI` cannot name: it may import only `AgentBarCore`, and that
    /// constant lives in `CodexAppServer`. `QuotaCadenceTests.spacingIsAMinute`
    /// pins the other end of this sentence.
    @Test("The window is worth several readings and far shorter than a day")
    func windowIsSane() {
        #expect(MenuBarController.watchingWindow >= .seconds(3 * 60))
        #expect(MenuBarController.watchingWindow <= .seconds(15 * 60))
    }
}
