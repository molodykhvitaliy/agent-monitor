import AgentBarCore
import AgentBarIngest
import AgentBarJSON
import Foundation
import Testing

@testable import CodexAdapter

/// Decoding, driven by the payload shapes Codex documents — see
/// `Fixtures/README.md` for what is captured and what is not.
@Suite("Codex payload decoding")
struct EventDecodingTests {
    static let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)
    static let session = SessionID("0198f6a3-2b71-7c4e-9d10-2f5a1c3b8e44")

    static func context() -> EventDecodingContext {
        EventDecodingContext(
            receivedAt: receivedAt, transport: .loopback, resolver: PathProjectResolver())
    }

    static func decode(_ fixture: String) throws -> [AgentEvent] {
        try CodexEventDecoder().decode(try Fixtures.data(fixture), in: context())
    }

    static func single(_ fixture: String) throws -> AgentEvent {
        let events = try decode(fixture)
        #expect(events.count == 1)
        return try #require(events.first)
    }

    @Test("A session announces itself, carrying the model")
    func decodesSessionStart() throws {
        let event = try Self.single("session-start")
        #expect(event.provider == .codex)
        #expect(event.kind == .sessionStarted)
        #expect(event.sessionId == Self.session)
        #expect(event.cwd.path(percentEncoded: false) == "/Users/dev/projects/probe")
        #expect(event.project.name == "probe")
        // The one thing Codex gives that Claude Code cannot: `model` arrives on
        // every event, where Claude Code carries it only on `SessionStart` — an
        // event that takes no `http` handler.
        #expect(event.model == "gpt-5.1-codex-max")
        #expect(event.agent == .main)
        #expect(event.timestamp == Self.receivedAt)
    }

    @Test("A submitted prompt starts a turn, carrying the turn id")
    func decodesUserPromptSubmit() throws {
        let event = try Self.single("user-prompt-submit")
        #expect(event.kind == .turnStarted)
        #expect(event.turnId == TurnID("0198f6a3-2b95-7a02-bb31-6d4c9f2a7e11"))
    }

    @Test("A tool call opens with the name and the identifier that closes it")
    func decodesPreToolUse() throws {
        let event = try Self.single("pre-tool-use-shell")
        #expect(event.kind == .toolStarted)
        #expect(event.tool?.name == "shell")
        // The shell tool sends an argv, and the row shows the command line it
        // stands for rather than a rendering of a JSON array.
        #expect(event.tool?.invocation == "bash -lc swift test --parallel")
        #expect(event.toolUseId == ToolUseID("call_9f2b6c7a41d84e0f"))
    }

    @Test("A finished tool call closes the one that opened it")
    func decodesPostToolUse() throws {
        let event = try Self.single("post-tool-use-shell")
        #expect(event.kind == .toolFinished)
        #expect(event.toolUseId == ToolUseID("call_9f2b6c7a41d84e0f"))
    }
}

@Suite("Codex interaction payload decoding")
struct CodexInteractionDecodingTests {
    static func context() -> EventDecodingContext {
        EventDecodingTests.context()
    }

