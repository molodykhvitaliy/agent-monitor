import AgentBarCore
import Foundation
import Observation

/// Whether the first run has happened. **The only thing the onboarding
/// persists.**
///
/// Everything else the flow shows is derived from an install report or from the
/// notification centre, re-read on entry to every step. That is the failure mode
/// this type exists to make impossible: a flow that remembered "Claude Code is
/// connected" would keep saying so after the user removed the hook in a
/// terminal, and would be a second, worse source of truth beside the reports.
@MainActor
public final class OnboardingState {
    static let key = "onboarding.hasCompletedFirstRun"

    private let defaults: UserDefaults

    /// Injectable so a test can drive a fresh machine without touching the
    /// developer's own defaults.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var hasCompletedFirstRun: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// The first-run flow's state: where the user is, and what is actually true.
///
/// Two seams rather than a third protocol. `PanelServices` already reads install
/// reports and performs install actions, and `SettingsServices` already owns the
/// notification permission — the flow drives exactly the same plumbing the
/// integration card and the settings window drive, which is what makes it
/// impossible for the onboarding to install something a different way from the
/// rest of the app.
@Observable
@MainActor
public final class OnboardingModel {
    public private(set) var step: OnboardingStep = .welcome
    public private(set) var integrations: [IntegrationStatus] = []
    public private(set) var permission: NotificationPermission = .notAsked
    /// Whether an action is in flight, so its button is disabled rather than
    /// pressed twice.
    public private(set) var busy: Set<Provider> = []
    /// What the last action on a provider left behind, shown until the next
    /// refresh replaces it.
    public private(set) var actionResults: [Provider: IntegrationActionResult] = [:]
    /// Set when the flow is over, whichever way it ended.
    public private(set) var hasFinished = false

    /// Called whenever the visible content changes shape.
    ///
    /// The flow lives in a borderless window, which does not resize itself to
    /// its content, so somebody has to re-measure. Every call site here is a
    /// **discrete** event — a step change, an action, a refresh — never a
    /// measurement fed back from layout, which is the shape that pegged a core
    /// in this panel once already.
    @ObservationIgnored public var onContentChange: (() -> Void)?

    /// Called when the flow ends of its own accord — the last step's button, or
    /// the link into Settings. **Not** called when the user dismisses the panel
    /// by clicking away: that path is the controller's, and it does not hand the
    /// user a panel they did not ask for.
    @ObservationIgnored public var onFinished: (() -> Void)?

    @ObservationIgnored private let panel: any PanelServices
    @ObservationIgnored private let settings: any SettingsServices
    @ObservationIgnored private let state: OnboardingState

    public init(
        panel: any PanelServices,
        settings: any SettingsServices,
        state: OnboardingState = OnboardingState()
    ) {
        self.panel = panel
        self.settings = settings
        self.state = state
    }

    /// Whether the flow should run at all.
    public static func shouldRun(_ state: OnboardingState = OnboardingState()) -> Bool {
        !state.hasCompletedFirstRun
    }

    // MARK: - Reading what is true

    /// Re-reads every install report and the notification permission.
    ///
    /// Called on entry to each step and on a slow poll while an install step is
    /// showing, because a user who runs the installer from a terminal — or
    /// trusts the hook in Codex's own prompt — must see the step flip without
    /// pressing anything here.
    public func refresh() async {
        integrations = await panel.integrationStatuses()
        permission = await settings.permission()
        onContentChange?()
    }

    public func condition(for provider: Provider) -> IntegrationCondition {
        integrations.first { $0.provider == provider }?.condition ?? .notConnected
    }

    public func status(for provider: Provider) -> IntegrationStatus? {
        integrations.first { $0.provider == provider }
    }

    /// What the row shows under its status line after an action.
    ///
    /// The same three outcomes the integration card has, including the one that
    /// is easy to get wrong: a write that found the file already correct is
    /// `Nothing to change`, and it must not read as a failure.
    public func resultLine(for provider: Provider) -> (text: String, isFault: Bool)? {
        switch actionResults[provider] {
        case .unchanged:
            (
                String(
                    localized: "Nothing to change",
                    comment: "Shown after an install action that wrote nothing"), false
            )
        case .failed(let reason):
            (reason, true)
        case .changed, .acknowledged, nil:
            nil
        }
    }

    // MARK: - Navigation

