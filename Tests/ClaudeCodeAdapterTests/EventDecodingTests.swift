import AgentBarCore
import AgentBarIngest
import Foundation
import Testing

@testable import ClaudeCodeAdapter

/// Decoding, driven entirely by payloads Claude Code sent — see
/// `Fixtures/README.md` for how they were captured.
@Suite("Claude Code payload decoding")
struct EventDecodingTests {
    static let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)

    static func context() -> EventDecodingContext {
        EventDecodingContext(
            receivedAt: receivedAt, transport: .loopback, resolver: PathProjectResolver())
    }

    static func decode(
        _ fixture: String, decoder: ClaudeCodeEventDecoder = ClaudeCodeEventDecoder()
    ) throws -> [AgentEvent] {
        try decoder.decode(try Fixtures.data(fixture), in: context())
    }

    static func single(_ fixture: String) throws -> AgentEvent {
        let events = try decode(fixture)
        #expect(events.count == 1)
        return try #require(events.first)
    }

    @Test("A submitted prompt starts a turn, carrying the prompt id")
    func decodesUserPromptSubmit() throws {
        let event = try Self.single("user-prompt-submit")
        #expect(event.provider == .claudeCode)
        #expect(event.kind == .turnStarted)
        #expect(event.sessionId == SessionID("15ca0fb1-dd1d-4f0f-a72e-d5bd88d662e5"))
        #expect(event.turnId == TurnID("e17fc6e7-66aa-40cd-b9a2-ac996892cc1a"))
        #expect(event.cwd.path(percentEncoded: false) == "/Users/dev/projects/probe")
        #expect(event.project.name == "probe")
        #expect(event.agent == .main)
        // Receipt time, because a Claude Code payload carries no timestamp.
        #expect(event.timestamp == Self.receivedAt)
    }

    @Test("A tool call opens with the name and the identifier that closes it")
    func decodesPreToolUse() throws {
        let event = try Self.single("pre-tool-use-bash")
        #expect(event.kind == .toolStarted)
        #expect(event.tool?.name == "Bash")
        #expect(event.tool?.invocation == "echo hello")
        #expect(event.toolUseId == ToolUseID("toolu_01Vj84rdcGMLu6tvr3GoxQRd"))
    }

    @Test("The VS Code extension's payload decodes the same as the CLI's")
    func decodesVSCodePayload() throws {
        // Recorded from a live VS Code session rather than a headless run. It
        // carries `effort`, which the CLI capture did not, and the shape is
        // otherwise identical — which is the claim being pinned here, because
        // the whole product targets a VS Code user.
        let event = try Self.single("vscode-pre-tool-use-bash")
        #expect(event.kind == .toolStarted)
        #expect(event.tool?.name == "Bash")
        #expect(event.project.name == "agent-monitor")
        #expect(event.turnId == TurnID("fead9158-4805-4cdd-abc4-4a2b5f2d6da3"))
        #expect(event.toolUseId == ToolUseID("toolu_01KaSnyRVoYyabe84idz39wF"))
    }

    @Test("A finished tool call closes, and so does a failed one")
    func decodesToolCompletion() throws {
        #expect(try Self.single("post-tool-use-bash").kind == .toolFinished)
        let failure = try Self.single("post-tool-use-failure-bash")
        #expect(failure.kind == .toolFinished)
        #expect(failure.toolUseId == ToolUseID("toolu_016a4uxPf3CnU6qGgDFJpJbQ"))
    }

    @Test("A file tool shows its path and never its contents")
    func decodesFileTool() throws {
        let event = try Self.single("pre-tool-use-write")
        let invocation = try #require(event.tool?.invocation)
        #expect(invocation == "…/probe/probe.txt")
        #expect(!invocation.contains("probe\n"))
        #expect(!event.raw.diagnosticSummary.contains("probe.txt"))
    }

    @Test("A subagent is identified, and its own tool calls belong to it")
    func decodesSubagentEvents() throws {
        let start = try Self.single("subagent-start")
        #expect(start.kind == .subagentStarted)
        #expect(start.agent == .subagent(id: AgentID("a116d8cb9b8f407d1"), type: "Explore"))
        #expect(start.sessionId == SessionID("da504299-9fe1-49a3-823f-3111b9db0bc3"))

        #expect(try Self.single("subagent-stop").kind == .subagentStopped)

        let nested = try Self.single("pre-tool-use-bash-subagent")
        #expect(nested.kind == .toolStarted)
        #expect(nested.agent.subagentId == AgentID("a116d8cb9b8f407d1"))
        // A subagent's work still belongs to the session that spawned it.
        #expect(nested.sessionId == SessionID("da504299-9fe1-49a3-823f-3111b9db0bc3"))
    }

    @Test("The end of a turn, an ended session, and a turn that died")
    func decodesTurnBoundaries() throws {
        #expect(try Self.single("stop").kind == .turnFinished)
        #expect(try Self.single("session-end").kind == .sessionEnded)
        let failure = try Self.single("stop-failure")
        #expect(failure.kind == .failed(reason: "Authentication failed"))
    }

    @Test("A permission prompt is the agent waiting on a person")
    func decodesNotification() throws {
        let event = try Self.single("notification-permission-prompt")
        #expect(event.kind == .waitingInput(question: nil))
        #expect(event.raw.diagnosticSummary.contains("permission_prompt"))
    }

    @Test("A tool whose purpose is to ask reads as waiting, not as work")
    func decodesAskingTool() throws {
        let payload = Data(
            """
            {"session_id":"s","cwd":"/Users/dev/projects/probe",
             "hook_event_name":"PreToolUse","tool_name":"AskUserQuestion",
             "tool_input":{"questions":[]},"tool_use_id":"toolu_1"}
            """.utf8)
        let events = try ClaudeCodeEventDecoder().decode(payload, in: Self.context())
        #expect(events.first?.kind == .waitingInput(question: nil))

        // And it is a seam, not a rule: an installation that disagrees turns it
        // back into an ordinary tool call.
        let plain = try ClaudeCodeEventDecoder(waitingTools: []).decode(payload, in: Self.context())
        #expect(plain.first?.kind == .toolStarted)
    }

    /// The question line the `Question` notification and the Waiting row carry
    /// (ADR-0005). It is the one place the adapter reads a tool's arguments for
    /// their content rather than for an identifier, so its bound and its
    /// fallbacks are worth pinning down.
    @Test("A question the agent asked reaches the event as a bounded line")
    func decodesQuestionLine() throws {
        let event = try Self.single("pre-tool-use-ask-user-question")
        #expect(event.kind == .waitingInput(question: Self.recordedQuestion))
        // The same line is on the tool, because one rule produced both.
        #expect(event.tool?.invocation == Self.recordedQuestion)
    }

    static let recordedQuestion = "Which database should the migration target?"

    @Test(
        "The line degrades to the header, then to nothing, and never guesses",
        arguments: [
            (#"{"questions":[{"header":"Database"}]}"#, "Database"),
            (#"{"questions":[{"question":"","header":"Database"}]}"#, "Database"),
            (#"{"questions":[{"options":[]}]}"#, String?.none),
            (#"{"questions":[]}"#, String?.none),
            (#"{"questions":"Database"}"#, String?.none),
            (#"{}"#, String?.none),
        ])
    func degradesQuestionLine(input: String, expected: String?) throws {
        #expect(try Self.question(askingWith: input) == expected)
    }

    @Test("A question longer than the limit is truncated, not carried whole")
    func boundsQuestionLine() throws {
        let long = String(repeating: "why ", count: 200)
        let input = #"{"questions":[{"question":"\#(long)"}]}"#
        let produced = try Self.question(askingWith: input)
        let line = try #require(produced)
        #expect(line.count == ToolInvocation.limit)
        #expect(line.hasSuffix("…"))
    }

    /// Decodes a `PreToolUse(AskUserQuestion)` carrying the given `tool_input`.
    private static func question(askingWith toolInput: String) throws -> String? {
        let payload = Data(
            """
            {"session_id":"s","cwd":"/Users/dev/projects/probe",
             "hook_event_name":"PreToolUse","tool_name":"AskUserQuestion",
             "tool_input":\(toolInput),"tool_use_id":"toolu_1"}
            """.utf8)
        let events = try ClaudeCodeEventDecoder().decode(payload, in: context())
        let event = try #require(events.first)
        guard case .waitingInput(let question) = event.kind else {
            Issue.record("expected a waiting event")
            return nil
        }
        return question
    }

    /// Rejected option 2 in ADR-0005, kept as a test because the payload really
    /// does carry a `message` and every future reader will be tempted by it.
    @Test("A permission prompt's own message never becomes the question line")
    func ignoresNotificationMessage() throws {
        #expect(
            try Self.single("notification-permission-prompt").kind
                == .waitingInput(question: nil))
    }

    @Test("An idle prompt is not treated as waiting for input")
    func ignoresIdlePrompt() throws {
        let payload = Data(
            """
            {"session_id":"s","cwd":"/Users/dev/projects/probe",
             "hook_event_name":"Notification","notification_type":"idle_prompt",
             "message":"Claude is waiting for your input"}
            """.utf8)
        // It fires about a minute after Stop already moved the session to idle,
        // and only if nobody has typed since: it describes the human, not the
        // agent.
        #expect(try ClaudeCodeEventDecoder().decode(payload, in: Self.context()).isEmpty)

        // A notification type from a later release is ignored the same way,
        // rather than guessed at.
        let unknown = Data(
            """
            {"session_id":"s","cwd":"/Users/dev/projects/probe",
             "hook_event_name":"Notification","notification_type":"auth_success"}
            """.utf8)
        #expect(try ClaudeCodeEventDecoder().decode(unknown, in: Self.context()).isEmpty)
    }

    @Test(
        "An event AgentBar does not track decodes to nothing rather than to an error",
        arguments: [
            #"{"session_id":"s","cwd":"/x","hook_event_name":"PreCompact","trigger":"auto"}"#,
            #"{"session_id":"s","cwd":"/x","hook_event_name":"CwdChanged","new_cwd":"/y"}"#,
            #"{"session_id":"s","cwd":"/x","hook_event_name":"SomethingNewIn2027"}"#,
        ]
    )
    func ignoresUntrackedEvents(text: String) throws {
        #expect(try ClaudeCodeEventDecoder().decode(Data(text.utf8), in: Self.context()).isEmpty)
    }

    @Test(
        "A field of the wrong type degrades the event instead of failing it",
        arguments: [
            #"{"session_id":"s","cwd":"/x","hook_event_name":"PreToolUse","tool_name":42}"#,
            #"{"session_id":"s","cwd":"/x","hook_event_name":"PreToolUse","tool_input":"text"}"#,
            #"{"session_id":"s","cwd":"/x","hook_event_name":"PreToolUse","prompt_id":null}"#,
            #"{"session_id":"s","cwd":"/x","hook_event_name":"SubagentStart","agent_id":[1]}"#,
        ]
    )
    func degradesOnUnexpectedTypes(text: String) throws {
        let events = try ClaudeCodeEventDecoder().decode(Data(text.utf8), in: Self.context())
        #expect(events.count == 1)
    }

    @Test(
        "Refuses only a payload that cannot say which session did what",
        arguments: [
            #"{"cwd":"/x","hook_event_name":"Stop"}"#,
            #"{"session_id":"s","hook_event_name":"Stop"}"#,
            #"{"session_id":"s","cwd":"/x"}"#,
            #"{"session_id":"","cwd":"/x","hook_event_name":"Stop"}"#,
            "[]",
            "not json at all",
        ]
    )
    func refusesUnusablePayloads(text: String) {
        #expect(throws: (any Error).self) {
            try ClaudeCodeEventDecoder().decode(Data(text.utf8), in: Self.context())
        }
    }

    @Test(
        "An error type becomes a sentence, including one nobody has seen yet",
        arguments: [
            ("rate_limit", "Rate limit reached"),
            ("max_output_tokens", "The reply hit the output limit"),
            ("unknown", "The turn ended in an error"),
            ("quantum_flux", "Quantum flux"),
        ]
    )
    func rewordsFailures(errorType: String, expected: String) {
        #expect(ClaudeCodeEventDecoder.failureReason(errorType) == expected)
    }

    @Test("A diagnostic line names the event and nothing a person wrote")
    func diagnosticsCarryNoContent() throws {
        let prompt = try Self.single("user-prompt-submit")
        #expect(prompt.raw.diagnosticSummary == "UserPromptSubmit")
        let bash = try Self.single("pre-tool-use-bash")
        #expect(bash.raw.diagnosticSummary == "PreToolUse tool=Bash")
        #expect(!bash.raw.diagnosticSummary.contains("echo"))

        // `error` is a taxonomy value on StopFailure and the failing tool's own
        // message on PostToolUseFailure — which for a failed Edit is a slice of
        // the user's source. Only the taxonomy is repeated.
        #expect(
            try Self.single("stop-failure").raw.diagnosticSummary
                == "StopFailure error=authentication_failed")
        #expect(
            try Self.single("post-tool-use-failure-bash").raw.diagnosticSummary
                == "PostToolUseFailure tool=Bash")
    }
}

@Suite("Tool invocation lines")
struct ToolInvocationTests {

    static func summary(_ tool: String, _ json: String) throws -> String? {
        ToolInvocation.summarise(tool: tool, input: try JSONParser.parse(Data(json.utf8)))
    }

    @Test("Names what the agent is doing, per tool")
    func namesTheWork() throws {
        #expect(try Self.summary("Bash", #"{"command":"swift test"}"#) == "swift test")
        #expect(try Self.summary("Grep", #"{"pattern":"TODO","path":"/x"}"#) == "TODO")
        #expect(try Self.summary("WebSearch", #"{"query":"swift 6"}"#) == "swift 6")
        #expect(
            try Self.summary("Agent", #"{"description":"review the diff"}"#) == "review the diff")
        #expect(try Self.summary("Read", #"{"file_path":"/a/b/c/d.swift"}"#) == "…/c/d.swift")
        #expect(try Self.summary("Read", #"{"file_path":"/d.swift"}"#) == "/d.swift")
    }

    @Test("Drops a URL's query string, where a credential would be")
    func dropsQueryStrings() throws {
        #expect(
            try Self.summary("WebFetch", #"{"url":"https://x.test/a?token=secret"}"#)
                == "https://x.test/a")
    }

    @Test("Never carries file contents")
    func carriesNoContent() throws {
        let summary = try Self.summary(
            "Write", #"{"file_path":"/a/b/c.txt","content":"a secret"}"#)
        #expect(summary == "…/b/c.txt")
    }

    @Test("Stays one bounded line")
    func staysOneLine() throws {
        let long = String(repeating: "x", count: 400)
        let summary = try #require(
            try Self.summary("Bash", "{\"command\":\"echo \\n\\t \(long)\"}"))
        #expect(summary.count == ToolInvocation.limit)
        #expect(!summary.contains("\n"))
        #expect(summary.hasSuffix("…"))
    }

    @Test("Says nothing rather than something useless")
    func staysQuietWhenThereIsNothingToSay() throws {
        #expect(try Self.summary("TodoWrite", #"{"todos":[]}"#) == nil)
        #expect(try Self.summary("mcp__server__thing", #"{"anything":1}"#) == nil)
        #expect(ToolInvocation.summarise(tool: "Bash", input: nil) == nil)
    }
}
