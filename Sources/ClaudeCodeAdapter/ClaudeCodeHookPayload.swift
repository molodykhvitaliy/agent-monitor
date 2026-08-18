import Foundation

public enum ClaudeCodeDecodingError: Error, Sendable, Hashable, CustomStringConvertible {
    case notAnObject
    case malformedJSON(String)
    case missingField(String)

    public var description: String {
        switch self {
        case .notAnObject: "hook payload is not a JSON object"
        case .malformedJSON(let reason): "malformed JSON: \(reason)"
        case .missingField(let name): "hook payload has no usable \"\(name)\""
        }
    }
}

/// One Claude Code hook payload, read field by field.
///
/// Every optional field is optional because the platform documents it as
/// conditional, and every field is read with a type check rather than a cast: a
/// `reason` that arrives as a number in some future release must make this
/// payload slightly less informative, never make it fail. Only the three fields
/// that identify *which session did something* are required, because an event
/// missing those describes nothing AgentBar can record.
struct ClaudeCodeHookPayload: Sendable {
    /// The event, when it is one AgentBar knows. `nil` for anything else — a
    /// handler left behind by an older version, or a hook the user pointed here
    /// on purpose — and an unknown event is ignored rather than refused.
    let event: ClaudeCodeHookEvent?
    let eventName: String
    let sessionId: String
    let cwd: String
    let promptId: String?
    let toolName: String?
    let toolInput: JSONValue?
    let toolUseId: String?
    let agentId: String?
    let agentType: String?
    let notification: ClaudeCodeNotification?
    /// `StopFailure`'s error type, such as `rate_limit`.
    let errorType: String?
    /// `SessionEnd`'s reason, such as `clear`.
    let endReason: String?
    /// Only `SessionStart` carries this, and AgentBar cannot install an `http`
    /// handler on `SessionStart`. Read anyway so the field is not lost if that
    /// ever changes.
    let model: String?

    init(_ body: Data) throws {
        let value: JSONValue
        do {
            value = try JSONParser.parse(body)
        } catch {
            throw ClaudeCodeDecodingError.malformedJSON("\(error)")
        }
        guard let object = value.object else { throw ClaudeCodeDecodingError.notAnObject }

        func text(_ key: String) -> String? {
            guard let value = object[key]?.string, !value.isEmpty else { return nil }
            return value
        }

        guard let eventName = text("hook_event_name") else {
            throw ClaudeCodeDecodingError.missingField("hook_event_name")
        }
        guard let sessionId = text("session_id") else {
            throw ClaudeCodeDecodingError.missingField("session_id")
        }
        guard let cwd = text("cwd") else {
            throw ClaudeCodeDecodingError.missingField("cwd")
        }

        self.eventName = eventName
        event = ClaudeCodeHookEvent(rawValue: eventName)
        self.sessionId = sessionId
        self.cwd = cwd
        promptId = text("prompt_id")
        toolName = text("tool_name")
        toolInput = object["tool_input"]
        toolUseId = text("tool_use_id")
        agentId = text("agent_id")
        agentType = text("agent_type")
        notification = text("notification_type").flatMap(ClaudeCodeNotification.init(rawValue:))
        errorType = text("error")
        endReason = text("reason")
        model = text("model")
    }
}
