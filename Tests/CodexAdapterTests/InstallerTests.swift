import AgentBarCore
import AgentBarJSON
import Foundation
import Testing

@testable import CodexAdapter

/// The installer against a real directory: what it writes, what it refuses to
/// write, and what it leaves exactly as it found it.
@Suite("Codex installer")
struct InstallerTests {
    static func endpoint(_ home: ScratchCodexHome) throws -> CodexEndpoint {
        CodexEndpoint(helperURL: try home.makeHelper())
    }

    /// A `config.toml` whose trust records name every entry AgentBar installs.
    static func trustedConfig(
        for home: ScratchCodexHome, enabled: Bool = true,
        hash: String = "sha256:whatever-codex-computed"
    ) -> String {
        let path = home.hooksURL.path(percentEncoded: false)
        return CodexHookHandler.monitoring.map { handler in
            """
            [hooks.state."\(path):\(handler.event.trustStateName):0:0"]
            trusted_hash = "\(hash)"
            enabled = \(enabled)
            """
        }.joined(separator: "\n\n")
    }

    @Test("A first install writes every handler and asks for trust")
    func installsFromNothing() throws {
        let home = try ScratchCodexHome()
        let installer = CodexInstaller(home: home.directory)
        let outcome = try installer.install(try Self.endpoint(home))
        #expect(outcome.changed)
        #expect(outcome.backupURL == nil)
        #expect(outcome.requiresTrust)

        let hooks = CodexHooksFile.installedHooks(in: try JSONParser.parse(home.hooksData))
        #expect(hooks.count == CodexHookHandler.monitoring.count)
        // No secret is written here, unlike the Claude Code settings file: the
        // helper reads the token when it runs.
        #expect(!(home.hooksText ?? "").contains("Authorization"))
        #expect(!(home.hooksText ?? "").contains("Bearer"))
    }

    @Test("A second install changes nothing and takes no backup")
    func installIsIdempotentOnDisk() throws {
        let home = try ScratchCodexHome()
        let installer = CodexInstaller(home: home.directory)
        let endpoint = try Self.endpoint(home)
        try installer.install(endpoint)
        let first = home.hooksData
        let outcome = try installer.install(endpoint)
        #expect(!outcome.changed)
        #expect(outcome.backupURL == nil)
        #expect(home.hooksData == first)
        #expect(home.backups().isEmpty)
    }

    @Test("Installing over a file the user owns backs it up first and keeps their entries")
    func backsUpBeforeWriting() throws {
        let original = """
            {
              "description": "mine",
              "hooks": {
                "Stop": [
                  { "hooks": [ { "type": "command", "command": "say done" } ] }
                ]
              }
            }
            """
        let home = try ScratchCodexHome(hooks: original)
        let installer = CodexInstaller(home: home.directory)
        let outcome = try installer.install(try Self.endpoint(home))
        #expect(outcome.changed)
        let backup = try #require(outcome.backupURL)
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        #expect((home.hooksText ?? "").contains("say done"))
        #expect((home.hooksText ?? "").contains("\"description\": \"mine\""))
    }

    /// Written the way `JSONWriter` renders — two-space indent, one value a line.
    ///
    /// The byte-for-byte claim is about *content*, not about layout: a file
    /// already in this shape comes back identical, and one written in some other
    /// style is reformatted the first time AgentBar writes to it at all. That is
    /// the same trade the Claude Code installer makes, and it is why the
    /// installer never writes when nothing would change.
    @Test("Uninstalling restores the file byte for byte")
    func uninstallRestoresTheFile() throws {
        let original = """
            {
              "hooks": {
                "Stop": [
                  {
                    "hooks": [
                      {
                        "type": "command",
                        "command": "say done"
                      }
                    ]
                  }
                ]
              }
            }

            """
        let home = try ScratchCodexHome(hooks: original)
        let installer = CodexInstaller(home: home.directory)
        try installer.install(try Self.endpoint(home))
        let outcome = try installer.uninstall()
        #expect(outcome.changed)
        #expect(home.hooksText == original)
    }

    @Test("A file AgentBar created and has now emptied goes with the hooks")
    func uninstallRemovesAFileItCreated() throws {
        let home = try ScratchCodexHome()
        let installer = CodexInstaller(home: home.directory)
        try installer.install(try Self.endpoint(home))
        #expect(home.hooksExist)
        let outcome = try installer.uninstall()
        #expect(outcome.changed)
        #expect(!home.hooksExist)
        // The copy of what was there is still there.
        #expect(home.backups().count == 1)
    }

    @Test("An empty file the user left behind is not AgentBar's to delete")
    func uninstallLeavesAForeignEmptyFile() throws {
        let home = try ScratchCodexHome(hooks: "{}")
        let outcome = try CodexInstaller(home: home.directory).uninstall()
        #expect(!outcome.changed)
        #expect(home.hooksExist)
    }

    @Test("A file that cannot be parsed is never written over")
    func refusesToWriteOverUnreadableFile() throws {
        let home = try ScratchCodexHome(hooks: "{not json")
        let installer = CodexInstaller(home: home.directory)
        #expect(throws: CodexInstallerError.self) {
            try installer.install(try Self.endpoint(home))
        }
        #expect(home.hooksText == "{not json")
        let report = installer.report(for: try Self.endpoint(home))
        guard case .hooksUnreadable = report.state else {
            Issue.record("expected hooksUnreadable, got \(report.state)")
            return
        }
        #expect(!report.isInstalled)
    }

    @Test("A hooks key of the wrong shape is refused rather than replaced")
    func refusesUnexpectedShape() throws {
        let home = try ScratchCodexHome(hooks: #"{"hooks": []}"#)
        #expect(throws: CodexInstallerError.self) {
            try CodexInstaller(home: home.directory).install(try Self.endpoint(home))
        }
    }

    @Test("A missing Codex directory is a refusal, not a directory AgentBar creates")
    func refusesToCreateTheCodexDirectory() throws {
        let home = try ScratchCodexHome()
        let missing = home.directory.appending(path: "not-there", directoryHint: .isDirectory)
        #expect(throws: CodexInstallerError.self) {
            try CodexInstaller(home: missing).install(try Self.endpoint(home))
        }
    }
}
