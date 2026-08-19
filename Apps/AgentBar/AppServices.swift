import AgentBarCore
import AgentBarIngest
import AgentBarUI
import Foundation

/// What the panel is given instead of the modules it may not import.
///
/// The assembly point's half of `PanelServices`: the store, the endpoint and
/// every provider integration are already linked here, so this is where they are
/// joined up.
@MainActor
final class AppServices: PanelServices {
    private let store: SessionStore
    private let integrations: [ClaudeCodeIntegration]
    private let caffeineBridge: CaffeineBridge

    init(
        store: SessionStore,
        integrations: [ClaudeCodeIntegration],
        caffeine: CaffeineBridge
    ) {
        self.store = store
        self.integrations = integrations
        caffeineBridge = caffeine
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

    /// Empty until step 10 reads Codex's windows off the App Server. Absent is
    /// not an error and gets no error styling — the Limits section still ships
    /// complete, because the Claude Code caveat row is the permanent half of it.
    func usageWindows() async -> [UsageWindow] { [] }

    // MARK: - Caffeine

    /// Read on every panel refresh, so it is a property read and never I/O. The
    /// controller behind it is observable, which is what lets the footer's
    /// indicator follow the assertion without a clock of its own.
    func caffeine() -> CaffeineIndicator { caffeineBridge.indicator() }

    func toggleCaffeine() { caffeineBridge.toggle() }
}
