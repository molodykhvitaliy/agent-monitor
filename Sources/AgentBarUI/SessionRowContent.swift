import AgentBarCore
import Foundation

/// What one row says, worked out before anything is drawn.
///
/// Separated from the view because these are the row's real decisions — which
/// line appears under which state, in which typeface, and what a screen reader
/// hears — and a decision that only exists inside a `body` is a decision nothing
/// can check.
nonisolated public struct SessionRowContent: Sendable, Hashable {

    /// The line beneath the state, and whether it is set in monospace.
    ///
    /// The typeface is itself a signal: **monospace is text a machine
    /// produced**, proportional is text AgentBar composed or a person wrote.
    public struct Detail: Sendable, Hashable {
        /// `nil` means the line is present but empty — its height is reserved
        /// and there is nothing honest to put in it.
        public let text: String?
        public let isMonospaced: Bool
    }

    public let stateLabel: String
    public let duration: String
    /// `nil` when the row has no second line at all and is one line tall.
    public let detail: Detail?
    public let subagentPill: String?
    public let accessibilityLabel: String
    public let openHint: String
    public let tooltip: String

    public init(session: Session, projectLabel: String) {
        stateLabel = session.state.kind.label
        duration = DurationText.compact(session.timeInState)
        detail = Self.detail(for: session)
        subagentPill = session.activeSubagentCount > 0 ? "+\(session.activeSubagentCount)" : nil

        var parts = [
            session.provider.displayName, session.state.kind.label, projectLabel,
            DurationText.spoken(session.timeInState),
        ]
        if session.activeSubagentCount > 0 {
            parts.append(
                String(
                    localized: "\(session.activeSubagentCount) subagents",
                    comment: "Session row accessibility label, subagent count"))
        }
        accessibilityLabel = parts.joined(separator: ", ")

        openHint = String(
            localized: "Open \(projectLabel) in the default application",
            comment: "Session row action")
        // `uptime`, `startedAt` and `lastEventAt` all live here: none of them
        // earns a place in a resting row, and this absorbs them without adding
        // a pixel.
        tooltip =
            openHint + "\n"
            + DurationText.startedAndRunning(at: session.startedAt, uptime: session.uptime)
    }

    /// One line per state, and one rule that matters more than the rest.
    ///
    /// **A working row reserves the line's height for as long as it is
    /// working** and shows the tool only when one is open. `currentTool` is nil
    /// from `turnStarted` until the first call opens, and again between every
    /// `toolFinished` and the next `toolStarted` — many times a second on a busy
    /// turn. A row that changes height twice a second is worse than one carrying
    /// a blank line, and nothing may be invented to fill it: not a placeholder,
    /// not "Thinking".
    private static func detail(for session: Session) -> Detail? {
        switch session.state {
        case .working:
            // `ToolRef.invocation` is nil more often than it looks:
            // `ToolInvocation.summarise` has no rule for `TodoWrite`,
            // `ExitPlanMode` or anything it does not recognise. The bare tool
            // name beats dropping the line.
            return Detail(
                text: session.currentTool.map { $0.invocation ?? $0.name }, isMonospaced: true)
        case .failed(let reason):
            // Monospace because the reason really can be a machine string:
            // `NativeEventDecoder` passes a caller-supplied one straight
            // through, and Codex's shape is not written yet.
            return Detail(text: reason, isMonospaced: true)
        case .waitingInput(let question):
            // Present only when the agent actually asked something (ADR-0005).
            // The permission and elicitation paths stay bare, correctly: there
            // the state label already says everything there is to say, and the
            // full-row wash is what makes the row unmissable.
            guard let question else { return nil }
            return Detail(text: question, isMonospaced: false)
        case .unknown:
            return Detail(text: silenceLine(for: session), isMonospaced: false)
        case .idle, .waitingPermission:
            return nil
        }
    }

    /// The two numbers on an unknown row mean different things and must not be
    /// swapped: the corner shows `timeInState`, which the store redefines for a
    /// derived `unknown` as *how long it has read as unknown*, and this line
    /// shows the full silence — always the larger, by exactly the watchdog's
    /// allowance for that state.
    private static func silenceLine(for session: Session) -> String {
        let silence = DurationText.compact(session.timeSinceLastEvent)
        return String(
            localized: "Stopped reporting\(DesignTokens.separator)last seen \(silence) ago",
            comment: "Detail line for a session that went quiet")
    }
}
