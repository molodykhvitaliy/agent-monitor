import Foundation
import Testing

@testable import CodexAppServer

/// Where `codex` is looked for, and why `PATH` alone is not the answer.
///
/// An app launched from the Finder or at login inherits launchd's environment,
/// which on the developer's machine sets no `PATH` at all — so the process comes
/// up with `/usr/bin:/bin:/usr/sbin:/sbin`, and Codex installs to `~/.local/bin`.
/// A build that trusted `PATH` would work perfectly from a terminal and find
/// nothing once installed.
@Suite("Codex executable discovery")
struct ExecutableDiscoveryTests {

    /// A directory holding an executable called `codex`, deleted with the test.
    struct Installed: ~Copyable {
        let directory: URL

        init(executable: Bool = true) throws {
            directory = URL(filePath: NSTemporaryDirectory())
                .appending(path: "agentbar-locate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let binary = directory.appending(path: "codex")
            try "#!/bin/sh\n".write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: executable ? 0o755 : 0o644],
                ofItemAtPath: binary.path(percentEncoded: false))
        }

        var path: String { directory.path(percentEncoded: false) }
        var binary: URL { directory.appending(path: "codex") }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    static func defaults(override: String? = nil) -> UserDefaults {
        let suite = UserDefaults(suiteName: "codex-locate-\(UUID().uuidString)") ?? .standard
        if let override { suite.set(override, forKey: CodexExecutable.overrideDefaultsKey) }
        return suite
    }

    @Test("A well-known directory is searched before PATH")
    func prefersAWellKnownDirectory() throws {
        let installed = try Installed()
        let found = CodexExecutable.locate(
            defaults: Self.defaults(), environment: [:], directories: [installed.path])
        #expect(found?.url == installed.binary)
    }

    @Test("PATH is the last resort, not the only one")
    func fallsBackToPath() throws {
        let installed = try Installed()
        let found = CodexExecutable.locate(
            defaults: Self.defaults(),
            environment: ["PATH": "/nowhere:\(installed.path)"],
            directories: [])
        #expect(found?.url == installed.binary)
    }

    /// Nothing to find is an ordinary answer on a machine that only runs Claude
    /// Code, and it must not be an error.
    @Test("No codex anywhere is nil, not a failure")
    func reportsAbsence() {
        #expect(
            CodexExecutable.locate(
                defaults: Self.defaults(), environment: ["PATH": "/nowhere"], directories: [])
                == nil)
    }

    @Test("A file that is not executable is not the binary")
    func ignoresANonExecutableFile() throws {
        let installed = try Installed(executable: false)
        #expect(
            CodexExecutable.locate(
                defaults: Self.defaults(), environment: [:], directories: [installed.path]) == nil)
    }

    @Test("The override wins over everything")
    func honoursTheOverride() throws {
        let installed = try Installed()
        let elsewhere = try Installed()
        let found = CodexExecutable.locate(
            defaults: Self.defaults(override: elsewhere.binary.path(percentEncoded: false)),
            environment: [:],
            directories: [installed.path])
        #expect(found?.url == elsewhere.binary)
    }

    /// Falling through to the search list would silently run a different binary
    /// than the one the user named, and they would have no way to tell.
    @Test("An override that does not resolve finds nothing rather than something else")
    func doesNotFallThroughFromABadOverride() throws {
        let installed = try Installed()
        let found = CodexExecutable.locate(
            defaults: Self.defaults(override: "/nowhere/at/all/codex"),
            environment: ["PATH": installed.path],
            directories: [installed.path])
        #expect(found == nil)
    }

    /// Asserted directly rather than through `locate`, because every indirect
    /// version of this test passes just as well when the tilde was never
    /// expanded: an unresolvable `~/…` path finds nothing either way. The
    /// default search list is written with tildes and `$TMPDIR` is not under
    /// `$HOME`, so there is nowhere to plant a real binary for it.
    @Test("A tilde is expanded, not looked for on disk")
    func expandsATilde() {
        let home = NSHomeDirectory()
        #expect(
            CodexExecutable.expand("~/.local/bin").path(percentEncoded: false)
                == "\(home)/.local/bin")
        #expect(
            CodexExecutable.expand("/opt/homebrew/bin").path(percentEncoded: false)
                == "/opt/homebrew/bin")
        // Every entry of the shipped list resolves to an absolute path — a `~`
        // that survived would be a directory named "~" in the working directory.
        #expect(
            CodexExecutable.searchDirectories.allSatisfy {
                CodexExecutable.expand($0).path(percentEncoded: false).hasPrefix("/")
            })
    }
}
