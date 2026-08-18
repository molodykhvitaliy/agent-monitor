import AgentBarCore
import AgentBarIngest
import Foundation

/// A hook event AgentBar understands.
///
/// The list is deliberately shorter than Claude Code's. An event AgentBar does
/// not subscribe to still decodes if one arrives — a settings file left behind
/// by an older version, or a hook the user copied — because an unrecognised
/// delivery is not a fault.
public enum ClaudeCodeHookEvent: String, Sendable, Hashable, CaseIterable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case notification = "Notification"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    case sessionEnd = "SessionEnd"
}

/// Why Claude Code raised a notification.
///
/// Only the cases AgentBar acts on need naming; an unknown value decodes to
/// `nil` and is ignored, which is what makes a new notification type in a future
/// release a no-op rather than a mislabelled session.
public enum ClaudeCodeNotification: String, Sendable, Hashable, CaseIterable {
    case permissionPrompt = "permission_prompt"
    case idlePrompt = "idle_prompt"
    case elicitationDialog = "elicitation_dialog"
    case elicitationURLDialog = "elicitation_url_dialog"

    /// Whether this notification means the agent is blocked on the human.
    ///
    /// `idle_prompt` is not, and the distinction matters: it fires about sixty
    /// seconds after Claude finished responding and only if nobody has typed
    /// since, so it describes a human who has walked away from a session that
    /// `Stop` already moved to idle. Treating it as "waiting" would relabel
    /// every idle session a minute after it went quiet.
    public var meansBlockedOnHuman: Bool {
        switch self {
        case .permissionPrompt, .elicitationDialog, .elicitationURLDialog: true
        case .idlePrompt: false
        }
    }
}

/// One handler AgentBar installs, described rather than hard-coded.
///
/// The installer renders these into `settings.json` and recognises them coming
/// back, so adding the synchronous `PermissionRequest` handler the Approve/Deny
/// backlog item needs is a new element in a list, not a new branch in the
/// installer.
public struct ClaudeCodeHookHandler: Sendable, Hashable {
    public let event: ClaudeCodeHookEvent
    /// `nil` installs the handler for every occurrence of the event.
    public let matcher: String?
    /// Seconds. Always explicit — see `ClaudeCodeHookHandler.defaultTimeout`.
    public let timeout: Int

    public init(event: ClaudeCodeHookEvent, matcher: String? = nil, timeout: Int) {
        self.event = event
        self.matcher = matcher
        self.timeout = timeout
    }
}

extension ClaudeCodeHookHandler {
    /// Two seconds, on a request the endpoint answers in under two milliseconds.
    ///
    /// An `http` hook **blocks** the agent until the endpoint answers: `async`
    /// is documented as available on `type: "command"` handlers only, so the
    /// architecture's "nothing AgentBar installs may delay an agent" is upheld
    /// by latency and by this number rather than by a flag. Two seconds is a
    /// thousand times the measured p99 and bounds the one case that could
    /// actually stall — some other process holding the port, accepting the
    /// connection and never answering — to something a human barely notices.
    /// Claude Code's own default is 600 seconds and must never be inherited.
    public static let defaultTimeout = 2

    /// One second for `SessionEnd`, which is smaller than everything else for a
    /// reason.
    ///
    /// `SessionEnd` handlers share a 1.5-second budget, and Claude Code raises
    /// that budget to match the largest explicit timeout in the settings files.
    /// A larger number here would lengthen session shutdown for the user's own
    /// `SessionEnd` hooks as well as ours; one second stays under the budget and
    /// cannot extend it.
    public static let sessionEndTimeout = 1

    /// The handlers the MVP installs.
    ///
    /// `SessionStart` is absent and its absence is a platform fact, not an
    /// oversight: Claude Code supports only `command` and `mcp_tool` handlers on
    /// that event, and AgentBar spawns no process per event. Nothing is lost —
    /// `SessionStore` adopts a session on whatever event reaches it first — except
    /// the `model` field, which no other event carries.
    ///
    /// `PostToolUseFailure` is present and was not in the plan. `PostToolUse`
    /// fires only when a tool *succeeds*, so without it a failed tool call is
    /// never closed and the session keeps showing a tool that stopped running.
    ///
    /// `WorktreeCreate` is deliberately absent and must stay absent: configuring
    /// it **replaces** Claude Code's own worktree creation, which would make
    /// AgentBar responsible for a feature it only wants to watch.
    public static let monitoring: [ClaudeCodeHookHandler] = [
        ClaudeCodeHookHandler(event: .userPromptSubmit, timeout: defaultTimeout),
        ClaudeCodeHookHandler(event: .preToolUse, timeout: defaultTimeout),
        ClaudeCodeHookHandler(event: .postToolUse, timeout: defaultTimeout),
        ClaudeCodeHookHandler(event: .postToolUseFailure, timeout: defaultTimeout),
        ClaudeCodeHookHandler(
            event: .notification,
            matcher: ClaudeCodeNotification.allCases
                .filter(\.meansBlockedOnHuman)
                .map(\.rawValue)
                .joined(separator: "|"),
            timeout: defaultTimeout),
        ClaudeCodeHookHandler(event: .subagentStart, timeout: defaultTimeout),
        ClaudeCodeHookHandler(event: .subagentStop, timeout: defaultTimeout),
        ClaudeCodeHookHandler(event: .stop, timeout: defaultTimeout),
        ClaudeCodeHookHandler(event: .stopFailure, timeout: defaultTimeout),
        ClaudeCodeHookHandler(event: .sessionEnd, timeout: sessionEndTimeout),
    ]
}

/// Where AgentBar's endpoint is, and what proves a caller is allowed to reach it.
///
/// A value rather than a reference to the running endpoint: the installer writes
/// a file, and it must be able to write the same file in a test with no socket
/// anywhere.
public struct ClaudeCodeEndpoint: Sendable, Hashable {
    /// The path every AgentBar hook URL ends with. Recognising our own entries
    /// keys off this rather than the whole URL, because the port ladder can move
    /// the port between installs.
    public static let path = IngestRoute.hooks(of: .claudeCode).path

    public let url: URL
    public let token: String

    public init(url: URL, token: String) {
        self.url = url
        self.token = token
    }

    /// Built from where the endpoint actually landed.
    ///
    /// `hookURLPrefix` carries the literal `127.0.0.1`: a name is the client's
    /// opinion, and a listener on `127.0.0.1` refuses `::1` outright.
    public init?(bound: BoundEndpoint, token: IngestToken) {
        guard let url = URL(string: "http://\(bound.host):\(bound.port)" + Self.path) else {
            return nil
        }
        self.init(url: url, token: token.value)
    }

    public var authorizationHeader: String { "Bearer \(token)" }

    /// Whether a URL found in `settings.json` is one AgentBar wrote.
    ///
    /// Matches on the path and a loopback host, never on the port: the ladder
    /// moves the port when something else holds 47821, and an entry left behind
    /// on the old port is precisely the one that has to be recognised in order
    /// to be repaired.
    public static func isAgentBarURL(_ text: String) -> Bool {
        guard let url = URL(string: text), url.path == path else { return false }
        guard let host = url.host() else { return false }
        return host == IngestConfiguration.host || host == "localhost" || host == "::1"
    }
}
