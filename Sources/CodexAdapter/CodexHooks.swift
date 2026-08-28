import AgentBarCore
import AgentBarIngest
import Foundation

/// A Codex hook event AgentBar understands.
///
/// Longer than the list AgentBar installs, deliberately. An event it does not
/// subscribe to still decodes if one arrives — a `hooks.json` left behind by an
/// older version, or an entry the user pointed here themselves — because an
/// unrecognised delivery is not a fault.
public enum CodexHookEvent: String, Sendable, Hashable, CaseIterable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    /// Not in the Codex 0.148 lifecycle list, but decoded defensively if a
    /// client emits the Claude-compatible spelling. It is deliberately not
    /// installed as a tenth handler.
    case postToolUseFailure = "PostToolUseFailure"
    case permissionRequest = "PermissionRequest"
    case preCompact = "PreCompact"
    case postCompact = "PostCompact"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case stop = "Stop"

    /// The event as it is spelled inside a `[hooks.state]` key.
    ///
    /// Codex records trust under `<source path>:<event>:<group>:<hook>`, and the
    /// event there is snake_case where the payload's `hook_event_name` is
    /// CamelCase — `SessionEnd` becomes `session_end`. Observed on this machine
    /// against the user's own hooks; see `CodexTrustState`.
    public var trustStateName: String {
        var result = ""
        for character in rawValue {
            if character.isUppercase, !result.isEmpty { result.append("_") }
            result.append(Character(character.lowercased()))
        }
        return result
    }
}

/// One handler AgentBar installs, described rather than hard-coded.
///
/// The installer renders these into `hooks.json` and recognises them coming
/// back, so changing the set is a change to a list rather than to the installer.
public struct CodexHookHandler: Sendable, Hashable {
    public let event: CodexHookEvent
    /// `nil` installs the handler for every occurrence of the event. Every
    /// handler AgentBar installs is matcher-less: it watches a whole event, and
    /// two of the events it watches ignore matchers outright.
    public let matcher: String?
    /// Seconds. Always explicit — Codex's own default is 600.
    public let timeout: Int

    public init(event: CodexHookEvent, matcher: String? = nil, timeout: Int) {
        self.event = event
        self.matcher = matcher
        self.timeout = timeout
    }
}

extension CodexHookHandler {
    /// Two seconds, on a helper measured in single-digit milliseconds.
    ///
    /// Codex's default is **600 seconds** and must never be inherited: a hook
    /// that hangs with that timeout is an agent that hangs with it. Two seconds
    /// is the same ceiling the Claude Code handlers carry, for the same reason —
    /// it bounds the one case that can actually stall, which is some other
    /// process holding the port, accepting the connection and never answering.
    public static let defaultTimeout = 2

    /// One second on `SessionEnd`, which is the platform's own cap.
    ///
    /// *"`SessionEnd` uses `1` second by default and supports up to `3`
    /// seconds"*, and it runs synchronously whatever `async` says. Asking for
    /// more than the default would lengthen shutdown for a value AgentBar does
    /// not need: the relay finishes in a few milliseconds or gives up.
    ///
    /// It is also the number `worstCaseHelperRun` is measured against, and
    /// raising it is not the cheap way out of a tight margin: Codex keys hook
    /// trust to the hash of the whole definition, so a changed timeout sends
    /// every user back to `/hooks` to re-approve a hook they had already
    /// approved.
    public static let sessionEndTimeout = 1

    /// What a helper process may cost before its own code starts.
    ///
    /// Everything the helper *decides* is bounded by two constants it owns —
    /// `StandardInput.defaultCeiling` and `RelayTimeouts.total` — and neither of
    /// them can see the part that comes first: `execve`, dyld loading a 2.2 MB
    /// binary and linking `CodexAdapter`, all before `main.swift` reads a byte.
    /// `HelperTimingProof` measured that whole run at p50 8.5 ms and **74.2 ms
    /// max over forty runs on an idle Mac**, so 150 ms is twice the worst
    /// observed and is deliberately an allowance rather than a measurement — it
    /// is a number the budget below is held to, not one the helper enforces.
    public static let helperSpawnAllowance: Duration = .milliseconds(150)

    /// The longest a helper process can take on any path, spawn included.
    ///
    /// > **The arithmetic that used to omit its first term.** The drain's
    /// > ceiling and the relay's total were chosen against each other and their
    /// > sum described as "the worst path", which left the process start-up out
    /// > of a budget whose whole purpose is to fit inside a platform timeout.
    /// > `HelperBudgetTests` asserts this against `sessionEndTimeout`, so the next
    /// > change to either constant has to answer for the margin rather than
    /// > rediscover it.
    public static var worstCaseHelperRun: Duration {
        helperSpawnAllowance + StandardInput.defaultCeiling + RelayTimeouts().total
    }

