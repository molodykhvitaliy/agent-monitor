import AgentBarCore
import Foundation
import Testing

@testable import AgentBarUI

/// The first-run flow. Its whole risk is holding state of its own, so most of
/// this suite is about what it does *not* remember.
@MainActor
@Suite("Onboarding")
struct OnboardingTests {

    /// A defaults domain per test, so a suite run never touches the developer's
    /// own flag and two tests cannot see each other's.
    private static func state(_ name: String) -> OnboardingState {
        let suite = "com.molodykhvitalii.AgentBar.tests.\(name)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return OnboardingState(defaults: defaults)
    }

    /// A flow and the three doubles behind it, so a test can move the world
    /// under a step the way a terminal would.
    private struct Harness {
        let model: OnboardingModel
        let panel: StubServices
        let settings: StubSettingsServices
        let state: OnboardingState
    }

    private static func harness(
        _ name: String,
        statuses: [IntegrationStatus] = [],
        permission: NotificationPermission = .notAsked
    ) -> Harness {
        let panel = StubServices()
        panel.storedStatuses = statuses
        let settings = StubSettingsServices()
        settings.permissionState = permission
        let state = Self.state(name)
        return Harness(
            model: OnboardingModel(panel: panel, settings: settings, state: state),
            panel: panel, settings: settings, state: state)
    }

    private static func only(
        _ name: String, statuses: [IntegrationStatus] = [],
        permission: NotificationPermission = .notAsked
    ) -> OnboardingModel {
        harness(name, statuses: statuses, permission: permission).model
    }

    private static func pair(
        _ name: String, statuses: [IntegrationStatus] = [],
        permission: NotificationPermission = .notAsked
    ) -> (OnboardingModel, OnboardingState) {
        let built = harness(name, statuses: statuses, permission: permission)
        return (built.model, built.state)
    }

    private static func withPanel(
        _ name: String, statuses: [IntegrationStatus] = [],
        permission: NotificationPermission = .notAsked
    ) -> (OnboardingModel, StubServices) {
        let built = harness(name, statuses: statuses, permission: permission)
        return (built.model, built.panel)
    }

    private static func withSettings(
        _ name: String, statuses: [IntegrationStatus] = [],
        permission: NotificationPermission = .notAsked
    ) -> (OnboardingModel, StubSettingsServices) {
        let built = harness(name, statuses: statuses, permission: permission)
        return (built.model, built.settings)
    }

    // MARK: - Navigation

    @Test("Next walks the five steps and then finishes")
    func nextWalksTheFlow() async {
        let (model, state) = Self.pair("walk")
        #expect(model.step == .welcome)
        for expected in [OnboardingStep.claudeCode, .codex, .notifications, .done] {
            await model.next()
            #expect(model.step == expected)
        }
        #expect(!model.hasFinished)
        await model.next()
        #expect(model.hasFinished)
        #expect(state.hasCompletedFirstRun)
    }

    @Test("Back walks it the other way, and stops at the first step")
    func backWalksBack() async {
        let model = Self.only("back")
        await model.next()
        await model.next()
        #expect(model.step == .codex)
        #expect(model.canGoBack)
        await model.back()
        #expect(model.step == .claudeCode)
        await model.back()
        #expect(model.step == .welcome)
        #expect(!model.canGoBack)
        await model.back()
        #expect(model.step == .welcome, "the first step walked off the front of the flow")
    }

    /// Skipping the welcome step skips the flow, and the summary then has to be
    /// honest about it rather than pretending the steps did not exist.
    @Test("Skipping the first step jumps to a summary that admits it")
    func skippingTheWelcomeSkipsEverything() async {
        let (model, panel) = Self.withPanel("skip-all")
        await model.skip()
        #expect(model.step == .done)
        #expect(panel.performed.isEmpty, "a skip wrote something")
        #expect(model.summary.allSatisfy { !$0.isDone })
        #expect(model.summary.contains { $0.text.contains("skipped") })
        // Quietly. No red, no warning glyph, no "incomplete".
        #expect(!model.summary.contains { $0.text.lowercased().contains("incomplete") })
    }

    /// A skip is a decision, not a failure. Nothing is written and nothing is
    /// recorded as an error.
    @Test("Skipping a step writes nothing and advances")
    func skippingAStepWritesNothing() async {
        let (model, panel) = Self.withPanel("skip-one")
        await model.next()
        await model.skip()
        #expect(model.step == .codex)
        #expect(panel.performed.isEmpty)
    }

    // MARK: - Derived state

    /// The failure mode this flow is built to avoid: a local mirror that keeps
    /// saying "connected" after the user has removed the hook in a terminal.
    @Test("A connection made outside the app changes the step")
    func stateFollowsTheReport() async {
        let (model, panel) = Self.withPanel(
            "external", statuses: [UIFixture.status(.claudeCode, .notConnected)])
        await model.refresh()
        #expect(model.condition(for: .claudeCode) == .notConnected)

        // The user runs the installer in a terminal while the step is up.
        panel.storedStatuses = [UIFixture.status(.claudeCode, .connected)]
        await model.refresh()
        #expect(model.condition(for: .claudeCode) == .connected)

        // And undoes it.
        panel.storedStatuses = [UIFixture.status(.claudeCode, .notConnected)]
        await model.refresh()
        #expect(model.condition(for: .claudeCode) == .notConnected)
    }

