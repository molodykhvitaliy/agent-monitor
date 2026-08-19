import AgentBarCore
import AgentBarUI

/// One provider's integration, as the assembly point needs to hold it.
///
/// The two integrations have almost nothing in common underneath — one merges
/// handlers into a JSON settings file and carries a bearer token, the other
/// writes a hook file and then has to explain a trust prompt — and the panel
/// needs neither of those facts. It needs a status and a way to run an action,
/// which is all this protocol is.
///
/// It lives in the app target because that is where providers are allowed to be
/// known: `AgentBarUI` may import only `AgentBarCore`, and CLAUDE.md's rule that
/// nothing above the adapter layer knows Claude Code or Codex exist says the
/// same thing from the other direction.
@MainActor
protocol ProviderIntegration: AnyObject {
    var provider: Provider { get }
    /// Reads whatever this provider's configuration lives in and maps it onto
    /// the UI's own vocabulary. Disk I/O, so it is called on panel open and
    /// after an action, never on a timer.
    func status() async -> IntegrationStatus
    func perform(_ action: IntegrationAction) async -> IntegrationActionResult
}
