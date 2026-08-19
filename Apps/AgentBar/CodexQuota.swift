import AgentBarUI
import CodexAppServer
import Foundation

/// Codex's limits, as the panel needs to see them.
///
/// The counterpart of `CodexIntegration`, and it lives here for the same
/// reason: `CodexAppServer` carries numbers and durations, `AgentBarUI` carries
/// the strings, and neither may import the other. The app target is where both
/// are already linked, so the joining happens here — the same shape as
/// `IntegrationStatus`.
///
/// It stays a joining and nothing more. Naming a window is a decision with rules
/// worth testing, so those rules are `UsageWindow.label` in `AgentBarUI`, where
/// `swift test` reaches them; `Apps/` has no test target.
enum CodexQuota {
    static func usageWindows(from windows: [QuotaWindow]) -> [UsageWindow] {
        windows.map { window in
            UsageWindow(
                name: UsageWindow.label(
                    name: window.limitName,
                    windowDuration: window.windowDuration,
                    identifier: window.limitId),
                fractionUsed: window.fractionUsed,
                resetsAt: window.resetsAt)
        }
    }
}