    /// The handlers the MVP installs, in the order they are written.
    ///
    /// Nine events, and the two absences are each a decision:
    ///
    /// - **`PermissionRequest` is observation-only.** The helper returns no
    ///   output and exits successfully, so Codex's own approval prompt remains
    ///   the only place a decision can be made. Installing the event lets the
    ///   domain show the wait without moving the Approve/Deny backlog item into
    ///   this monitor.
    /// - **`PreCompact` / `PostCompact` are not installed.** Compaction is not a
    ///   state the panel shows, and each extra entry is another hook the user has
    ///   to review before any of them run.
    /// - **No `notify` entry, ever.** It is a single-slot key in `config.toml`,
    ///   the file AgentBar does not write, and on this machine it is already
    ///   taken by Codex Computer Use.
    public static let monitoring: [CodexHookHandler] = [
        CodexHookHandler(event: .sessionStart, timeout: defaultTimeout),
        CodexHookHandler(event: .userPromptSubmit, timeout: defaultTimeout),
        CodexHookHandler(event: .preToolUse, timeout: defaultTimeout),
        CodexHookHandler(event: .postToolUse, timeout: defaultTimeout),
        CodexHookHandler(event: .permissionRequest, timeout: defaultTimeout),
        CodexHookHandler(event: .subagentStart, timeout: defaultTimeout),
        CodexHookHandler(event: .subagentStop, timeout: defaultTimeout),
        CodexHookHandler(event: .stop, timeout: defaultTimeout),
        CodexHookHandler(event: .sessionEnd, timeout: sessionEndTimeout),
    ]
}

/// The command written into `hooks.json`, and the way one is recognised.
///
/// Codex runs a hook command **through a shell** — the entry already on this
/// machine relies on `"$HOME"` expanding — so the path is quoted rather than
/// passed as argv. The quoting is single-quote and nothing else: a path is data,
/// and the only character that needs escaping inside single quotes is the single
/// quote itself.
public enum CodexHookCommand {
    /// The helper's file name, inside the app bundle, Application Support and
    /// the installed command.
    /// Recognition keys off this rather than the whole path, because the path
    /// changes when the app is moved and the entry then has to be *recognised*
    /// in order to be repaired.
    public static let executableName = "agentbar-helper"

    /// The command for a helper at `url`.
    public static func command(forHelperAt url: URL) -> String {
        quote(url.path(percentEncoded: false))
    }

    /// POSIX single-quoting: `it's` becomes `'it'\''s'`.
    static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The path inside a command AgentBar wrote, or `nil` for anything else.
    ///
    /// Understands only the shape this module writes — one quoted or bare path,
    /// no arguments — because that is all it has to recognise. A command that
    /// merely mentions the helper somewhere in a longer script is not one of
    /// ours and is left alone; if it were treated as ours, an uninstall would
    /// delete somebody else's line.
    public static func helperPath(in command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if trimmed.hasPrefix("'"), trimmed.hasSuffix("'"), trimmed.count >= 2 {
            path = String(trimmed.dropFirst().dropLast())
                .replacingOccurrences(of: "'\\''", with: "'")
        } else if trimmed.contains(" ") {
            // Arguments, a pipeline or a shell built-in: not something AgentBar
            // wrote, whatever it names.
            return nil
        } else {
            path = trimmed
        }
        // An absolute path, and nothing that a shell would read as more than
        // one word. `'echo hi; /tmp/agentbar-helper'` is quoted, ends in the
        // right file name, and is emphatically not something AgentBar wrote —
        // and treating it as ours would mean deleting it on uninstall. Spaces
        // stay legal, because a path may contain one and quoting is why this
        // module quotes.
        let metacharacters: Set<Character> = [";", "&", "|", "`", "$", "<", ">", "(", ")", "\n"]
        guard !path.isEmpty, path.hasPrefix("/"),
            !path.contains(where: metacharacters.contains),
            URL(filePath: path).lastPathComponent == executableName
        else { return nil }
        return path
    }

    /// Whether a `hooks.json` entry's command is one AgentBar wrote.
    public static func isAgentBarCommand(_ command: String) -> Bool {
        helperPath(in: command) != nil
    }

    /// Where the source helper sits in a running app bundle: a sibling of the
    /// executable, at `Contents/MacOS/agentbar-helper`.
    ///
    /// Hooks do not name this URL. `CodexHelperDeployment` copies it to a
    /// stable Application Support path first, so moving or rebuilding the app
    /// does not change the definition Codex trusts.
    public static func bundledHelperURL(
        executableURL: URL? = Bundle.main.executableURL
    ) -> URL? {
        guard let executableURL else { return nil }
        return executableURL.deletingLastPathComponent().appending(path: executableName)
    }
}

/// Where AgentBar's endpoint is, as the Codex side needs it.
///
/// Deliberately thinner than its Claude Code counterpart, and the difference is
/// the point: **no token appears in `hooks.json`**. The helper reads the token
/// from the file the endpoint publishes it in, at the moment it runs. So a
/// rotated token and a moved port change nothing on disk, and neither of them
/// can invalidate Codex's trust in a hook definition that never mentioned them.
public struct CodexEndpoint: Sendable, Hashable {
    /// Where the helper posts. Named here so the decoder's route and the
    /// helper's request cannot drift apart.
    public static let route = IngestRoute.hooks(of: .codex)

    /// The helper binary the hooks will invoke.
    public let helperURL: URL

    public init(helperURL: URL) {
        self.helperURL = helperURL
    }

    public var command: String { CodexHookCommand.command(forHelperAt: helperURL) }
}
