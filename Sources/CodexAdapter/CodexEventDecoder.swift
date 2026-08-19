import AgentBarCore
import AgentBarIngest
import Foundation

/// Translates a Codex hook payload into domain events.
///
/// The whole boundary, and the mirror image of `ClaudeCodeEventDecoder`:
/// everything Codex's JSON looks like stops here, and what leaves is
/// `AgentEvent`. A payload describing something AgentBar does not track produces
/// no events rather than an error — an unrecognised delivery is not a fault, and
/// the helper has already exited by the time this runs, so there is nobody left
/// to report a failure to.
public struct CodexEventDecoder: EventDecoding {
    /// Where the endpoint expects this decoder's traffic. The helper posts to
    /// the matching path, so the two cannot drift apart.
    public static let route = CodexEndpoint.route

    public init() {}

    public func decode(_ body: Data, in context: EventDecodingContext) throws -> [AgentEvent] {
        let payload = try CodexHookPayload(body)
        guard let kind = kind(of: payload) else { return [] }
        let cwd = URL(filePath: payload.cwd)
        let tool = payload.toolName.map {
            ToolRef(
                name: $0,
                invocation: CodexToolInvocation.summarise(tool: $0, input: payload.toolInput))
        }
        return [
            AgentEvent(
                provider: .codex,
                sessionId: SessionID(payload.sessionId),
                kind: kind,
                cwd: cwd,
                project: context.resolver.project(for: cwd),
                // Receipt time, as on the Claude Code side. Codex puts no
                // timestamp in a hook payload either, and one taken from a body
                // could poison the store's high-water mark.
                timestamp: context.receivedAt,
                turnId: payload.turnId.map(TurnID.init),
                model: payload.model,
                tool: tool,
                toolUseId: payload.toolUseId.map(ToolUseID.init),
                agent: agent(of: payload),
                raw: RawPayload(summary: diagnostic(for: payload)))
        ]
    }

    /// What the payload says happened, in domain terms.
    ///
    /// Two absences are worth naming. There is no `waitingInput` on any branch:
    /// Codex's only "blocked on a human" event is `PermissionRequest`, which
    /// AgentBar does not install (see `CodexHookHandler.monitoring`), so a Codex
    /// session waiting on an approval reads as `working` until the watchdog
    /// demotes it. And there is no `failed`: Codex has no counterpart to
    /// `StopFailure`, so a turn that dies on an API error arrives as an ordinary
    /// `Stop` if it arrives at all.
    private func kind(of payload: CodexHookPayload) -> EventKind? {
        switch payload.event {
        case .sessionStart: .sessionStarted
        case .userPromptSubmit: .turnStarted
        case .preToolUse: .toolStarted
        case .postToolUse: .toolFinished
        case .subagentStart: .subagentStarted
        case .subagentStop: .subagentStopped
        case .stop: .turnFinished
        case .sessionEnd: .sessionEnded
        // Documented events AgentBar does not install and does not act on. Named
        // rather than defaulted so adding one is a compiler error here first.
        case .permissionRequest, .preCompact, .postCompact: nil
        case nil: nil
        }
    }

    /// `agent_id` is present only inside a subagent, which is how a main-thread
    /// event is recognised — the same rule the Claude Code adapter uses, and for
    /// the same reason: `agent_type` alone would misread a session that was
    /// started as an agent.
    private func agent(of payload: CodexHookPayload) -> AgentRef {
        guard let id = payload.agentId else { return .main }
        return .subagent(id: AgentID(id), type: payload.agentType)
    }

    /// One line for a log, and nothing a person wrote.
    ///
    /// The event name plus whichever field distinguishes this delivery from the
    /// next. Prompts, commands and file contents stay out: a diagnostic is the
    /// thing most likely to be pasted into a bug report.
    private func diagnostic(for payload: CodexHookPayload) -> String {
        var parts = [payload.eventName]
        if let tool = payload.toolName { parts.append("tool=\(tool)") }
        if let source = payload.source { parts.append("source=\(source)") }
        if let reason = payload.endReason { parts.append("reason=\(reason)") }
        if payload.agentId != nil, let type = payload.agentType { parts.append("agent=\(type)") }
        return parts.joined(separator: " ")
    }
}
