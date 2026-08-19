import AgentBarCore
import AgentBarIngest
import AgentBarUI
import CodexAppServer
import Foundation

/// What the panel is given instead of the modules it may not import.
///
/// The assembly point's half of `PanelServices`: the store, the endpoint and
/// every provider integration are already linked here, so this is where they are
/// joined up.
@MainActor
final class AppServices: PanelServices {
    private let store: SessionStore
    private let integrations: [any ProviderIntegration]
    private let caffeineBridge: CaffeineBridge
    /// Absent when Codex limits are not wired up at all. Distinct from "the
    /// service found nothing", which is an empty reading and looks the same to
    /// the panel — deliberately, because both mean the section has no Codex half.
    private let quota: QuotaService?

    init(
        store: SessionStore,
        integrations: [any ProviderIntegration],
        caffeine: CaffeineBridge,
        quota: QuotaService? = nil
    ) {
        self.store = store
        self.integrations = integrations
        caffeineBridge = caffeine
        self.quota = quota
    }

    func snapshot() async -> StoreSnapshot {
        await store.snapshot()
    }

    func sweep() async {
        // The changes a sweep reports are not forwarded anywhere yet: step 07
        // is what turns "this session went quiet" into a notification, and
        // `unknown` is explicitly not one of the events worth waking a person
        // for. The retiring is what matters here.
        _ = await store.sweep()
    }

    /// One report per registered integration, read in order.
    ///
    /// Disk I/O, and called only when something could have changed: panel open,
    /// after an action, after a bind.
    func integrationStatuses() async -> [IntegrationStatus] {
        var statuses: [IntegrationStatus] = []
        for integration in integrations {
            statuses.append(await integration.status())
        }
        return statuses
    }

    func perform(
        _ action: IntegrationAction, for provider: Provider
    ) async -> IntegrationActionResult {
        guard let integration = integrations.first(where: { $0.provider == provider }) else {
            return .unchanged
        }
        return await integration.perform(action)
    }

    /// The last reading Codex gave, named for the panel.
    ///
    /// A property read behind an actor hop, never a fetch: the service refreshes
    /// on its own schedule, and a panel that opened a child process to fill its
    /// Limits section would take a second and a half to appear. An empty result
    /// is not an error and gets no error styling — the Claude Code caveat row is
    /// the permanent half of the section either way.
    func usageWindows() async -> [UsageWindow] {
        guard let quota else { return [] }
        return CodexQuota.usageWindows(from: await quota.windows())
    }

    // MARK: - Caffeine

    /// Read on every panel refresh, so it is a property read and never I/O. The
    /// controller behind it is observable, which is what lets the footer's
    /// indicator follow the assertion without a clock of its own.
    func caffeine() -> CaffeineIndicator { caffeineBridge.indicator() }

    func toggleCaffeine() { caffeineBridge.toggle() }
}
