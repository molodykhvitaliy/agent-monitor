import Foundation

/// Something an agent did, translated out of a provider's vocabulary.
///
/// Adapters build these; nothing above the adapter layer sees the payload they
/// were decoded from. An event is a statement of fact about a moment, not a
/// command: what it does to a session is `SessionStore`'s decision.
public struct AgentEvent: Sendable, Hashable {
    public let provider: Provider
    public let sessionId: SessionID
    public let turnId: TurnID?
    /// Where the agent is working. May be deeper than `project.root`.
    public let cwd: URL
    public let project: ProjectRef
    public let model: String?
    public let kind: EventKind
    public let tool: ToolRef?
    /// Pairs a tool's start with its finish, and the key duplicates are caught by.
    public let toolUseId: ToolUseID?
    public let agent: AgentRef
    /// When the event happened, as the adapter understood it. Used for ordering
    /// and for display; never for measuring an interval — see `TimeSource`.
    public let timestamp: Date
    public let raw: RawPayload

    public init(
        provider: Provider,
        sessionId: SessionID,
        kind: EventKind,
        cwd: URL,
        project: ProjectRef,
        timestamp: Date,
        turnId: TurnID? = nil,
        model: String? = nil,
        tool: ToolRef? = nil,
        toolUseId: ToolUseID? = nil,
        agent: AgentRef = .main,
        raw: RawPayload = .empty
    ) {
        self.provider = provider
        self.sessionId = sessionId
        self.kind = kind
        self.cwd = cwd
        self.project = project
        self.timestamp = timestamp
        self.turnId = turnId
        self.model = model
        self.tool = tool
        self.toolUseId = toolUseId
        self.agent = agent
        self.raw = raw
    }

    /// Convenience for the common case: derive the project from `cwd`.
    ///
    /// An adapter with a better resolver — one allowed to read git metadata —
    /// passes it in; the default is the path-only answer.
    public init(
        provider: Provider,
        sessionId: SessionID,
        kind: EventKind,
        cwd: URL,
        timestamp: Date,
        resolver: any ProjectResolving = PathProjectResolver(),
        turnId: TurnID? = nil,
        model: String? = nil,
        tool: ToolRef? = nil,
        toolUseId: ToolUseID? = nil,
        agent: AgentRef = .main,
        raw: RawPayload = .empty
    ) {
        self.init(
            provider: provider,
            sessionId: sessionId,
            kind: kind,
            cwd: cwd,
            project: resolver.project(for: cwd),
            timestamp: timestamp,
            turnId: turnId,
            model: model,
            tool: tool,
            toolUseId: toolUseId,
            agent: agent,
            raw: raw
        )
    }
}

/// What happened, in provider-neutral terms.
///
/// The names describe the fact, not the resulting state: `turnStarted` is a
/// prompt being submitted, and it is `SessionStore` that decides this means the
/// session is now working.
public enum EventKind: Sendable, Hashable {
    /// The agent announced a session. Also fires on resume, clear, compact and
    /// fork, so it must never be read as "a brand new session".
    case sessionStarted
    /// The user gave the agent work.
    case turnStarted
    /// A tool call began — the heartbeat that arrives most often.
    case toolStarted
    /// A tool call returned.
    case toolFinished
    case subagentStarted
    case subagentStopped
    /// The agent is blocked on the human by a question it asked.
    ///
    /// The line is what the agent asked, already bounded and redacted by the
    /// adapter — the same contract `ToolRef.invocation` meets, and produced by
    /// the same machinery. `nil` on every waiting path that has no specific
    /// question to show (ADR-0005).
    ///
    /// It is a display value. Nothing above the adapter may branch on it and no
    /// transition may depend on whether it is there.
    case waitingInput(question: String?)
    /// The agent is blocked on a permission decision in the provider's UI.
    /// AgentBar observes this state but cannot answer it.
    case waitingPermission(PermissionRequestRef)
    /// The turn ended normally.
    case turnFinished
    /// The turn died, typically on an API error.
    case failed(reason: String)
    /// The session is over and should leave the list.
    case sessionEnded
}

/// `EventKind` without its payload.
///
/// Duplicate detection and logging need to compare and count kinds, and neither
/// should have to care what a case carries.
public enum EventKindTag: String, Sendable, Hashable, CaseIterable {
    case sessionStarted
    case turnStarted
    case toolStarted
    case toolFinished
    case subagentStarted
    case subagentStopped
    case waitingInput
    case waitingPermission
    case turnFinished
    case failed
    case sessionEnded
}

extension EventKind {
    public var tag: EventKindTag {
        switch self {
        case .sessionStarted: .sessionStarted
        case .turnStarted: .turnStarted
        case .toolStarted: .toolStarted
        case .toolFinished: .toolFinished
        case .subagentStarted: .subagentStarted
        case .subagentStopped: .subagentStopped
        case .waitingInput: .waitingInput
        case .waitingPermission: .waitingPermission
        case .turnFinished: .turnFinished
        case .failed: .failed
        case .sessionEnded: .sessionEnded
        }
    }
}

/// The tool a session is running.
public struct ToolRef: Sendable, Hashable {
    /// The provider's own name for the tool, such as `Bash` or `Edit`.
    public let name: String
    /// One line describing the call, already shortened and redacted by the
    /// adapter. The session row renders it verbatim in monospace.
    public let invocation: String?

    public init(name: String, invocation: String? = nil) {
        self.name = name
        self.invocation = invocation
    }
}

/// Who inside a session an event belongs to.
public enum AgentRef: Sendable, Hashable {
    /// The session's own thread. Claude Code sends no agent fields here, which
    /// is exactly how a main-thread event is recognised.
    case main
    case subagent(id: AgentID, type: String?)

    public var subagentId: AgentID? {
        guard case .subagent(let id, _) = self else { return nil }
        return id
    }
}

/// A permission decision the agent is waiting for in the provider's UI.
/// The id is local state identity, not necessarily a provider reply handle.
public struct PermissionRequestRef: Sendable, Hashable {
    public let id: PermissionRequestID
    /// One line naming what is being asked for.
    public let summary: String?

    public init(id: PermissionRequestID, summary: String? = nil) {
        self.id = id
        self.summary = summary
    }
}

/// What survives of the payload an event was decoded from.
///
/// Deliberately opaque. Raw provider JSON must not cross the adapter boundary,
/// and a domain that can read a payload will eventually branch on one. Only a
/// bounded, human-readable line survives, which is enough to explain a stuck
/// session in a log and not enough to become a second source of truth.
public struct RawPayload: Sendable, Hashable {
    public static let empty = RawPayload(summary: "")

    /// A payload can carry an entire file in `tool_input`. Events are held for
    /// as long as their session is, so the residue has to be bounded.
    public static let summaryLimit = 512

    private let summary: String

    public init(summary: String) {
        self.summary = String(summary.prefix(RawPayload.summaryLimit))
    }

    public var diagnosticSummary: String { summary }
    public var isEmpty: Bool { summary.isEmpty }
}
