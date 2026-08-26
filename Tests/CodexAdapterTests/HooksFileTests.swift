import AgentBarJSON
import Foundation
import Testing

@testable import CodexAdapter

/// The merge rules, as pure functions of a parsed document.
@Suite("Codex hooks.json merge")
struct HooksFileTests {
    static let helper = URL(filePath: "/Applications/AgentBar.app/Contents/MacOS/agentbar-helper")
    static var endpoint: CodexEndpoint { CodexEndpoint(helperURL: helper) }

    static func parse(_ json: String) throws -> JSONValue {
        try JSONParser.parse(Data(json.utf8))
    }

    static let foreign = """
        {
          "description": "my hooks",
          "hooks": {
            "Stop": [
              {
                "matcher": "*",
                "hooks": [
                  { "type": "command", "command": "'$HOME'/.codex/hooks/notify.sh", "timeout": 5 }
                ]
              }
            ]
          }
        }
        """

    @Test("An empty document gains one group per installed event")
    func installsEveryHandler() throws {
        let installed = CodexHooksFile.installed(try Self.parse("{}"), endpoint: Self.endpoint)
        let hooks = try #require(installed.object?["hooks"]?.object)
        #expect(hooks.keys.count == CodexHookHandler.monitoring.count)
        for handler in CodexHookHandler.monitoring {
            let groups = try #require(hooks[handler.event.rawValue]?.array)
            #expect(groups.count == 1)
            let entry = try #require(groups[0].object?["hooks"]?.array?.first?.object)
            #expect(entry["type"]?.string == "command")
            #expect(entry["command"]?.string == Self.endpoint.command)
            #expect(entry["timeout"]?.integer == handler.timeout)
            // Neither field is written, and both absences are deliberate: a
            // status message would announce the monitor on every tool call, and
            // an async hook would let `Stop` and `SessionEnd` arrive out of order.
            #expect(entry["statusMessage"] == nil)
            #expect(entry["async"] == nil)
            #expect(groups[0].object?["matcher"] == nil)
        }
        #expect(hooks[CodexHookEvent.permissionRequest.rawValue] != nil)
    }

    @Test("`SessionEnd` carries the platform's own one-second cap")
    func sessionEndTimeoutIsSmallest() throws {
        let timeouts = Dictionary(
            uniqueKeysWithValues: CodexHookHandler.monitoring.map { ($0.event, $0.timeout) })
        #expect(timeouts[.sessionEnd] == 1)
        #expect(timeouts[.preToolUse] == 2)
        // Codex's own default is 600 seconds, and inheriting it is the failure
        // this table exists to prevent.
        #expect(CodexHookHandler.monitoring.allSatisfy { $0.timeout <= 2 })
    }

    @Test("Installing twice produces the same document")
    func installIsIdempotent() throws {
        let once = CodexHooksFile.installed(try Self.parse(Self.foreign), endpoint: Self.endpoint)
        let twice = CodexHooksFile.installed(once, endpoint: Self.endpoint)
        #expect(once == twice)
    }

    @Test("A foreign entry survives install and uninstall untouched")
    func leavesForeignEntriesAlone() throws {
        let original = try Self.parse(Self.foreign)
        let installed = CodexHooksFile.installed(original, endpoint: Self.endpoint)
        let removed = CodexHooksFile.uninstalled(installed)
        #expect(removed == original)
        #expect(JSONWriter.data(removed) == JSONWriter.data(original))
    }

    @Test("An event AgentBar emptied goes with it; one the user emptied does not")
    func removesOnlyItsOwnContainers() throws {
        let document = try Self.parse(
            """
            {"hooks":{"PreCompact":[],"Stop":[{"hooks":[
              {"type":"command","command":"'/opt/agentbar-helper'"}
            ]}]}}
            """)
        let removed = CodexHooksFile.uninstalled(document)
        let hooks = try #require(removed.object?["hooks"]?.object)
        #expect(hooks["Stop"] == nil)
        #expect(hooks["PreCompact"]?.array?.isEmpty == true)
    }

