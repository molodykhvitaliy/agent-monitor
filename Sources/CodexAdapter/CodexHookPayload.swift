import AgentBarJSON
import Foundation

public enum CodexDecodingError: Error, Sendable, Hashable, CustomStringConvertible {
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

/// One Codex hook payload, read field by field.
///
/// Read exactly as defensively as the Claude Code payload is, and for the same
/// reason: every optional field is optional because the platform documents it as
/// conditional, and every field is type-checked rather than cast, so a field
/// that changes shape in a later release makes this payload less informative
/// rather than making it fail. Only the three fields that say *which session did
/// something* are required.
struct CodexHookPayload: Sendable {
    /// The event, when it is one AgentBar knows; `nil` for anything else, which
    /// is ignored rather than refused.
    let event: CodexHookEvent?
    let eventName: String
    let sessionId: String
    let cwd: String
    let turnId: String?
    /// Codex sends the model on every event, which Claude Code does not — its
    /// only carrier there is `SessionStart`, an event that takes no `http`
    /// handler.
    let model: String?
    let toolName: String?
    let toolInput: JSONValue?
    let toolUseId: String?
    let agentId: String?
    let agentType: String?
    /// `SessionStart`'s `startup | resume | clear | compact`.
    let source: String?
    /// `SessionEnd`'s reason, `other` at the time of writing.
    let endReason: String?

    init(_ body: Data) throws {
        let value: JSONValue
        do {
            value = try JSONParser.parse(body)
        } catch {
            throw CodexDecodingError.malformedJSON("\(error)")
        }
        guard let object = value.object else { throw CodexDecodingError.notAnObject }

        func text(_ key: String) -> String? {
            guard let value = object[key]?.string, !value.isEmpty else { return nil }
            return value
        }

        guard let eventName = text("hook_event_name") else {
            throw CodexDecodingError.missingField("hook_event_name")
        }
        guard let sessionId = text("session_id") else {
            throw CodexDecodingError.missingField("session_id")
        }
        guard let cwd = text("cwd") else {
            throw CodexDecodingError.missingField("cwd")
        }

        self.eventName = eventName
        event = CodexHookEvent(rawValue: eventName)
        self.sessionId = sessionId
        self.cwd = cwd
        turnId = text("turn_id")
        model = text("model")
        toolName = text("tool_name")
        toolInput = object["tool_input"]
        toolUseId = text("tool_use_id")
        agentId = text("agent_id")
        agentType = text("agent_type")
        source = text("source")
        endReason = text("reason")
    }
}
