import AgentBarJSON
import Foundation
import Testing

@testable import CodexAdapter

/// The tool line, which is the one place a Codex payload's contents reach the
/// screen.
@Suite("Codex tool lines")
struct ToolInvocationTests {
    static func summarise(_ json: String, tool: String = "shell") throws -> String? {
        CodexToolInvocation.summarise(tool: tool, input: try JSONParser.parse(Data(json.utf8)))
    }

    @Test("The identifying argument is chosen without knowing the tool's name")
    func picksIdentifyingArgument() throws {
        #expect(try Self.summarise(#"{"command":"ls -la"}"#) == "ls -la")
        #expect(
            try Self.summarise(#"{"file_path":"/a/b/c.swift"}"#, tool: "read") == "/a/b/c.swift")
        #expect(
            try Self.summarise(#"{"query":"swift concurrency"}"#, tool: "web")
                == "swift concurrency")
        #expect(try Self.summarise(#"{"pattern":"TODO"}"#, tool: "grep") == "TODO")
    }

    @Test("A URL keeps its path and loses its query")
    func stripsQuery() throws {
        #expect(
            try Self.summarise(#"{"url":"https://example.com/a?token=secret"}"#, tool: "fetch")
                == "https://example.com/a")
    }

    @Test("Nothing recognisable produces no line rather than a guess")
    func degradesToNothing() throws {
        #expect(try Self.summarise(#"{"contents":"a whole file"}"#) == nil)
        #expect(try Self.summarise("[]") == nil)
        #expect(CodexToolInvocation.summarise(tool: "shell", input: nil) == nil)
    }

    @Test("A nested container is not rendered")
    func refusesNestedArguments() throws {
        #expect(try Self.summarise(#"{"command":[{"a":1}]}"#) == nil)
        #expect(try Self.summarise(#"{"command":{"argv":["ls"]}}"#) == nil)
    }

    @Test("A long line is bounded and collapsed to one line")
    func boundsTheLine() throws {
        let long = String(repeating: "x", count: 400)
        let line = try #require(try Self.summarise(#"{"command":"\#(long)"}"#))
        #expect(line.count == CodexToolInvocation.limit)
        #expect(line.hasSuffix("…"))
        #expect(try Self.summarise(#"{"command":"a\nb   c"}"#) == "a b c")
    }

    @Test("Approval copy prefers the human reason, then safe invocation, then tool")
    func approvalSummaryFallbacks() throws {
        #expect(
            CodexToolInvocation.approvalSummary(
                tool: "Bash",
                input: try JSONParser.parse(Data(#"{"description":"Need network"}"#.utf8)))
                == "Need network")
        #expect(
            CodexToolInvocation.approvalSummary(
                tool: "Bash", input: try JSONParser.parse(Data(#"{"command":"git push"}"#.utf8)))
                == "git push")
        #expect(
            CodexToolInvocation.approvalSummary(tool: "custom_tool", input: nil) == "custom_tool")
        #expect(
            CodexToolInvocation.approvalSummary(tool: nil, input: nil) == "Codex requested approval"
        )
    }

    @Test("Approval copy never carries credential-shaped command arguments")
    func approvalSummaryRedactsCredentials() throws {
        let header = try JSONParser.parse(
            Data(
                #"{"command":"curl -H 'Authorization: Bearer top-secret' https://example.com"}"#
                    .utf8))
        let userInfo = try JSONParser.parse(
            Data(#"{"command":"curl https://user:pass@example.com/path?token=secret"}"#.utf8))

        #expect(CodexToolInvocation.approvalSummary(tool: "Bash", input: header) == "Bash")
        #expect(CodexToolInvocation.approvalSummary(tool: "Bash", input: userInfo) == "Bash")
    }

    @Test(
        "Approval copy drops bare credential prefixes from commands and descriptions",
        arguments: [
            "sk-proj-123",  // tos-allow: synthetic prefix proves lock-screen redaction
            "sk-ant-123",  // tos-allow: synthetic prefix proves lock-screen redaction
            "ghp_123", "xoxb-123", "AKIA123",
        ]
    )
    func approvalSummaryDropsCredentialPrefixes(secret: String) throws {
        let command = try JSONParser.parse(
            Data(#"{"command":"echo \#(secret)"}"#.utf8))
        let description = try JSONParser.parse(
            Data(#"{"description":"Use \#(secret)"}"#.utf8))

        #expect(CodexToolInvocation.approvalSummary(tool: "Bash", input: command) == "Bash")
        #expect(CodexToolInvocation.approvalSummary(tool: "Bash", input: description) == "Bash")
    }

    @Test("Approval paths show only the final component")
    func approvalSummaryShortensPaths() throws {
        let input = try JSONParser.parse(
            Data(#"{"file_path":"/Users/alice/private/secrets.txt"}"#.utf8))
        #expect(
            CodexToolInvocation.approvalSummary(tool: "Read", input: input) == "secrets.txt")
    }
}
