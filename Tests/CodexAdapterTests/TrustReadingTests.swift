import Foundation
import Testing

@testable import CodexAdapter

/// Reading `config.toml`: the file AgentBar must never write and cannot do
/// without.
@Suite("Codex config.toml reading")
struct TrustReadingTests {
    /// The shape observed on the developer's machine on 2026-08-19, reduced to
    /// the tables AgentBar reads. Three trust records written by Codex itself,
    /// and three hooks the user configured before AgentBar existed.
    static let realShape = """
        notify = ["/Users/dev/.codex/computer-use/Client.app/Contents/MacOS/Client", "turn-ended"]

        [history]
        persistence = "save-all"

        # =============================================================
        # Lifecycle hooks
        # =============================================================

        [[hooks.UserPromptSubmit]]

        [[hooks.UserPromptSubmit.hooks]]
        type = "command"
        command = '"$HOME"/.codex/hooks/caffeine.sh start'
        timeout = 3

        [[hooks.Stop]]

        [[hooks.Stop.hooks]]
        type = "command"
        command = '"$HOME"/.codex/hooks/caffeine.sh stop'
        timeout = 3

        [[hooks.SessionEnd]]

        [[hooks.SessionEnd.hooks]]
        type = "command"
        command = '"$HOME"/.codex/hooks/caffeine.sh cleanup-session'
        timeout = 3

        [hooks.state]

        [hooks.state."/Users/dev/.codex/config.toml:session_end:0:0"]
        trusted_hash = "sha256:1b55368ea935052886968f1726a62ea1ebc7d1d41dd8aa0274dce5fcaf4a8501"

        [hooks.state."/Users/dev/.codex/config.toml:user_prompt_submit:0:0"]
        trusted_hash = "sha256:85fedc8a074644bc39f20957c4f46313070b93243e45448e1b5f0f108acd9798"

        [hooks.state."/Users/dev/.codex/config.toml:stop:0:0"]
        trusted_hash = "sha256:856bfcd8fe3983973fe9d186661914fe7cc4723e78b82e0619bcb793ae75341f"
        """

    @Test("A real configuration's trust records are read by their whole key")
    func readsTrustRecords() {
        let reading = CodexConfigFile.parse(Self.realShape)
        #expect(reading.isPresent)
        #expect(reading.isReadable)
        #expect(reading.trust.count == 3)
        let record = reading.trust["/Users/dev/.codex/config.toml:stop:0:0"]
        #expect(record?.trustedHash?.hasPrefix("sha256:") == true)
        // Absent means enabled: Codex writes the flag only to turn one off.
        #expect(record?.enabled == true)
        #expect(record?.permitsExecution == true)
    }

    @Test("The user's own hooks are found where they actually live")
    func readsForeignHooks() {
        let reading = CodexConfigFile.parse(Self.realShape)
        #expect(reading.hooks.count == 3)
        #expect(reading.hooks.allSatisfy { $0.family == .caffeine })
        #expect(reading.hooks.allSatisfy { $0.source == .configToml })
        #expect(reading.hooks.map(\.event).sorted() == ["SessionEnd", "Stop", "UserPromptSubmit"])
        #expect(reading.hooks.contains { $0.summary.contains("caffeine.sh start") })
    }

    @Test("A disabled entry is trusted and still will not run")
    func readsDisabledFlag() {
        let reading = CodexConfigFile.parse(
            """
            [hooks.state."/h.json:stop:0:0"]
            enabled = false
            trusted_hash = "sha256:abc"
            """)
        let record = reading.trust["/h.json:stop:0:0"]
        #expect(record?.enabled == false)
        #expect(record?.permitsExecution == false)
    }

    @Test("Nothing outside the two tables AgentBar reads leaves the reader")
    func readsNothingElse() {
        // `config.toml` can hold a provider's credentials. The reader takes two
        // tables and the rest is parsed into oblivion — a value that never
        // becomes a value cannot be logged by accident.
        let reading = CodexConfigFile.parse(
            """
            [model_providers.example]
            api_key = "sk-do-not-read-me"
            env_key = "EXAMPLE_KEY"

            [hooks.state."/h.json:stop:0:0"]
            trusted_hash = "sha256:abc"
            """)
        #expect(reading.trust.count == 1)
        #expect(reading.hooks.isEmpty)
        #expect(!"\(reading)".contains("sk-do-not-read-me"))
    }

    @Test("A comment is not a value, and a `#` inside a string is not a comment")
    func handlesComments() {
        let reading = CodexConfigFile.parse(
            """
            # [hooks.state."/commented-out:stop:0:0"]
            [[hooks.Stop]]
            matcher = "shell # not a comment"

            [[hooks.Stop.hooks]]
            command = "say done"  # trailing
            """)
        #expect(reading.trust.isEmpty)
        #expect(reading.hooks.first?.matcher == "shell # not a comment")
        #expect(reading.hooks.first?.summary == "say done")
    }

    @Test("A multi-line string cannot smuggle a table header into the reading")
    func skipsMultilineStrings() {
        let reading = CodexConfigFile.parse(
            """
            [notes]
            text = \"\"\"
            [hooks.state."/forged:stop:0:0"]
            trusted_hash = "sha256:forged"
            \"\"\"

            [hooks.state."/real:stop:0:0"]
            trusted_hash = "sha256:real"
            """)
        #expect(reading.trust.count == 1)
        #expect(reading.trust["/real:stop:0:0"]?.trustedHash == "sha256:real")
    }

    @Test("A header this reader cannot parse orphans its keys rather than misplacing them")
    func refusesToGuessAtBrokenSyntax() {
        let reading = CodexConfigFile.parse(
            """
            [hooks.state."/real:stop:0:0"
            trusted_hash = "sha256:not-a-record"
            """)
        #expect(reading.trust.isEmpty)
    }

    @Test("AgentBar's own entries in config.toml are not reported as foreign")
    func skipsItsOwnCommands() {
        let reading = CodexConfigFile.parse(
            """
            [[hooks.Stop]]

            [[hooks.Stop.hooks]]
            command = "'/Applications/AgentBar.app/Contents/MacOS/agentbar-helper'"
            """)
        #expect(reading.hooks.isEmpty)
    }

    @Test("An absent file is not an unreadable one")
    func distinguishesAbsentFromUnreadable() throws {
        let home = try ScratchCodexHome()
        let absent = CodexConfigFile.read(at: home.configURL)
        #expect(!absent.isPresent)
        #expect(absent.isReadable)

        try Data([0xFF, 0xFE, 0xFF]).write(to: home.configURL)
        let unreadable = CodexConfigFile.read(at: home.configURL)
        #expect(unreadable.isPresent)
        #expect(!unreadable.isReadable)
    }

    @Test("An event's trust key is spelled the way Codex spells it")
    func eventNamesAreSnakeCase() {
        #expect(CodexHookEvent.sessionEnd.trustStateName == "session_end")
        #expect(CodexHookEvent.userPromptSubmit.trustStateName == "user_prompt_submit")
        #expect(CodexHookEvent.stop.trustStateName == "stop")
        #expect(CodexHookEvent.preToolUse.trustStateName == "pre_tool_use")
    }
}