    /// Codex's two-step requirement is what surprises people, so the step draws
    /// it. `notTrusted` is a distinct third state and not a kind of failure.
    @Test("Codex's stages follow its condition")
    func codexStages() {
        #expect(IntegrationCondition.notConnected.codexStagesDone == 0)
        #expect(IntegrationCondition.notTrusted.codexStagesDone == 1)
        #expect(IntegrationCondition.connected.codexStagesDone == 2)
    }

    @Test("An action goes through the same plumbing the card uses")
    func actionsUseTheExistingPath() async {
        let (model, panel) = Self.withPanel(
            "action", statuses: [UIFixture.status(.claudeCode, .notConnected)])
        await model.refresh()
        await model.perform(.connect, for: .claudeCode)
        #expect(panel.performed.map(\.action) == [.connect])
        #expect(panel.performed.map(\.provider) == [.claudeCode])
    }

    /// A write that found the file already correct is news for a moment, and it
    /// must not wear a failure's colour.
    @Test("Nothing to change is not a failure")
    func noOpIsNotAFailure() async throws {
        let (model, panel) = Self.withPanel("noop")
        panel.result = .unchanged
        await model.perform(.connect, for: .claudeCode)
        let line = try #require(model.resultLine(for: .claudeCode))
        #expect(line.text == "Nothing to change")
        #expect(!line.isFault)

        panel.result = .failed("could not write ~/.claude/settings.json")
        await model.perform(.connect, for: .claudeCode)
        let failure = try #require(model.resultLine(for: .claudeCode))
        #expect(failure.isFault)
    }

    // MARK: - Permission

    @Test("The permission step asks once, and only when nothing has been asked")
    func permissionIsAskedOnce() async {
        let (model, settings) = Self.withSettings("ask", permission: .notAsked)
        await model.refresh()
        await model.requestPermission()
        #expect(settings.permissionRequests == 1)
        #expect(model.permission == .granted)
        // Already granted: nothing left to ask.
        await model.requestPermission()
        #expect(settings.permissionRequests == 1)
    }

    /// macOS shows its prompt once per app and silently ignores a second
    /// request, so a button that re-asked would visibly do nothing — which
    /// reads as a broken app rather than as a setting that lives elsewhere.
    @Test("A refusal is never re-asked")
    func refusalIsNeverReasked() async {
        let (model, settings) = Self.withSettings("refused", permission: .refused)
        await model.refresh()
        #expect(model.permission == .refused)
        await model.requestPermission()
        #expect(settings.permissionRequests == 0, "a refusal was re-prompted")
    }

    // MARK: - The flag

    @Test("The flag is the only thing the flow persists, and it is written once")
    func theFlagIsTheOnlyState() async {
        let state = Self.state("flag")
        #expect(OnboardingModel.shouldRun(state))
        let model = OnboardingModel(
            panel: StubServices(), settings: StubSettingsServices(), state: state)
        model.finish()
        #expect(state.hasCompletedFirstRun)
        #expect(!OnboardingModel.shouldRun(state))

        var finishes = 0
        model.onFinished = { finishes += 1 }
        model.finish()
        model.finish()
        #expect(finishes == 0, "finish is not idempotent, so teardown can recurse")
    }

    @Test("Finishing on its own calls back; finishing twice does not")
    func finishCallsBackOnce() {
        let state = Self.state("callback")
        let model = OnboardingModel(
            panel: StubServices(), settings: StubSettingsServices(), state: state)
        var finishes = 0
        model.onFinished = { finishes += 1 }
        model.finish()
        model.finish()
        #expect(finishes == 1)
    }

    // MARK: - The summary

    @Test("The summary is derived, and reads the same for every outcome")
    func summaryIsDerived() async {
        let model = Self.only(
            "summary",
            statuses: [
                UIFixture.status(.claudeCode, .connected),
                UIFixture.status(.codex, .notTrusted),
            ],
            permission: .granted)
        await model.refresh()
        let summary = model.summary
        #expect(summary.count == 3)
        #expect(summary[0].isDone)
        #expect(summary[0].text == "Claude Code — connected")
        // Installed but not trusted is not connected, and the line says
        // "skipped" rather than inventing a fourth word for it.
        // Installed but not trusted is neither connected nor skipped, and
        // calling it "skipped" would be this summary's one job done wrongly.
        #expect(!summary[1].isDone)
        #expect(summary[1].text == "Codex — installed, not trusted")
        #expect(summary[2].isDone)
        #expect(summary[2].text == "Notifications — allowed")
    }

    /// The step names and the progress label, because they are the one string
    /// in the flow assembled from three pieces.
    @Test("The progress label names the step and counts to five")
    func progressLabel() {
        #expect(OnboardingStep.welcome.progressLabel == "Step 1 of 5 · Welcome")
        #expect(OnboardingStep.codex.progressLabel == "Step 3 of 5 · Codex")
        #expect(OnboardingStep.done.progressLabel == "Step 5 of 5 · Done")
    }

    /// Every step that writes into a file the user owns says which file, in the
    /// step itself. Rule 4 of the copy rules, and the easiest one to drop.
    @Test("Both install steps name what they read and where it lives")
    func installStepsAreHonest() {
        for step in [OnboardingStep.claudeCode, .codex] {
            #expect(step.facts.count == 2, "\(step)")
            #expect(step.facts.contains { $0.contains("status events only") }, "\(step)")
            #expect(step.facts.contains { $0.contains("~/") }, "\(step) names no file")
            #expect(step.subtitle != nil, "\(step) does not say it is reversible")
        }
    }
}
