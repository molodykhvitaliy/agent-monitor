import AgentBarCore
import AgentBarIngest
import AgentBarJSON
import Foundation
import Testing

@testable import ClaudeCodeAdapter

@Suite("Installing into a settings file")
struct InstallerTests {

    @Test("Installs every handler the plan describes, and nothing else")
    func installsThePlan() throws {
        let scratch = try ScratchSettings(contents: Data("{}\n".utf8))
        try scratch.installer().install(try .test())

        let root = try JSONParser.parse(scratch.data)
        let installed = ClaudeCodeSettings.installedHandlers(in: root)
        #expect(
            Set(installed.map(\.event))
                == Set(ClaudeCodeHookHandler.monitoring.map(\.event.rawValue)))
        #expect(installed.allSatisfy { $0.url == "http://127.0.0.1:47821/v1/hooks/claude-code" })
        #expect(installed.allSatisfy { $0.authorization == "Bearer test-token" })
        // Never the 600-second default, and SessionEnd smaller still so the
        // shared 1.5-second budget is not raised.
        #expect(installed.allSatisfy { ($0.timeout ?? 600) <= 2 })
        #expect(installed.first { $0.event == "SessionEnd" }?.timeout == 1)
        // SessionStart takes no http handler, so there must not be one.
        #expect(!installed.contains { $0.event == "SessionStart" })
        #expect(!installed.contains { $0.event == "WorktreeCreate" })
        // No allow-list where there was none: an absent key permits every http
        // hook, and defining one switches allow-listing on at every settings
        // level — including for hooks in a project's settings we cannot see.
        #expect(ClaudeCodeSettings.allowedURLs(in: root) == nil)
    }

    @Test("A second install changes nothing and takes no backup")
    func isIdempotent() throws {
        let scratch = try ScratchSettings(
            contents: try Fixtures.data("settings-with-foreign-hooks"))
        let endpoint = try ClaudeCodeEndpoint.test()

        let first = try scratch.installer().install(endpoint)
        #expect(first.changed)
        let afterFirst = scratch.data

        let second = try scratch.installer().install(endpoint)
        #expect(!second.changed)
        #expect(second.backupURL == nil)
        #expect(scratch.data == afterFirst)
        #expect(scratch.backups.count == 1)
        #expect(scratch.strayFiles.isEmpty)
    }

    @Test("Uninstall returns the file to exactly what it was")
    func uninstallRestoresTheOriginal() throws {
        let original = try Fixtures.data("settings-with-foreign-hooks")
        let scratch = try ScratchSettings(contents: original)

        try scratch.installer().install(try .test())
        #expect(scratch.data != original)
        let outcome = try scratch.installer().uninstall()

        #expect(outcome.changed)
        #expect(scratch.data == original)
    }

    @Test("Foreign hooks survive install and uninstall untouched")
    func foreignHooksSurvive() throws {
        let original = try Fixtures.data("settings-with-foreign-hooks")
        let scratch = try ScratchSettings(contents: original)
        try scratch.installer().install(try .test())

        let root = try JSONParser.parse(scratch.data)
        let originalRoot = try JSONParser.parse(original)
        // Every foreign key, byte for byte.
        for key in ["permissions", "statusLine", "theme"] {
            #expect(root.object?[key] == originalRoot.object?[key])
        }
        // Every foreign hook group, byte for byte, still first in its event.
        let hooks = try #require(root.object?["hooks"]?.object)
        let originalHooks = try #require(originalRoot.object?["hooks"]?.object)
        for event in originalHooks.keys {
            let groups = try #require(hooks[event]?.array)
            let originalGroups = try #require(originalHooks[event]?.array)
            #expect(Array(groups.prefix(originalGroups.count)) == originalGroups)
        }
        // Including the one event AgentBar does not install on at all.
        #expect(hooks["PermissionRequest"] == originalHooks["PermissionRequest"])
    }

    @Test("The user's existing notifier and caffeine hooks are reported, never changed")
    func reportsOverlap() throws {
        let scratch = try ScratchSettings(
            contents: try Fixtures.data("settings-with-foreign-hooks"))
        let outcome = try scratch.installer().install(try .test())

        let families = Dictionary(grouping: outcome.overlaps, by: \.family)
        #expect(families[.notifier]?.count == 5)
        #expect(families[.caffeine]?.count == 3)
        #expect(outcome.overlaps.contains { $0.event == "Stop" && $0.family == .notifier })
        #expect(
            outcome.overlaps.contains {
                $0.event == "PreToolUse" && $0.matcher == "AskUserQuestion"
            })
        // Reported from an event AgentBar installs nothing on, because the
        // duplicate notification is just as confusing there.
        #expect(outcome.overlaps.contains { $0.event == "PermissionRequest" })
    }

    @Test("A foreign http hook that ran before still runs afterwards")
    func leavesForeignHTTPHooksRunning() throws {
        let existing = Data(
            """
            {
              "hooks": {
                "Stop": [
                  {
                    "hooks": [
                      { "type": "http", "url": "https://example.test/hook", "timeout": 5 }
                    ]
                  }
                ]
              }
            }

            """.utf8)
        let scratch = try ScratchSettings(contents: existing)
        let outcome = try scratch.installer().install(try .test())

        // The trap this avoids: creating allowedHttpHookUrls switches on
        // allow-listing at every settings level at once, so a foreign http hook
        // — here, or in a project's settings we cannot even see — stops running
        // unless it is on the list. Not creating the key leaves every one of
        // them exactly as it was.
        #expect(ClaudeCodeSettings.allowedURLs(in: try JSONParser.parse(scratch.data)) == nil)
        #expect(!outcome.warnings.contains(.allowListInEffect))
    }

    @Test("An allow-list defined in settings.local.json is joined, not ignored")
    func joinsAnAllowlistFromTheSiblingFile() throws {
        let scratch = try ScratchSettings(contents: Data("{}\n".utf8))
        try Data(#"{"allowedHttpHookUrls":["https://example.test/hook"]}"#.utf8)
            .write(to: scratch.directory.appending(path: "settings.local.json"))

        let outcome = try scratch.installer().install(try .test())

        // Allow-lists merge across settings levels, so one next door governs the
        // handlers written here — and an entry written here counts towards it.
        // Missing that is "installed, and nothing ever arrives".
        #expect(
            ClaudeCodeSettings.allowedURLs(in: try JSONParser.parse(scratch.data))
                == ["http://127.0.0.1:47821/v1/hooks/claude-code"])
        #expect(outcome.warnings.contains(.allowListInEffect))
    }

    @Test("An allowlist the user already keeps is added to, not replaced")
    func extendsAnExistingAllowlist() throws {
        let existing = Data(#"{"allowedHttpHookUrls":["https://example.test/hook"]}"#.utf8)
        let scratch = try ScratchSettings(contents: existing)
        let outcome = try scratch.installer().install(try .test())

        let allowed = try #require(
            ClaudeCodeSettings.allowedURLs(in: JSONParser.parse(scratch.data)))
        #expect(
            allowed == ["https://example.test/hook", "http://127.0.0.1:47821/v1/hooks/claude-code"])
        #expect(outcome.warnings.contains(.allowListInEffect))

        try scratch.installer().uninstall()
        // The key stays, because the user defined it. Switching allow-listing
        // off on the way out is the same unasked-for policy change as switching
        // it on.
        let after = try #require(ClaudeCodeSettings.allowedURLs(in: JSONParser.parse(scratch.data)))
        #expect(after == ["https://example.test/hook"])
    }

    @Test("Uninstalling from an empty file leaves an empty file")
    func leavesNothingBehind() throws {
        let scratch = try ScratchSettings(contents: Data("{}\n".utf8))
        try scratch.installer().install(try .test())
        try scratch.installer().uninstall()
        #expect(scratch.text == "{}\n")
    }

    @Test("An empty container the user wrote is not tidied away")
    func leavesUserWrittenEmptyContainersAlone() throws {
        let original = Data(
            """
            {
              "hooks": {
                "PreCompact": []
              }
            }

            """.utf8)
        let scratch = try ScratchSettings(contents: original)
        try scratch.installer().install(try .test())
        try scratch.installer().uninstall()
        #expect(scratch.data == original)
    }

    @Test(
        "A settings file whose shape would be overwritten rather than merged is refused",
        arguments: [
            #"{"hooks": ["not an object"]}"#,
            #"{"hooks": "off"}"#,
            #"{"allowedHttpHookUrls": {"a": 1}}"#,
            #"{"allowedHttpHookUrls": ["ok", 5]}"#,
        ]
    )
    func refusesAnUnexpectedShape(text: String) throws {
        let scratch = try ScratchSettings(contents: Data((text + "\n").utf8))
        #expect(throws: ClaudeCodeInstallerError.self) {
            try scratch.installer().install(try .test())
        }
        #expect(scratch.text == text + "\n")
    }

    @Test("A moved port is repaired in place, leaving one handler per event")
    func repairsAMovedEndpoint() throws {
        let scratch = try ScratchSettings(contents: Data("{}\n".utf8))
        try scratch.installer().install(try .test(port: 47821))
        try scratch.installer().install(try .test(port: 47825, token: "new-token"))

        let installed = ClaudeCodeSettings.installedHandlers(in: try JSONParser.parse(scratch.data))
        #expect(installed.count == ClaudeCodeHookHandler.monitoring.count)
        #expect(installed.allSatisfy { $0.url.contains(":47825/") })
        #expect(installed.allSatisfy { $0.authorization == "Bearer new-token" })
    }
}
