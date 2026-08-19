import Foundation

/// Finds the `codex` binary, and reads its version.
///
/// **PATH is not enough, and this is the whole reason the type exists.** An app
/// launched from the Finder or at login inherits launchd's environment, and on
/// this machine `launchctl getenv PATH` is empty — so the process comes up with
/// `/usr/bin:/bin:/usr/sbin:/sbin` and nothing else. Codex installs to
/// `~/.local/bin`, which is on none of them. A build that trusted `PATH` would
/// work perfectly when run from a terminal and find nothing at all once
/// installed, which is the worst possible way for this to fail.
///
/// So the search is: what the user told us, then the places Codex actually
/// installs to, then whatever `PATH` this process happens to have. Absence is
/// not a fault — Codex simply is not installed here, and the Limits section says
/// nothing rather than complaining.
public struct CodexExecutable: Sendable, Hashable {
    /// Where the user can name the binary themselves, when it is somewhere this
    /// list has never heard of. A defaults key rather than a settings control:
    /// the design brief's restraint requirement is explicit, and this is a
    /// repair for an unusual install rather than a preference.
    public static let overrideDefaultsKey = "codex.executablePath"

    /// Directories Codex is installed into, most specific first.
    ///
    /// `~/.local/bin` is where the standalone installer puts it and is first
    /// because it is what this machine has; the Homebrew prefixes follow, Apple
    /// silicon before Intel; `/usr/local/bin` also catches an npm global prefix
    /// with default settings.
    public static let searchDirectories = [
        "~/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "~/.bun/bin",
        "~/.npm-global/bin",
        "/usr/bin",
    ]

    public let url: URL

    public init(url: URL) { self.url = url }

    /// Looks for the binary, or reports that there is not one.
    ///
    /// `nil` is an ordinary answer. Nothing is logged, because "Codex is not
    /// installed" is not news on a machine that only runs Claude Code.
    public static func locate(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        directories: [String] = searchDirectories
    ) -> CodexExecutable? {
        if let override = defaults.string(forKey: overrideDefaultsKey),
            !override.trimmingCharacters(in: .whitespaces).isEmpty
        {
            // An override that does not resolve is reported by returning
            // nothing rather than by falling through: silently using a
            // different binary than the one named would be worse than finding
            // none, because the user would have no way to tell.
            return runnable(at: expand(override), fileManager: fileManager)
        }
        for directory in directories {
            let candidate = expand(directory).appending(path: "codex")
            if let found = runnable(at: candidate, fileManager: fileManager) { return found }
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            guard !directory.isEmpty else { continue }
            let candidate = expand(String(directory)).appending(path: "codex")
            if let found = runnable(at: candidate, fileManager: fileManager) { return found }
        }
        return nil
    }

    private static func runnable(at url: URL, fileManager: FileManager) -> CodexExecutable? {
        let path = url.path(percentEncoded: false)
        // `isExecutableFile` follows the symlink `~/.local/bin/codex` is, and
        // reports false for a directory, so no separate check is needed.
        guard fileManager.isExecutableFile(atPath: path) else { return nil }
        return CodexExecutable(url: url)
    }

    /// Internal rather than private so the suite can assert it directly.
    ///
    /// A tilde is the one thing standing between an app launched at login and a
    /// `codex` it can find, and every indirect test of it — "an unresolvable
    /// `~/…` path finds nothing" — passes just as well when the tilde was never
    /// expanded at all. `$TMPDIR` is not under `$HOME` on macOS, so there is no
    /// honest way to test this through `locate` without writing into the user's
    /// home directory.
    static func expand(_ path: String) -> URL {
        URL(filePath: (path as NSString).expandingTildeInPath)
    }
}

/// Which Codex answered, taken from the handshake rather than from a second
/// process.
///
/// `initialize` replies with a `userAgent` of the form
/// `AgentBar/0.147.0 (Mac OS 27.0.0; arm64) unknown (AgentBar; 0.1.0)`, where
/// the first version is Codex's own. Running `codex --version` would cost a
/// whole extra spawn to learn something the connection is about to say anyway.
///
/// Deliberately **not** parsed into a comparable version with a minimum floor.
/// The only floor anybody could name is the version this was verified against,
/// and refusing to try below it would break users on a Codex that works while
/// buying nothing: whether the account methods exist is a question the server
/// answers exactly, in one round trip, by rejecting a method it does not
/// implement. So the version is a diagnostic and a cache key — the reading that
/// says "this build of Codex has no account API" is remembered against it, and
/// forgotten the moment the user updates.
public struct CodexVersion: Sendable, Hashable, CustomStringConvertible {
    public let raw: String

    public init(raw: String) {
        self.raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The version out of an `initialize` reply's user agent, or the whole
    /// string when it is not the shape we expect — an unrecognised user agent
    /// still identifies the build it came from, which is all this is for.
    public init(userAgent: String) {
        let trimmed = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmed.firstIndex(of: "/") else {
            self.init(raw: trimmed)
            return
        }
        let rest = trimmed[trimmed.index(after: slash)...]
        let version = rest.prefix { !$0.isWhitespace }
        self.init(raw: version.isEmpty ? trimmed : String(version))
    }

    public var description: String { raw }
}