    @Test("A group holding one of ours beside a foreign handler keeps the foreign one")
    func keepsForeignHandlerInSharedGroup() throws {
        let document = try Self.parse(
            """
            {"hooks":{"Stop":[{"matcher":"x","hooks":[
              {"type":"command","command":"'/opt/agentbar-helper'"},
              {"type":"command","command":"say done"}
            ]}]}}
            """)
        let removed = CodexHooksFile.uninstalled(document)
        let handlers = try #require(
            removed.object?["hooks"]?.object?["Stop"]?.array?.first?.object?["hooks"]?.array)
        #expect(handlers.count == 1)
        #expect(handlers[0].object?["command"]?.string == "say done")
    }

    @Test("Recognition reads a path, not a substring")
    func recognisesOnlyItsOwnCommand() {
        #expect(
            CodexHookCommand.isAgentBarCommand(
                "'/Applications/AgentBar.app/Contents/MacOS/agentbar-helper'"))
        #expect(CodexHookCommand.isAgentBarCommand("/opt/agentbar-helper"))
        // A longer command line that merely mentions the helper is somebody
        // else's line, and an uninstall that deleted it would be deleting
        // somebody else's configuration.
        #expect(!CodexHookCommand.isAgentBarCommand("/opt/agentbar-helper --verbose"))
        #expect(!CodexHookCommand.isAgentBarCommand("echo agentbar-helper"))
        #expect(!CodexHookCommand.isAgentBarCommand("/opt/agentbar-helper-wrapper"))
        #expect(!CodexHookCommand.isAgentBarCommand(""))
        // Quoted, ends in the right file name, and still somebody else's line:
        // treating it as ours would delete it on uninstall.
        #expect(!CodexHookCommand.isAgentBarCommand("'echo hi; /opt/agentbar-helper'"))
        #expect(!CodexHookCommand.isAgentBarCommand("'$(id) /opt/agentbar-helper'"))
        #expect(!CodexHookCommand.isAgentBarCommand("'relative/agentbar-helper'"))
        // A path with a space in it is still a path, which is why the command is
        // quoted in the first place.
        #expect(CodexHookCommand.isAgentBarCommand("'/Users/dev/My Apps/agentbar-helper'"))
    }

    @Test("A path with a quote in it survives the round trip")
    func quotesPathsForTheShell() {
        let awkward = URL(
            filePath: "/Users/dev/It's Apps/AgentBar.app/Contents/MacOS/agentbar-helper")
        let command = CodexHookCommand.command(forHelperAt: awkward)
        #expect(
            command == #"'/Users/dev/It'\''s Apps/AgentBar.app/Contents/MacOS/agentbar-helper'"#)
        #expect(
            CodexHookCommand.helperPath(in: command) == awkward.path(percentEncoded: false))
    }

    @Test("Every installed entry can name the trust record Codex would write for it")
    func buildsTrustKeys() throws {
        let installed = CodexHooksFile.installed(try Self.parse("{}"), endpoint: Self.endpoint)
        let source = URL(filePath: "/Users/dev/.codex/hooks.json")
        let hooks = CodexHooksFile.installedHooks(in: installed)
        #expect(hooks.count == CodexHookHandler.monitoring.count)
        let keys = hooks.compactMap { $0.trustKey(source: source) }
        #expect(keys.count == hooks.count)
        #expect(keys.contains("/Users/dev/.codex/hooks.json:session_end:0:0"))
        #expect(keys.contains("/Users/dev/.codex/hooks.json:user_prompt_submit:0:0"))
        #expect(keys.contains("/Users/dev/.codex/hooks.json:pre_tool_use:0:0"))
    }

    @Test("A second group on the same event is indexed as the second group")
    func indexesGroupsInFileOrder() throws {
        let document = try Self.parse(
            """
            {"hooks":{"Stop":[
              {"hooks":[{"type":"command","command":"say one"}]},
              {"hooks":[{"type":"command","command":"say two"},
                        {"type":"command","command":"'/opt/agentbar-helper'"}]}
            ]}}
            """)
        let ours = try #require(CodexHooksFile.installedHooks(in: document).first)
        #expect(ours.groupIndex == 1)
        #expect(ours.hookIndex == 1)
    }

    @Test("A foreign hook is reported with the family it belongs to")
    func reportsForeignFamilies() throws {
        let document = try Self.parse(
            """
            {"hooks":{"Stop":[{"hooks":[
              {"type":"command","command":"'$HOME'/.codex/hooks/caffeine.sh stop"},
              {"type":"command","command":"node claude-notifier-on-stop.js"},
              {"type":"command","command":"say done"}
            ]}]}}
            """)
        let overlaps = CodexHooksFile.foreignHooks(in: document)
        #expect(overlaps.count == 3)
        #expect(overlaps.map(\.family) == [.caffeine, .notifier, .other])
        #expect(overlaps.allSatisfy { $0.source == .hooksFile })
    }

    @Test("A vacant document is one AgentBar emptied, not one the user wrote into")
    func recognisesVacancy() throws {
        #expect(CodexHooksFile.isVacant(try Self.parse("{}")))
        #expect(CodexHooksFile.isVacant(try Self.parse(#"{"hooks":{}}"#)))
        #expect(!CodexHooksFile.isVacant(try Self.parse(#"{"description":"mine"}"#)))
        #expect(!CodexHooksFile.isVacant(try Self.parse(#"{"hooks":{"Stop":[]}}"#)))
    }
}
