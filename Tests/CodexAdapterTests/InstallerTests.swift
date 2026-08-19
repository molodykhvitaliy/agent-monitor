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
    static func trustedConfig(for home: ScratchCodexHome, enabled: Bool = true) -> String {
        let path = home.hooksURL.path(percentEncoded: false)
        return CodexHookHandler.monitoring.map { handler in
            """
            [hooks.state."\(path):\(handler.event.trustStateName):0:0"]
            trusted_hash = "sha256:whatever-codex-computed"
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

/// What the installer says about a configuration it did not just write.
///
/// Split from the writing half because the two ask different questions: one is
/// about a file changing on disk, the other about the sentence a user reads on
/// the card — and Codex's trust model means there are five answers where the
/// Claude Code side has three.
@Suite("Codex install reports")
struct InstallReportTests {
    static func endpoint(_ home: ScratchCodexHome) throws -> CodexEndpoint {
        try InstallerTests.endpoint(home)
    }

    static func trustedConfig(for home: ScratchCodexHome, enabled: Bool = true) -> String {
        InstallerTests.trustedConfig(for: home, enabled: enabled)
    }

    @Test("Nothing installed reads as not connected")
    func reportsNotInstalled() throws {
        let home = try ScratchCodexHome()
        let report = CodexInstaller(home: home.directory).report(for: try Self.endpoint(home))
        #expect(report.state == .notInstalled)
        #expect(!report.isInstalled)
    }

    @Test("Installed and untrusted is the state the onboarding card exists for")
    func reportsInstalledNotTrusted() throws {
        let home = try ScratchCodexHome()
        let installer = CodexInstaller(home: home.directory)
        try installer.install(try Self.endpoint(home))
        let report = installer.report(for: try Self.endpoint(home))
        #expect(report.state == .installedNotTrusted(.notTrusted))
        #expect(report.isInstalled)
    }

    @Test("Trust records for every entry make it connected")
    func reportsTrusted() throws {
        let home = try ScratchCodexHome()
        let installer = CodexInstaller(home: home.directory)
        try installer.install(try Self.endpoint(home))
        try Data(Self.trustedConfig(for: home).utf8).write(to: home.configURL)
        #expect(installer.report(for: try Self.endpoint(home)).state == .installed)
    }

    @Test("An entry switched off in Codex is its own state, not `not trusted`")
    func reportsDisabled() throws {
        let home = try ScratchCodexHome()
        let installer = CodexInstaller(home: home.directory)
        try installer.install(try Self.endpoint(home))
        try Data(Self.trustedConfig(for: home, enabled: false).utf8).write(to: home.configURL)
        #expect(installer.report(for: try Self.endpoint(home)).state == .disabledInCodex)
    }

    @Test("A delivered event outranks a trust table that says nothing")
    func deliveryProvesTrust() throws {
        let home = try ScratchCodexHome()
        let installer = CodexInstaller(home: home.directory)
        try installer.install(try Self.endpoint(home))
        let endpoint = try Self.endpoint(home)
        #expect(installer.report(for: endpoint).state == .installedNotTrusted(.notTrusted))
        // An event cannot arrive from a hook that did not run, so this direction
        // is proof where the table is only evidence.
        #expect(installer.report(for: endpoint, hasDelivered: true).state == .installed)
    }

    @Test("An unreadable config.toml is reported as unconfirmed, never as trusted")
    func unreadableConfigIsPessimistic() throws {
        let home = try ScratchCodexHome()
        let installer = CodexInstaller(home: home.directory)
        try installer.install(try Self.endpoint(home))
        try Data([0xFF, 0xFE, 0xFF]).write(to: home.configURL)
        let report = installer.report(for: try Self.endpoint(home))
        #expect(report.state == .installedNotTrusted(.unknown))
        #expect(report.warnings.contains(.trustStateUnavailable))
    }

    @Test("Installed with no endpoint bound is `not receiving`")
    func reportsEndpointUnavailable() throws {
        let home = try ScratchCodexHome()
        let installer = CodexInstaller(home: home.directory)
        try installer.install(try Self.endpoint(home))
        #expect(installer.report(for: nil).state == .endpointUnavailable)
    }

    @Test("A moved app is one drift, not eight")
    func reportsMovedHelperOnce() throws {
        let home = try ScratchCodexHome()
        let installer = CodexInstaller(home: home.directory)
        try installer.install(try Self.endpoint(home))
        let moved = CodexEndpoint(
            helperURL: URL(filePath: "/Applications/AgentBar.app/Contents/MacOS/agentbar-helper"))
        guard case .needsRepair(let drift) = installer.report(for: moved).state else {
            Issue.record("expected needsRepair")
            return
        }
        #expect(drift.count == 1)
        #expect(drift.first?.description.contains("this copy of AgentBar is at") == true)
    }

    @Test("A helper that is not there at all is reported as missing")
    func reportsMissingHelper() throws {
        let home = try ScratchCodexHome()
        let installer = CodexInstaller(home: home.directory)
        let endpoint = try Self.endpoint(home)
        try installer.install(endpoint)
        try FileManager.default.removeItem(at: endpoint.helperURL)
        guard case .needsRepair(let drift) = installer.report(for: endpoint).state else {
            Issue.record("expected needsRepair")
            return
        }
        #expect(drift == [.helperMissing(path: endpoint.helperURL.path(percentEncoded: false))])
    }

    @Test("A repair after a move restores the state and asks for trust again")
    func repairAsksForTrustAgain() throws {
        let home = try ScratchCodexHome()
        let installer = CodexInstaller(home: home.directory)
        let first = CodexEndpoint(helperURL: home.directory.appending(path: "old-agentbar-helper"))
        try installer.install(first)
        try Data(Self.trustedConfig(for: home).utf8).write(to: home.configURL)

        let moved = try Self.endpoint(home)
        let outcome = try installer.install(moved)
        #expect(outcome.changed)
        // Trust was granted for the definition that named the old path. The
        // rewritten definition hashes differently, so Codex will ask again — and
        // the user has to be told, or the integration goes quiet with no reason.
        #expect(outcome.requiresTrust)
    }

    @Test("Re-installing an already trusted, unchanged configuration asks for nothing")
    func trustedReinstallAsksForNothing() throws {
        let home = try ScratchCodexHome()
        let installer = CodexInstaller(home: home.directory)
        let endpoint = try Self.endpoint(home)
        try installer.install(endpoint)
        try Data(Self.trustedConfig(for: home).utf8).write(to: home.configURL)
        let outcome = try installer.install(endpoint)
        #expect(!outcome.changed)
        #expect(!outcome.requiresTrust)
    }

    @Test("The user's own hooks are reported from both layers, and neither is touched")
    func reportsCoexistence() throws {
        let home = try ScratchCodexHome(
            hooks: #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#,
            config: TrustReadingTests.realShape)
        let configBefore = try Data(contentsOf: home.configURL)
        let installer = CodexInstaller(home: home.directory)
        try installer.install(try Self.endpoint(home))
        let report = installer.report(for: try Self.endpoint(home))

        #expect(report.overlaps.count == 4)
        #expect(report.overlaps.filter { $0.source == .configToml }.count == 3)
        #expect(report.overlaps.contains { $0.family == .caffeine })
        #expect(report.warnings.contains(.hooksAlsoInConfigToml(count: 3)))
        // The rule this whole module is built around.
        #expect(try Data(contentsOf: home.configURL) == configBefore)
    }

    @Test("config.toml is never written, by any path through the installer")
    func neverWritesConfigToml() throws {
        let home = try ScratchCodexHome(config: TrustReadingTests.realShape)
        let before = try Data(contentsOf: home.configURL)
        let installer = CodexInstaller(home: home.directory)
        let endpoint = try Self.endpoint(home)
        try installer.install(endpoint)
        _ = installer.report(for: endpoint)
        try installer.uninstall()
        #expect(try Data(contentsOf: home.configURL) == before)
        #expect(home.backups().allSatisfy { !$0.lastPathComponent.hasPrefix("config.toml") })
    }

    @Test("Backups are bounded")
    func prunesBackups() throws {
        let home = try ScratchCodexHome(hooks: #"{"description":"mine"}"#)
        let clock = ManualClock()
        let installer = CodexInstaller(home: home.directory, clock: clock)
        for index in 0..<8 {
            let endpoint = CodexEndpoint(
                helperURL: home.directory.appending(path: "helper-\(index)/agentbar-helper"))
            try installer.install(endpoint)
            clock.advance(by: 60)
        }
        #expect(home.backups().count == CodexInstaller.backupsKept)
    }
}
