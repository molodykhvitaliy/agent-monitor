import AgentBarCore
import AgentBarJSON
import Foundation
import Testing

@testable import CodexAdapter

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

    static func trustedConfig(
        for home: ScratchCodexHome, enabled: Bool = true,
        hash: String = "sha256:whatever-codex-computed"
    ) -> String {
        InstallerTests.trustedConfig(for: home, enabled: enabled, hash: hash)
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

    @Test("A repair after a move rewrites the same eight entries and asks for trust again")
    func repairAsksForTrustAgain() throws {
        let home = try ScratchCodexHome()
        let baseline = home.directory.appending(path: "trust-baseline.json")
        let installer = CodexInstaller(home: home.directory, trustBaselineURL: baseline)
        // A *moved app*, which keeps the file name: the recognition rule is the
        // basename, so a stand-in called anything else would not be recognised
        // as AgentBar's at all and the repair path would never run.
        let old = try home.makeHelper(at: "Old.app/Contents/MacOS/agentbar-helper")
        try installer.install(CodexEndpoint(helperURL: old))
        try Data(Self.trustedConfig(for: home).utf8).write(to: home.configURL)

        let moved = try Self.endpoint(home)
        let outcome = try installer.install(moved)
        #expect(outcome.changed)
        // The old entries were replaced, not joined: eight in, eight out.
        let hooks = CodexHooksFile.installedHooks(in: try JSONParser.parse(home.hooksData))
        #expect(hooks.count == CodexHookHandler.monitoring.count)
        #expect(hooks.allSatisfy { $0.command == moved.command })
        // Trust was granted for the definition that named the old path. The
        // rewritten definition hashes differently, so Codex will ask again — and
        // the user has to be told, or the integration goes quiet with no reason.
        #expect(outcome.requiresTrust)
    }

    @Test("A timeout change alone still invalidates trust")
    func timeoutChangeRequiresTrust() throws {
        let home = try ScratchCodexHome()
        let installer = CodexInstaller(home: home.directory)
        let endpoint = try Self.endpoint(home)
        try installer.install(endpoint)
        try Data(Self.trustedConfig(for: home).utf8).write(to: home.configURL)

        // The same commands, one different timeout: Codex hashes the whole
        // definition, so this is a new hook to it. Comparing commands alone —
        // which every entry shares — would have called this unchanged.
        var root = try #require(JSONParser.parse(home.hooksData).object)
        var hooks = try #require(root["hooks"]?.object)
        var groups = try #require(hooks["Stop"]?.array)
        var group = try #require(groups[0].object)
        var handlers = try #require(group["hooks"]?.array)
        var handler = try #require(handlers[0].object)
        handler["timeout"] = .number("5")
        handlers[0] = .object(handler)
        group["hooks"] = .array(handlers)
        groups[0] = .object(group)
        hooks["Stop"] = .array(groups)
        root["hooks"] = .object(hooks)
        try JSONWriter.data(.object(root)).write(to: home.hooksURL)

        let outcome = try installer.install(endpoint)
        #expect(outcome.changed)
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

    @Test("A stale trust record left at the same position does not read as trusted")
    func staleTrustRecordIsNotTrust() throws {
        let home = try ScratchCodexHome()
        let baselineURL = home.directory.appending(path: "trust-baseline.json")
        let installer = CodexInstaller(home: home.directory, trustBaselineURL: baselineURL)
        let old = try home.makeHelper(at: "Old.app/Contents/MacOS/agentbar-helper")
        try installer.install(CodexEndpoint(helperURL: old))
        try Data(Self.trustedConfig(for: home).utf8).write(to: home.configURL)
        #expect(installer.report(for: CodexEndpoint(helperURL: old)).state == .installed)

        // The app moves — the documented `cp -R … /Applications` — and the user
        // presses Repair. Codex keys trust by *position*, so every record is
        // still there, still saying `trusted_hash`, and now describing a
        // definition Codex will refuse to run. Reading it at face value would
        // put `Connected` under an integration that is inert, which is the one
        // outcome ADR-0008 exists to forbid.
        let moved = try Self.endpoint(home)
        try installer.install(moved)
        #expect(installer.report(for: moved).state == .installedNotTrusted(.notTrusted))
    }

    @Test("A record that changes after the rewrite is consent for what is there now")
    func reviewedAgainReadsAsTrusted() throws {
        let home = try ScratchCodexHome()
        let baselineURL = home.directory.appending(path: "trust-baseline.json")
        let installer = CodexInstaller(home: home.directory, trustBaselineURL: baselineURL)
        let old = try home.makeHelper(at: "Old.app/Contents/MacOS/agentbar-helper")
        try installer.install(CodexEndpoint(helperURL: old))
        try Data(Self.trustedConfig(for: home).utf8).write(to: home.configURL)
        let moved = try Self.endpoint(home)
        try installer.install(moved)
        #expect(installer.report(for: moved).state == .installedNotTrusted(.notTrusted))

        // The user opens /hooks and trusts the new definition. Codex writes a
        // fresh hash at the same key, and a hash that has moved since AgentBar
        // wrote is consent for what AgentBar wrote.
        try Data(
            Self.trustedConfig(for: home, hash: "sha256:reviewed-again").utf8
        ).write(to: home.configURL)
        #expect(installer.report(for: moved).state == .installed)
    }

    @Test("A delivery settles the question the baseline was asking")
    func deliveryClearsTheBaseline() throws {
        let home = try ScratchCodexHome()
        let baselineURL = home.directory.appending(path: "trust-baseline.json")
        let installer = CodexInstaller(home: home.directory, trustBaselineURL: baselineURL)
        let old = try home.makeHelper(at: "Old.app/Contents/MacOS/agentbar-helper")
        try installer.install(CodexEndpoint(helperURL: old))
        try Data(Self.trustedConfig(for: home).utf8).write(to: home.configURL)
        let moved = try Self.endpoint(home)
        try installer.install(moved)

        installer.clearTrustBaseline()
        #expect(
            !FileManager.default.fileExists(atPath: baselineURL.path(percentEncoded: false)))
        #expect(installer.report(for: moved).state == .installed)
    }

    @Test("Without a baseline the caller's own memory of the rewrite still decides")
    func trustPendingCarriesTheLaunch() throws {
        let home = try ScratchCodexHome()
        // No baseline URL: this is the app whose application support directory
        // could not be reached, or whose write failed.
        let installer = CodexInstaller(home: home.directory)
        try installer.install(try Self.endpoint(home))
        try Data(Self.trustedConfig(for: home).utf8).write(to: home.configURL)
        let endpoint = try Self.endpoint(home)
        #expect(installer.report(for: endpoint).state == .installed)
        #expect(
            installer.report(for: endpoint, trustPending: true).state
                == .installedNotTrusted(.notTrusted))
        // A delivery outranks even that.
        #expect(
            installer.report(for: endpoint, hasDelivered: true, trustPending: true).state
                == .installed)
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
