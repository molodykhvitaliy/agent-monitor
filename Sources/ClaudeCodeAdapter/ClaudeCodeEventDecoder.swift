import AgentBarCore
import AgentBarIngest
import Foundation

/// Translates a Claude Code hook payload into domain events.
///
/// This is the whole boundary. Everything Claude Code's JSON looks like stops
/// here, and what leaves is `AgentEvent`, which names facts rather than a
/// provider's vocabulary. A payload describing something AgentBar does not track
/// produces no events rather than an error: an unrecognised delivery is not a
/// fault, and Claude Code never retries a hook it considers failed.
public struct ClaudeCodeEventDecoder: EventDecoding {
    /// Tools whose whole purpose is to block on a person.
    ///
    /// `PreToolUse` for one of these is not the agent starting work, it is the
    /// agent stopping to ask. Without this, a session waiting on
    /// `AskUserQuestion` reads as working until the watchdog gives up on it —
    /// and "an agent asked you something" is one of the three things AgentBar
    /// exists to tell a person about. A set rather than a constant because
    /// `ExitPlanMode` is a candidate whose behaviour depends on the permission
    /// mode, and this is the seam that decides it without a new code path.
    public static let defaultWaitingTools: Set<String> = ["AskUserQuestion"]

    private let waitingTools: Set<String>

    public init(waitingTools: Set<String> = ClaudeCodeEventDecoder.defaultWaitingTools) {
        self.waitingTools = waitingTools
    }

    /// Where the endpoint expects this decoder's traffic. The installer writes
    /// the matching URL, so the two cannot drift apart.
    public static let route = IngestRoute.hooks(of: .claudeCode)

    public func decode(_ body: Data, in context: EventDecodingContext) throws -> [AgentEvent] {
        let payload = try ClaudeCodeHookPayload(body)
        guard let kind = kind(of: payload) else { return [] }
        let cwd = URL(filePath: payload.cwd)
        let tool = payload.toolName.map {
            ToolRef(
                name: $0, invocation: ToolInvocation.summarise(tool: $0, input: payload.toolInput))
        }
        return [
            AgentEvent(
                provider: .claudeCode,
                sessionId: SessionID(payload.sessionId),
                kind: kind,
                cwd: cwd,
                project: context.resolver.project(for: cwd),
                // Claude Code puts no timestamp in a hook payload — `prompt_id`
                // is a UUID and orders nothing — so receipt time is not merely
                // the safe choice, it is the only one available.
                timestamp: context.receivedAt,
                turnId: payload.promptId.map(TurnID.init),
                model: payload.model,
                tool: tool,
                toolUseId: payload.toolUseId.map(ToolUseID.init),
                agent: agent(of: payload),
                raw: RawPayload(summary: diagnostic(for: payload)))
        ]
    }

    /// What the payload says happened, in domain terms.
    private func kind(of payload: ClaudeCodeHookPayload) -> EventKind? {
        switch payload.event {
        case .sessionStart:
            return .sessionStarted
        case .userPromptSubmit:
            return .turnStarted
        case .preToolUse:
            guard let name = payload.toolName, waitingTools.contains(name) else {
                return .toolStarted
            }
            return .waitingInput
        case .postToolUse, .postToolUseFailure:
            // A failed tool call is still a finished one. `PostToolUse` fires
            // only on success, so treating the failure as anything else leaves
            // the call open and the row showing a tool that stopped running.
            return .toolFinished
        case .notification:
            guard let notification = payload.notification, notification.meansBlockedOnHuman else {
                return nil
            }
            return .waitingInput
        case .subagentStart:
            return .subagentStarted
        case .subagentStop:
            return .subagentStopped
        case .stop:
            return .turnFinished
        case .stopFailure:
            return .failed(reason: ClaudeCodeEventDecoder.failureReason(payload.errorType))
        case .sessionEnd:
            return .sessionEnded
        case nil:
            return nil
        }
    }

    /// `agent_id` is present only inside a subagent, which is exactly how a
    /// main-thread event is recognised. `agent_type` alone is not enough: a
    /// session started with `--agent` carries it on every event.
    private func agent(of payload: ClaudeCodeHookPayload) -> AgentRef {
        guard let id = payload.agentId else { return .main }
        return .subagent(id: AgentID(id), type: payload.agentType)
    }

    /// A sentence for the row, from an error type meant for a matcher.
    ///
    /// Unknown values are reworded rather than dropped, so a failure Claude Code
    /// adds in a later release still reads as something instead of as nothing.
    static func failureReason(_ errorType: String?) -> String {
        guard let errorType, !errorType.isEmpty else { return "The turn ended in an error" }
        switch errorType {
        case "rate_limit": return "Rate limit reached"
        case "overloaded": return "The API is overloaded"
        case "authentication_failed": return "Authentication failed"
        case "oauth_org_not_allowed": return "This organisation is not allowed"
        case "billing_error": return "Billing error"
        case "invalid_request": return "The request was rejected"
        case "model_not_found": return "The model is unavailable"
        case "server_error": return "Server error"
        case "max_output_tokens": return "The reply hit the output limit"
        case "unknown": return "The turn ended in an error"
        default:
            let spaced = errorType.replacingOccurrences(of: "_", with: " ")
            return spaced.prefix(1).uppercased() + spaced.dropFirst()
        }
    }

    /// One line for a log, and nothing a person wrote.
    ///
    /// The event name plus whichever field distinguishes this delivery from the
    /// next. Prompts, commands and file contents stay out: a diagnostic is the
    /// thing most likely to be pasted into a bug report.
    private func diagnostic(for payload: ClaudeCodeHookPayload) -> String {
        var parts = [payload.eventName]
        if let tool = payload.toolName { parts.append("tool=\(tool)") }
        if let notification = payload.notification { parts.append("type=\(notification.rawValue)") }
        // `error` is a small taxonomy value on `StopFailure` and the failing
        // tool's own message on `PostToolUseFailure` — which can be a slice of
        // the user's source or a command's stderr. Only the taxonomy is safe to
        // repeat.
        if payload.event == .stopFailure, let errorType = payload.errorType {
            parts.append("error=\(errorType)")
        }
        if let reason = payload.endReason { parts.append("reason=\(reason)") }
        if payload.agentId != nil, let type = payload.agentType { parts.append("agent=\(type)") }
        return parts.joined(separator: " ")
    }
}