    @Test("request_user_input becomes a question with nested copy")
    func decodesRequestUserInput() throws {
        let body = Data(
            """
            {"hook_event_name":"PreToolUse","session_id":"s","cwd":"/tmp",
             "turn_id":"t","tool_name":"request_user_input","tool_use_id":"call-q",
             "tool_input":{"questions":[
               {"header":"Branch","question":"Which branch should I use?"},
               {"header":"Tests","question":"Run the live suite too?"}
             ]}}
            """.utf8)
        let event = try #require(
            try CodexEventDecoder().decode(body, in: Self.context()).first)
        #expect(event.kind == .waitingInput(question: "Which branch should I use? (+1 more)"))
        #expect(event.tool?.name == CodexToolInvocation.requestUserInputTool)
    }

    @Test("A changed question shape stays a visible wait")
    func questionShapeDegrades() throws {
        for input in [#"{"questions":[{"header":"Database"}]}"#, #"{"questions":"moved"}"#] {
            let body = Data(
                """
                {"hook_event_name":"PreToolUse","session_id":"s","cwd":"/tmp",
                 "tool_name":"request_user_input","tool_input":\(input)}
                """.utf8)
            let event = try #require(
                try CodexEventDecoder().decode(body, in: Self.context()).first)
            if input.contains("Database") {
                #expect(event.kind == .waitingInput(question: "Database"))
            } else {
                #expect(event.kind == .waitingInput(question: "Codex needs your input"))
            }
        }
    }

    @Test("A later real question outranks an earlier header-only item")
    func questionPrefersQuestionAcrossTheArray() throws {
        let body = Data(
            """
            {"hook_event_name":"PreToolUse","session_id":"s","cwd":"/tmp",
             "tool_name":"request_user_input","tool_input":{"questions":[
               {"header":"First"},{"question":"Actual question"}]}}
            """.utf8)
        let event = try #require(
            CodexEventDecoder().decode(body, in: Self.context()).first)
        #expect(event.kind == .waitingInput(question: "Actual question (+1 more)"))
    }

    @Test("A PermissionRequest is observation state, with a stable opaque id")
    func decodesPermissionRequest() throws {
        let first = Data(
            """
            {"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/tmp",
             "turn_id":"t","tool_name":"Bash",
             "tool_input":{"command":["git","push"],"description":"Push to origin"}}
            """.utf8)
        let reordered = Data(
            """
            {"cwd":"/tmp","session_id":"s","hook_event_name":"PermissionRequest",
             "tool_name":"Bash","turn_id":"t",
             "tool_input":{"description":"Push to origin","command":["git","push"]}}
            """.utf8)
        let changed = Data(
            """
            {"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/tmp",
             "turn_id":"t","tool_name":"Bash","tool_input":{"command":["git","fetch"]}}
            """.utf8)

        let one = try #require(CodexEventDecoder().decode(first, in: Self.context()).first)
        let two = try #require(CodexEventDecoder().decode(reordered, in: Self.context()).first)
        let three = try #require(CodexEventDecoder().decode(changed, in: Self.context()).first)
        guard case .waitingPermission(let request) = one.kind,
            case .waitingPermission(let same) = two.kind,
            case .waitingPermission(let other) = three.kind
        else {
            Issue.record("expected waitingPermission")
            return
        }
        #expect(request.summary == "Push to origin")
        #expect(request.id.value.hasPrefix("codex:"))
        #expect(request.id == same.id)
        #expect(request.id != other.id)
        #expect(!request.id.value.contains("Push"))
        #expect(!request.id.value.contains("git"))
    }

    @Test("A minimal PermissionRequest still becomes a safe visible approval")
    func decodesMinimalPermissionRequest() throws {
        let body = Data(
            #"{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/tmp"}"#.utf8)
        let event = try #require(
            CodexEventDecoder().decode(body, in: Self.context()).first)
        guard case .waitingPermission(let request) = event.kind else {
            Issue.record("expected waitingPermission")
            return
        }
        #expect(request.summary == "Codex requested approval")
        #expect(request.id.value.hasPrefix("codex:"))
    }

    @Test("Observed waits recover on the next Codex lifecycle event")
    func observedWaitsRecover() async throws {
        let store = SessionStore()
        let context = EventDecodingContext(
            receivedAt: Date(), transport: .loopback, resolver: PathProjectResolver())

        func apply(_ json: String) async throws {
            let event = try #require(
                CodexEventDecoder().decode(Data(json.utf8), in: context).first)
            await store.apply(event)
        }

        try await apply(
            #"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/tmp"}"#)
        #expect(await store.snapshot().sessions.first?.state == .working)

        try await apply(
            """
            {"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/tmp",
             "turn_id":"t","tool_name":"Bash","tool_input":{"command":"git push"}}
            """
        )
        guard case .waitingPermission = await store.snapshot().sessions.first?.state else {
            Issue.record("expected permission wait")
            return
        }

        try await apply(
            """
            {"hook_event_name":"PreToolUse","session_id":"s","cwd":"/tmp",
             "tool_name":"shell","tool_use_id":"call-1","tool_input":{"command":"pwd"}}
            """
        )
        #expect(await store.snapshot().sessions.first?.state == .working)

        try await apply(
            """
            {"hook_event_name":"PreToolUse","session_id":"s","cwd":"/tmp",
             "tool_name":"request_user_input",
             "tool_input":{"questions":[{"question":"Continue?"}]}}
            """
        )
        #expect(
            await store.snapshot().sessions.first?.state == .waitingInput(question: "Continue?"))

        try await apply(
            """
            {"hook_event_name":"PostToolUseFailure","session_id":"s","cwd":"/tmp",
             "tool_name":"request_user_input"}
            """
        )
        #expect(await store.snapshot().sessions.first?.state == .working)

        try await apply(
            #"{"hook_event_name":"Stop","session_id":"s","cwd":"/tmp"}"#)
        #expect(await store.snapshot().sessions.first?.state == .idle)
    }
}

