import AgentBarCore
import AgentBarIngest
import Foundation
import Testing

@testable import ClaudeCodeAdapter

/// The parts of installing that can fail for filesystem reasons: the backup, the
/// atomic write, the permissions, and the files a crash could leave behind.
@Suite("Writing a settings file safely")
struct InstallerFileHandlingTests {

    @Test("Every write is preceded by a byte-for-byte backup")
    func backsUpBeforeWriting() throws {
        let original = try Fixtures.data("settings-with-foreign-hooks")
        let scratch = try ScratchSettings(contents: original)

        let outcome = try scratch.installer().install(try .test())
        let backup = try #require(outcome.backupURL)
        #expect(try Data(contentsOf: backup) == original)
        #expect(backup.lastPathComponent.hasPrefix("settings.json.bak."))
    }

    @Test("A backup is private even when the file it copies is not")
    func backupsArePrivate() throws {
        let scratch = try ScratchSettings(contents: Data("{}\n".utf8))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: scratch.url.path(percentEncoded: false))

        let backup = try #require(try scratch.installer().install(try .test()).backupURL)
        // The user's permissions on their own file are their decision
        // (ADR-0004). A backup is AgentBar's own artefact and holds a live
        // token, so it is not covered by that.
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: backup.path(percentEncoded: false))[
                .posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o600)
    }

    @Test("Backups are bounded rather than accumulated for ever")
    func backupsAreBounded() throws {
        let scratch = try ScratchSettings(contents: Data("{}\n".utf8))
        let clock = ManualClock()
        for port in 0..<(ClaudeCodeInstaller.backupsKept + 3) {
            clock.advance(by: 1)
            try scratch.installer(clock: clock).install(try .test(port: UInt16(47821 + port)))
        }
        #expect(scratch.backups.count == ClaudeCodeInstaller.backupsKept)
    }

    @Test("A write that fails leaves neither a temporary file nor an orphan backup")
    func cleansUpAfterAFailedWrite() throws {
        let original = Data("{}\n".utf8)
        let scratch = try ScratchSettings(contents: original)
        let installer = ClaudeCodeInstaller(
            settingsURL: scratch.url, fileManager: FailingWriteFileManager(), clock: ManualClock()
        )

        #expect(throws: ClaudeCodeInstallerError.self) { try installer.install(try .test()) }
        #expect(scratch.data == original)
        #expect(scratch.backups.isEmpty)
        #expect(scratch.strayFiles.isEmpty)
    }

    @Test("A temporary file a killed process left behind is swept up")
    func sweepsAbandonedTemporaries() throws {
        let scratch = try ScratchSettings(contents: Data("{}\n".utf8))
        let stray = scratch.directory
            .appending(path: "\(ClaudeCodeInstaller.temporaryPrefix)abandoned.tmp")
        try Data("{}".utf8).write(to: stray)

        try scratch.installer().install(try .test())
        // It held a token, and nothing else ever writes this prefix.
        #expect(!FileManager.default.fileExists(atPath: stray.path(percentEncoded: false)))
    }

    @Test("A differently formatted settings file survives the round trip")
    func roundTripsADifferentlyFormattedFile() throws {
        // Four-space indent, escaped solidus, keys in an order JSONWriter would
        // not choose. Install reformats it — the writer emits one shape — so the
        // contract that has to hold is semantic, not byte-for-byte.
        let original = Data(
            """
            {
                "theme": "dark",
                "hooks": {
                    "Stop": [
                        {
                            "hooks": [
                                {"type": "command", "command": "\\/usr\\/bin\\/true"}
                            ]
                        }
                    ]
                }
            }
            """.utf8)
        let scratch = try ScratchSettings(contents: original)
        try scratch.installer().install(try .test())
        try scratch.installer().uninstall()

        #expect(try JSONParser.parse(scratch.data) == JSONParser.parse(original))
    }

    @Test("Two writes in the same second do not overwrite the first backup")
    func backupsNeverCollide() throws {
        let scratch = try ScratchSettings(contents: Data("{}\n".utf8))
        let clock = ManualClock()
        try scratch.installer(clock: clock).install(try .test(port: 47821))
        try scratch.installer(clock: clock).install(try .test(port: 47822))
        #expect(scratch.backups.count == 2)
    }

    @Test("A settings file that cannot be parsed is never rewritten")
    func refusesToRewriteWhatItCannotRead() throws {
        let broken = Data("{ \"hooks\": [ truncated".utf8)
        let scratch = try ScratchSettings(contents: broken)
        #expect(throws: ClaudeCodeInstallerError.self) {
            try scratch.installer().install(try .test())
        }
        #expect(scratch.data == broken)
        #expect(scratch.backups.isEmpty)
    }

    @Test("An absent settings file is created private to its owner")
    func createsAPrivateFile() throws {
        let scratch = try ScratchSettings()
        #expect(!scratch.exists)
        try scratch.installer().install(try .test())

        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: scratch.url.path(percentEncoded: false))[
                .posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o600)
    }

    @Test("The permission of a file the user already had is left alone, and reported")
    func leavesExistingPermissionsAlone() throws {
        let scratch = try ScratchSettings(contents: Data("{}\n".utf8))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: scratch.url.path(percentEncoded: false))

        let outcome = try scratch.installer().install(try .test())
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: scratch.url.path(percentEncoded: false))[
                .posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o644)
        #expect(outcome.warnings.contains(.settingsReadableByOthers(mode: 0o644)))
    }

    @Test("Installing where Claude Code is not set up says so instead of creating it")
    func refusesAMissingDirectory() throws {
        let missing = URL(filePath: NSTemporaryDirectory())
            .appending(path: "agentbar-absent-\(UUID().uuidString)/settings.json")
        let installer = ClaudeCodeInstaller(settingsURL: missing)
        #expect(throws: ClaudeCodeInstallerError.self) { try installer.install(try .test()) }
        #expect(!FileManager.default.fileExists(atPath: missing.path(percentEncoded: false)))
    }

    @Test("Uninstalling when nothing was installed is not an error")
    func uninstallIsSafeWhenNothingIsInstalled() throws {
        let original = try Fixtures.data("settings-with-foreign-hooks")
        let scratch = try ScratchSettings(contents: original)
        let outcome = try scratch.installer().uninstall()
        #expect(!outcome.changed)
        #expect(scratch.data == original)

        let absent = try ScratchSettings()
        #expect(!(try absent.installer().uninstall().changed))
        #expect(!absent.exists)
    }
}
