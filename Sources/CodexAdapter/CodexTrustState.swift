import Foundation

/// What Codex has recorded about one hook definition.
///
/// Codex hashes the definition and stores the hash against the entry's position;
/// a changed definition therefore stops matching and goes back to needing
/// review. **AgentBar never computes that hash.** The algorithm is not
/// documented — four candidate pre-images were tried against three live records
/// and none matched — and a monitor that reproduced it would be one release away
/// from confidently telling the user a dead hook was fine.
public struct CodexTrustRecord: Sendable, Hashable {
    /// `sha256:…` as Codex wrote it. Carried for diagnostics, never recomputed.
    public let trustedHash: String?
    /// Codex lets a user disable an individual non-managed hook. A disabled
    /// entry is trusted and still will not run, which is a different sentence
    /// from "not trusted" and has to be reported as one.
    public let enabled: Bool

    public init(trustedHash: String?, enabled: Bool) {
        self.trustedHash = trustedHash
        self.enabled = enabled
    }

    /// Whether Codex would run the entry this record belongs to.
    public var permitsExecution: Bool { enabled && trustedHash != nil }
}

/// What `~/.codex/config.toml` says, for the two questions AgentBar may ask it.
///
/// **This file is read and never written.** It is the file that holds `notify`
/// — already taken by Codex Computer Use on this machine — the user's comments,
/// and their own hooks, and it is the reason `hooks.json` exists as AgentBar's
/// only write target.
public struct CodexConfigReading: Sendable, Hashable {
    /// Trust records by `[hooks.state]` key.
    public let trust: [String: CodexTrustRecord]
    /// The user's own hooks, declared in the TOML rather than in `hooks.json`.
    /// This is where the `caffeine.sh` entries on this machine live, so a
    /// coexistence report that read only `hooks.json` would say there was
    /// nothing to coexist with.
    public let hooks: [CodexHookOverlap]
    /// `false` when there is no `config.toml` at all, which is ordinary: a Codex
    /// installation that has never been configured has none.
    public let isPresent: Bool
    /// `false` when the file is there and its contents could not be obtained —
    /// unreadable, implausibly large, or not UTF-8.
    ///
    /// Kept apart from "present but holding no trust records", which is the
    /// ordinary state before the user has trusted anything. One of those two
    /// facts means *nothing has been trusted*; the other means *AgentBar cannot
    /// tell*, and only the second earns a warning.
    public let isReadable: Bool

    /// Nothing known, because there was nothing to read.
    public static let absent = CodexConfigReading(
        trust: [:], hooks: [], isPresent: false, isReadable: true)

    public init(
        trust: [String: CodexTrustRecord],
        hooks: [CodexHookOverlap],
        isPresent: Bool,
        isReadable: Bool
    ) {
        self.trust = trust
        self.hooks = hooks
        self.isPresent = isPresent
        self.isReadable = isReadable
    }
}

/// Reads the two tables AgentBar is allowed to care about out of `config.toml`.
public enum CodexConfigFile {
    static let trustTable = ["hooks", "state"]
    static let hooksTable = "hooks"

    /// A `config.toml` larger than this is not read at all.
    ///
    /// The file is a few kilobytes in every real installation; a megabyte of it
    /// is a sign of something wrong, and a status surface is not worth an
    /// unbounded read on the main path.
    static let maximumBytes = 1 << 20

    /// Reads the file, or reports that nothing is known.
    ///
    /// Never throws. Absent, unreadable, too large, or written in TOML this
    /// reader does not understand all resolve the same way — to *no information*,
    /// which the caller turns into "trust not confirmed" rather than into a
    /// claim in either direction.
    static func read(at url: URL, fileManager: FileManager = .default) -> CodexConfigReading {
        let path = url.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: path) else { return .absent }
        guard let size = (try? fileManager.attributesOfItem(atPath: path))?[.size] as? NSNumber,
            size.intValue <= maximumBytes,
            let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        else {
            return CodexConfigReading(trust: [:], hooks: [], isPresent: true, isReadable: false)
        }
        return parse(text)
    }

    static func parse(_ text: String) -> CodexConfigReading {
        var trust: [String: CodexTrustRecord] = [:]
        var hooks: [CodexHookOverlap] = []
        /// The matcher of the most recent `[[hooks.<Event>]]`, which is the
        /// group a following `[[hooks.<Event>.hooks]]` belongs to.
        var matcherByEvent: [String: String?] = [:]

        for table in TOMLTables.tables(in: text) {
            if table.path.count == trustTable.count + 1,
                Array(table.path.prefix(trustTable.count)) == trustTable
            {
                let key = table.path[trustTable.count]
                trust[key] = CodexTrustRecord(
                    trustedHash: table.values["trusted_hash"],
                    // Absent means enabled: Codex writes the flag only when the
                    // user has turned an entry off.
                    enabled: table.values["enabled"].map { $0 == "true" } ?? true)
                continue
            }
            guard table.path.first == hooksTable else { continue }
            switch table.path.count {
            case 2 where table.path[1] != "state":
                matcherByEvent[table.path[1]] = table.values["matcher"]
            case 3 where table.path[2] == "hooks":
                let event = table.path[1]
                let command = table.values["command"] ?? table.values["type"] ?? "hook"
                guard !CodexHookCommand.isAgentBarCommand(command) else { continue }
                let summary = CodexHooksFile.describe(command)
                hooks.append(
                    CodexHookOverlap(
                        event: event,
                        matcher: matcherByEvent[event].flatMap { $0 },
                        summary: summary,
                        family: CodexHooksFile.family(of: summary),
                        source: .configToml))
            default:
                continue
            }
        }
        return CodexConfigReading(trust: trust, hooks: hooks, isPresent: true, isReadable: true)
    }

    /// `~/.codex/config.toml`, or the same file under `CODEX_HOME`.
    ///
    /// A menu-bar app launched from the Finder inherits no shell environment, so
    /// the override is seen only when it was set for the login session — the
    /// same caveat the Claude Code installer carries about `CLAUDE_CONFIG_DIR`,
    /// and worth honouring for the same reason: reading the wrong file is a
    /// failure with no symptom.
    public static func defaultHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let home = environment["CODEX_HOME"], !home.isEmpty {
            return URL(filePath: home, directoryHint: .isDirectory)
        }
        return fileManager.homeDirectoryForCurrentUser.appending(
            path: ".codex", directoryHint: .isDirectory)
    }
}
