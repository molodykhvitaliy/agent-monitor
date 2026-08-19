import AgentBarCore
import Foundation

public enum NativeEventDecodingError: Error, Sendable, Hashable, CustomStringConvertible {
    case notAnObjectOrArray
    case malformedJSON(String)
    case unknownProvider(String)
    case unknownKind(String)
    case missingDetail(kind: String, field: String)

    public var description: String {
        switch self {
        case .notAnObjectOrArray: "body is neither a JSON object nor an array"
        case .malformedJSON(let reason): "malformed JSON: \(reason)"
        case .unknownProvider(let value): "unknown provider \"\(value)\""
        case .unknownKind(let value): "unknown event kind \"\(value)\""
        case .missingDetail(let kind, let field): "\(kind) needs \(field)"
        }
    }
}

/// AgentBar's own event envelope — the domain model, spelled as JSON.
///
/// It is not a provider format and never becomes one. It exists so the endpoint
/// can be driven without either agent installed, which is what makes a `curl` an
/// end-to-end test rather than a test of the parser; and it gives a source that
/// is neither Claude Code nor Codex somewhere to arrive without an adapter being
/// written for it first.
///
/// It carries **no timestamp**, which is a decision rather than an omission.
/// Ordering in the store is a high-water mark, so a caller able to choose its
/// own stamp is a caller able to freeze a session in `working` for ever — see
/// `EventDecodingContext`.
public struct NativeEventDecoder: EventDecoding {
    public init() {}

    public func decode(_ body: Data, in context: EventDecodingContext) throws -> [AgentEvent] {
        guard let first = body.first(where: { !$0.isASCIIWhitespace }) else { return [] }
        let decoder = JSONDecoder()
        do {
            switch first {
            case UInt8(ascii: "["):
                return try decoder.decode([NativeEventEnvelope].self, from: body)
                    .map { try $0.event(in: context) }
            case UInt8(ascii: "{"):
                return [try decoder.decode(NativeEventEnvelope.self, from: body).event(in: context)]
            default:
                throw NativeEventDecodingError.notAnObjectOrArray
            }
        } catch let error as DecodingError {
            throw NativeEventDecodingError.malformedJSON("\(error)")
        }
    }
}

/// One event as the native envelope spells it.
struct NativeEventEnvelope: Decodable {
    struct Tool: Decodable {
        let name: String
        let invocation: String?
    }

    struct Subagent: Decodable {
        let id: String
        let type: String?
    }

    struct Permission: Decodable {
        let id: String
        let summary: String?
    }

    let provider: String
    let sessionId: String
    let kind: String
    let cwd: String
    let turnId: String?
    let model: String?
    let tool: Tool?
    let toolUseId: String?
    let subagent: Subagent?
    let failureReason: String?
    let permissionRequest: Permission?
    /// The question a `waitingInput` event is reporting, when the caller has
    /// one. Optional on purpose: most waiting has nothing specific to say
    /// (ADR-0005).
    let question: String?
    /// One line for a log. Bounded by `RawPayload`, and never echoed back.
    let summary: String?

    func event(in context: EventDecodingContext) throws -> AgentEvent {
        let workingDirectory = URL(filePath: cwd)
        return AgentEvent(
            provider: try resolvedProvider(),
            sessionId: SessionID(sessionId),
            kind: try resolvedKind(),
            cwd: workingDirectory,
            project: context.resolver.project(for: workingDirectory),
            timestamp: context.receivedAt,
            turnId: turnId.map(TurnID.init),
            model: model,
            tool: tool.map {
                ToolRef(name: $0.name, invocation: $0.invocation.map(NativeEventEnvelope.bounded))
            },
            toolUseId: toolUseId.map(ToolUseID.init),
            agent: subagent.map { .subagent(id: AgentID($0.id), type: $0.type) } ?? .main,
            raw: RawPayload(summary: summary ?? ""))
    }

    /// Display lines are kept for as long as their session is, and this
    /// envelope's are chosen by the caller. Bounding them here is the same
    /// contract `ToolInvocation` meets on the Claude Code side; a body limit
    /// alone would still admit one 64 KB line.
    static let displayLineLimit = 120

    static func bounded(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > displayLineLimit else { return collapsed }
        return String(collapsed.prefix(displayLineLimit - 1)) + "…"
    }

    /// Accepts either spelling — the domain's own case name, or the slug the
    /// route uses — because a caller that has just read the URL should not have
    /// to learn a second name for the same thing.
    private func resolvedProvider() throws -> Provider {
        let matched = Provider.allCases.first {
            $0.rawValue == provider || IngestRoute.slug(of: $0) == provider
        }
        guard let matched else { throw NativeEventDecodingError.unknownProvider(provider) }
        return matched
    }

    private func resolvedKind() throws -> EventKind {
        guard let tag = EventKindTag(rawValue: kind) else {
            throw NativeEventDecodingError.unknownKind(kind)
        }
        switch tag {
        case .sessionStarted: return .sessionStarted
        case .turnStarted: return .turnStarted
        case .toolStarted: return .toolStarted
        case .toolFinished: return .toolFinished
        case .subagentStarted: return .subagentStarted
        case .subagentStopped: return .subagentStopped
        case .waitingInput: return .waitingInput(question: question.map(Self.bounded))
        case .turnFinished: return .turnFinished
        case .sessionEnded: return .sessionEnded
        case .failed:
            guard let failureReason else {
                throw NativeEventDecodingError.missingDetail(kind: kind, field: "failureReason")
            }
            // Bounded like every other display string this envelope carries: a
            // failure reason is held in `SessionState` for the session's life
            // and again in the history, and this envelope's content is chosen
            // by the caller.
            return .failed(reason: NativeEventEnvelope.bounded(failureReason))
        case .waitingPermission:
            guard let permissionRequest else {
                throw NativeEventDecodingError.missingDetail(kind: kind, field: "permissionRequest")
            }
            return .waitingPermission(
                PermissionRequestRef(
                    id: PermissionRequestID(permissionRequest.id),
                    summary: permissionRequest.summary))
        }
    }
}

extension UInt8 {
    fileprivate var isASCIIWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}
