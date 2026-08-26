import Foundation
import Testing

@testable import AgentBarCore
@testable import AgentBarIngest

@Suite("Native event decoding")
struct NativeEventDecoderTests {
    static let receipt = Date(timeIntervalSince1970: 1_800_000_000)

    private func context() -> EventDecodingContext {
        EventDecodingContext(
            receivedAt: NativeEventDecoderTests.receipt, transport: .loopback,
            resolver: PathProjectResolver())
    }

    private func decode(_ json: String) throws -> [AgentEvent] {
        try NativeEventDecoder().decode(Data(json.utf8), in: context())
    }

    @Test("Decodes one event")
    func decodesOne() throws {
        let events = try decode(EventPayload.json(kind: "turnStarted"))
        let event = try #require(events.first)
        #expect(events.count == 1)
        #expect(event.provider == .claudeCode)
        #expect(event.sessionId == SessionID("session-1"))
        #expect(event.kind.tag == .turnStarted)
        #expect(event.project.name == "agentbar")
    }

    @Test("Decodes a batch")
    func decodesArray() throws {
        let json =
            "[\(EventPayload.json(kind: "sessionStarted")), "
            + "\(EventPayload.json(kind: "turnStarted"))]"
        #expect(try decode(json).map(\.kind.tag) == [.sessionStarted, .turnStarted])
    }

    @Test("An empty body is no events rather than an error")
    func toleratesEmptyBody() throws {
        #expect(try decode("").isEmpty)
        #expect(try decode("   \n ").isEmpty)
    }

    /// The store's ordering is a high-water mark, so a caller that could choose
    /// its own stamp could freeze a session in `working` for ever. There is no
    /// timestamp field to supply, and one in the body is ignored.
    @Test("Stamps every event with receipt time, whatever the body says")
    func stampsFromReceipt() throws {
        let json = EventPayload.json(
            kind: "turnStarted", extra: ["timestamp": "\"2099-01-01T00:00:00Z\""])
        let event = try #require(try decode(json).first)
        #expect(event.timestamp == NativeEventDecoderTests.receipt)
    }

    @Test("Accepts either spelling of a provider", arguments: ["claudeCode", "claude-code"])
    func acceptsBothProviderSpellings(value: String) throws {
        let event = try #require(
            try decode(EventPayload.json(kind: "turnStarted", provider: value)).first)
        #expect(event.provider == .claudeCode)
    }

    @Test("Carries the tool, the subagent and the turn through")
    func carriesDetail() throws {
        let json = EventPayload.json(
            kind: "toolStarted",
            extra: [
                "tool": #"{"name": "Bash", "invocation": "swift test"}"#,
                "toolUseId": #""toolu_1""#,
                "turnId": #""turn-9""#,
                "model": #""claude-opus-5""#,
                "subagent": #"{"id": "agent-1", "type": "reviewer"}"#,
                "summary": #""PreToolUse Bash""#,
            ])
        let event = try #require(try decode(json).first)
        #expect(event.tool?.name == "Bash")
        #expect(event.tool?.invocation == "swift test")
        #expect(event.toolUseId == ToolUseID("toolu_1"))
        #expect(event.turnId == TurnID("turn-9"))
        #expect(event.model == "claude-opus-5")
        #expect(event.agent.subagentId == AgentID("agent-1"))
        #expect(event.raw.diagnosticSummary == "PreToolUse Bash")
    }

    @Test("A failure carries its reason, and is refused without one")
    func requiresFailureReason() throws {
        let withReason = EventPayload.json(
            kind: "failed", extra: ["failureReason": #""api error""#])
        #expect(try decode(withReason).first?.kind == .failed(reason: "api error"))
        #expect(
            throws: NativeEventDecodingError.missingDetail(kind: "failed", field: "failureReason")
        ) {
            try decode(EventPayload.json(kind: "failed"))
        }
    }

    /// Observation-only: decoding this state never creates a decision channel.
    @Test("A permission request decodes, and is refused without its identifier")
    func decodesPermissionKind() throws {
        let json = EventPayload.json(
            kind: "waitingPermission",
            extra: ["permissionRequest": #"{"id": "perm-1", "summary": "rm -rf"}"#])
        let event = try #require(try decode(json).first)
        guard case .waitingPermission(let request) = event.kind else {
            Issue.record("expected a permission request")
            return
        }
        #expect(request.id == PermissionRequestID("perm-1"))
        #expect(throws: (any Error).self) {
            try decode(EventPayload.json(kind: "waitingPermission"))
        }
    }

    @Test(
        "Refuses what it cannot understand instead of guessing",
        arguments: [
            EventPayload.json(kind: "danced"),
            EventPayload.json(kind: "turnStarted", provider: "cursor"),
            "not json at all",
            "42",
            #"{"provider": "codex"}"#,
        ]
    )
    func refusesUnknownInput(json: String) {
        #expect(throws: (any Error).self) { try decode(json) }
    }
}
