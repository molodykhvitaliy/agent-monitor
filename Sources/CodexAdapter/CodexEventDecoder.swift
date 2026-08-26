import AgentBarCore
import AgentBarIngest
import AgentBarJSON
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
    /// `request_user_input` and `PermissionRequest` are the two waits Codex can
    /// expose without AgentBar taking part in the answer. There is no `failed`:
    /// Codex has no counterpart to `StopFailure`, so a turn that dies on an API
    /// error arrives as an ordinary `Stop` if it arrives at all.
    private func kind(of payload: CodexHookPayload) -> EventKind? {
        switch payload.event {
        case .sessionStart: .sessionStarted
        case .userPromptSubmit: .turnStarted
        case .preToolUse:
            payload.toolName == CodexToolInvocation.requestUserInputTool
                ? .waitingInput(question: CodexToolInvocation.question(input: payload.toolInput))
                : .toolStarted
        case .postToolUse, .postToolUseFailure: .toolFinished
        case .permissionRequest:
            .waitingPermission(
                PermissionRequestRef(
                    id: Self.permissionRequestID(for: payload),
                    summary: CodexToolInvocation.approvalSummary(
                        tool: payload.toolName, input: payload.toolInput)))
        case .subagentStart: .subagentStarted
        case .subagentStop: .subagentStopped
        case .stop: .turnFinished
        case .sessionEnd: .sessionEnded
        // Documented events AgentBar does not install and does not act on. Named
        // rather than defaulted so adding one is a compiler error here first.
        case .preCompact, .postCompact: nil
        case nil: nil
        }
    }

    /// A stable, opaque observation id for a hook payload that documents no
    /// request id of its own.
    ///
    /// The id is deliberately unusable as a decision handle. It exists only so
    /// two deliveries of the same local request describe the same domain state;
    /// an eventual Approve/Deny feature must use the App Server request id it is
    /// replying to, never this fingerprint.
    private static func permissionRequestID(for payload: CodexHookPayload) -> PermissionRequestID {
        let canonicalInput = payload.toolInput.map(Self.canonicalized) ?? .null
        let identity = JSONValue.object(
            JSONObject([
                ("turn_id", payload.turnId.map(JSONValue.string) ?? .null),
                ("tool_name", payload.toolName.map(JSONValue.string) ?? .null),
                ("tool_input", canonicalInput),
            ]))
        var fingerprint: UInt64 = 14_695_981_039_346_656_037
        for byte in JSONWriter.data(identity) {
            fingerprint ^= UInt64(byte)
            fingerprint &*= 1_099_511_628_211
        }
        return PermissionRequestID(String(format: "codex:%016llx", fingerprint))
    }

    /// Sorts object keys recursively before hashing. `JSONObject` equality is
    /// order-independent but its writer preserves source order, and two
    /// semantically identical hook payloads must not gain different ids merely
    /// because Codex changed field order.
    private static func canonicalized(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            return .object(
                JSONObject(
                    object.pairs.sorted { $0.key < $1.key }.map {
                        ($0.key, canonicalized($0.value))
                    }))
        case .array(let values):
            return .array(values.map(canonicalized))
        case .string, .number, .bool, .null:
            return value
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