    public var canGoBack: Bool { step != .welcome && step != .done }

    public func next() async {
        guard let next = step.next else {
            finish()
            return
        }
        step = next
        await refresh()
    }

    public func back() async {
        guard let previous = step.previous else { return }
        step = previous
        await refresh()
    }

    /// Walk past this step. Nothing is written and nothing is logged as an
    /// error — a skip is a decision, not a failure, and the summary says so in
    /// secondary ink rather than in red.
    ///
    /// Skipping the **welcome** step skips the whole flow: it jumps to the
    /// summary, which then honestly reports that nothing was set up. The panel's
    /// own `Get Started` card is what the user meets next, which is exactly what
    /// it is for.
    public func skip() async {
        // **Nothing is recorded.** A set of skipped steps would be a local
        // mirror of something the reports already answer — a step is "skipped"
        // exactly when its provider is still not connected — and this flow's one
        // rule is that it remembers nothing it can read.
        step = step == .welcome ? .done : (step.next ?? .done)
        await refresh()
    }

    /// Ends the flow and records that it happened. The one write.
    ///
    /// Idempotent, because both ends of the flow can reach it: the last step's
    /// button calls it directly, and the controller calls it again when it tears
    /// the surface down.
    public func finish() {
        guard !hasFinished else { return }
        state.hasCompletedFirstRun = true
        hasFinished = true
        onFinished?()
    }

    // MARK: - Actions

    /// Runs an install action through the same path the integration card uses.
    public func perform(_ action: IntegrationAction, for provider: Provider) async {
        guard busy.insert(provider).inserted else { return }
        defer { busy.remove(provider) }
        let result = await panel.perform(action, for: provider)
        // The report is re-read whatever happened: a failed write can still have
        // changed what the file says about itself.
        integrations = await panel.integrationStatuses()
        actionResults[provider] = result
        onContentChange?()
    }

    /// Opens the system prompt, once.
    ///
    /// **Never when the answer is already a refusal.** macOS shows its prompt
    /// once per app and silently does nothing on a second request, so a button
    /// that re-asked would be a button that visibly does nothing — which reads
    /// as a broken app rather than as a setting that lives elsewhere.
    public func requestPermission() async {
        guard permission.canRequest else { return }
        permission = await settings.requestPermission()
        onContentChange?()
    }

    public func openSystemSettings() {
        settings.openSystemNotificationSettings()
    }

    // MARK: - The summary

    /// One line per thing the flow could have set up, in the order it offered
    /// them.
    ///
    /// `%@ — skipped` is deliberately as plain as `%@ — connected`: the state is
    /// recoverable and the app says so by tone. No red, no warning glyph, no
    /// "incomplete".
    public var summary: [SummaryLine] {
        var lines: [SummaryLine] = []
        for step in [OnboardingStep.claudeCode, .codex] {
            guard let provider = step.provider else { continue }
            let condition = condition(for: provider)
            lines.append(
                SummaryLine(
                    id: step,
                    text: String(
                        localized: "\(provider.displayName) — \(condition.summaryPhrase)",
                        comment: "Onboarding summary: a provider, then where it stands"),
                    isDone: condition.isHealthy))
        }
        lines.append(
            SummaryLine(
                id: .notifications,
                text: permission.canDeliver
                    ? String(
                        localized: "Notifications — allowed",
                        comment: "Onboarding summary, notifications are on")
                    : String(
                        localized: "Notifications — not allowed",
                        comment: "Onboarding summary, notifications are off"),
                isDone: permission.canDeliver))
        return lines
    }

    public struct SummaryLine: Sendable, Hashable, Identifiable {
        public let id: OnboardingStep
        public let text: String
        /// Whether the thing is set up. Decides a colour and nothing else — an
        /// unfinished line is quiet, never a fault.
        public let isDone: Bool
    }
}

nonisolated extension IntegrationCondition {
    /// Where Codex's two-stage progression stands: install, then trust.
    ///
    /// The two-step requirement surprises people — "I installed it, why is
    /// nothing happening" — so the step draws it as a progression rather than
    /// explaining it in a footnote.
    public var codexStagesDone: Int {
        switch self {
        case .notConnected, .settingsUnreadable: 0
        case .notTrusted, .needsRepair, .notReceiving: 1
        case .connected: 2
        }
    }
}