@Suite("Codex lifecycle payload decoding")
struct CodexLifecycleDecodingTests {
    static func context() -> EventDecodingContext {
        EventDecodingTests.context()
    }

    static func decode(_ fixture: String) throws -> [AgentEvent] {
        try EventDecodingTests.decode(fixture)
    }

    static func single(_ fixture: String) throws -> AgentEvent {
        try EventDecodingTests.single(fixture)
    }

    @Test("A tool whose arguments carry a patch shows the path, never the patch")
    func decodesApplyPatch() throws {
        let event = try Self.single("pre-tool-use-apply-patch")
        let invocation = try #require(event.tool?.invocation)
        #expect(invocation.contains("Main.swift"))
        #expect(!invocation.contains("Begin Patch"))
        #expect(invocation.count <= CodexToolInvocation.limit)
    }

    @Test("A subagent's events are attributed to the subagent")
    func decodesSubagent() throws {
        let start = try Self.single("subagent-start")
        #expect(start.kind == .subagentStarted)
        #expect(start.agent == .subagent(id: AgentID("agent_5d3f9b71"), type: "reviewer"))
        let stop = try Self.single("subagent-stop")
        #expect(stop.kind == .subagentStopped)
        #expect(stop.agent.subagentId == AgentID("agent_5d3f9b71"))
    }

    @Test("A turn ends, and a session ends")
    func decodesTerminals() throws {
        #expect(try Self.single("stop").kind == .turnFinished)
        let end = try Self.single("session-end")
        #expect(end.kind == .sessionEnded)
        // No `turn_id` and no `permission_mode` on this event, and reading it
        // must not depend on either.
        #expect(end.turnId == nil)
    }

    @Test("An event AgentBar does not act on decodes to nothing at all")
    func ignoresUnsubscribedEvent() throws {
        #expect(try Self.decode("pre-compact").isEmpty)
    }

    @Test("An event Codex has not invented yet is ignored rather than refused")
    func ignoresUnknownEvent() throws {
        let body = Data(
            #"{"hook_event_name":"SomethingNew","session_id":"s","cwd":"/tmp"}"#.utf8)
        #expect(try CodexEventDecoder().decode(body, in: Self.context()).isEmpty)
    }

    @Test(
        "A payload missing what identifies a session is refused",
        arguments: [
            #"{"session_id":"s","cwd":"/tmp"}"#,
            #"{"hook_event_name":"Stop","cwd":"/tmp"}"#,
            #"{"hook_event_name":"Stop","session_id":"s"}"#,
            #"{"hook_event_name":"Stop","session_id":"","cwd":"/tmp"}"#,
        ]
    )
    func refusesIncompletePayload(json: String) throws {
        #expect(throws: CodexDecodingError.self) {
            try CodexEventDecoder().decode(Data(json.utf8), in: Self.context())
        }
    }

    @Test("A field that arrives as the wrong type degrades one field, not the payload")
    func toleratesTypeDrift() throws {
        let body = Data(
            """
            {"hook_event_name":"PreToolUse","session_id":"s","cwd":"/tmp",
             "turn_id":42,"model":{"name":"x"},"tool_name":"shell",
             "tool_input":"not an object","tool_use_id":["a"]}
            """.utf8)
        let event = try #require(
            try CodexEventDecoder().decode(body, in: Self.context()).first)
        #expect(event.kind == .toolStarted)
        #expect(event.tool?.name == "shell")
        #expect(event.tool?.invocation == nil)
        #expect(event.turnId == nil)
        #expect(event.model == nil)
        #expect(event.toolUseId == nil)
    }

    @Test("Malformed JSON is a decoding error, not a crash")
    func refusesMalformedJSON() throws {
        #expect(throws: CodexDecodingError.self) {
            try CodexEventDecoder().decode(Data("{".utf8), in: Self.context())
        }
        #expect(throws: CodexDecodingError.self) {
            try CodexEventDecoder().decode(Data("[]".utf8), in: Self.context())
        }
    }

    @Test("The diagnostic line names the delivery and repeats nothing a person wrote")
    func diagnosticCarriesNoContent() throws {
        let event = try Self.single("user-prompt-submit")
        let summary = event.raw.diagnosticSummary
        #expect(summary == "UserPromptSubmit")
        #expect(!summary.contains("run the tests"))
    }

    @Test("The decoder answers on the route the helper posts to")
    func routeMatchesTheHelper() {
        #expect(CodexEventDecoder.route == IngestRoute.hooks(of: .codex))
        #expect(CodexEventDecoder.route.path == "/v1/hooks/codex")
    }
}
