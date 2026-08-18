import Foundation

/// A session as the rest of the app sees it: an immutable reading taken at one
/// moment, with every duration already worked out.
///
/// Durations rather than timestamps because they are what the panel renders,
/// and because computing them here is the only way to guarantee they came from
/// the monotonic clock rather than from subtracting two `Date`s.
public struct Session: Sendable, Hashable, Identifiable {
    public let id: SessionID
    public let provider: Provider
    public let project: ProjectRef
    public let model: String?
    public let state: SessionState
    /// The tool the agent is running. Only ever set while working — a reading
    /// the store produces never carries one in any other state, and a fixture
    /// should not either.
    public let currentTool: ToolRef?
    public let activeSubagentCount: Int
    /// When the session was first seen. For display; the row's timer uses
    /// `uptime`.
    public let startedAt: Date
    /// The newest applied event's own timestamp — for showing when something
    /// last happened. Its measured counterpart is `timeSinceLastEvent`; the two
    /// describe the same moment, one in wall-clock terms and one in elapsed
    /// terms. Deliveries the store ignored are in neither.
    public let lastEventAt: Date
    public let uptime: Duration
    public let timeInState: Duration
    /// How long the session has been silent — what the `unknown` row explains.
    public let timeSinceLastEvent: Duration

    public init(
        id: SessionID,
        provider: Provider,
        project: ProjectRef,
        model: String?,
        state: SessionState,
        currentTool: ToolRef?,
        activeSubagentCount: Int,
        startedAt: Date,
        lastEventAt: Date,
        uptime: Duration,
        timeInState: Duration,
        timeSinceLastEvent: Duration
    ) {
        self.id = id
        self.provider = provider
        self.project = project
        self.model = model
        self.state = state
        self.currentTool = currentTool
        self.activeSubagentCount = activeSubagentCount
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
        self.uptime = uptime
        self.timeInState = timeInState
        self.timeSinceLastEvent = timeSinceLastEvent
    }
}

/// The sessions running in one project.
public struct ProjectGroup: Sendable, Hashable, Identifiable {
    public let project: ProjectRef
    public let sessions: [Session]

    /// Sessions are ordered oldest first, here rather than at the call site: a
    /// preview or a test fixture that ordered them differently would let the UI
    /// depend on an arrangement the store never produces.
    public init(project: ProjectRef, sessions: [Session]) {
        self.project = project
        self.sessions = sessions.sorted {
            ($0.startedAt, $0.id) < ($1.startedAt, $1.id)
        }
    }

    public var id: ProjectID { project.id }
}

/// A session that has left the list.
///
/// Kept so a dashboard can show what happened earlier without the store being
/// redesigned for it, and so a late event cannot revive a session that ended.
public struct FinishedSession: Sendable, Hashable {
    public let sessionId: SessionID
    public let provider: Provider
    public let project: ProjectRef
    public let startedAt: Date
    public let endedAt: Date
    /// The last state the session was actually seen in. A session the
    /// watchdog gave up on keeps the state it was in — `unknown` is what the
    /// panel showed, not what the session was doing.
    public let finalState: SessionState
    public let outcome: FinishOutcome

    public init(
        sessionId: SessionID,
        provider: Provider,
        project: ProjectRef,
        startedAt: Date,
        endedAt: Date,
        finalState: SessionState,
        outcome: FinishOutcome
    ) {
        self.sessionId = sessionId
        self.provider = provider
        self.project = project
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.finalState = finalState
        self.outcome = outcome
    }
}

/// Why a session left the list.
public enum FinishOutcome: String, Sendable, Hashable {
    /// The agent said so.
    case ended
    /// It went silent and the watchdog retired it.
    case lost
}

/// Everything the UI needs, as one immutable value.
public struct StoreSnapshot: Sendable, Hashable {
    public let takenAt: Date
    /// Ordered by project name, then by id, so the panel does not reshuffle
    /// itself between readings.
    public let projects: [ProjectGroup]
    /// Most recently finished first.
    public let finished: [FinishedSession]

    /// Groups are ordered by name for the same reason sessions are ordered
    /// inside them: a list that reorders itself under the cursor is worse than
    /// one that is not sorted by urgency, and the icon carries urgency instead.
    public init(takenAt: Date, projects: [ProjectGroup], finished: [FinishedSession] = []) {
        self.takenAt = takenAt
        self.projects = projects.sorted {
            ($0.project.name.lowercased(), $0.project.id)
                < ($1.project.name.lowercased(), $1.project.id)
        }
        self.finished = finished
    }

    public var sessions: [Session] { projects.flatMap(\.sessions) }

    public var isEmpty: Bool { projects.isEmpty }

    /// What the status-bar icon shows: the single most urgent state present.
    public var mostUrgentState: SessionStateKind? {
        sessions.map(\.state.kind).min { $0.attentionRank < $1.attentionRank }
    }

    /// Whether anything is worth keeping the Mac awake for.
    public var isAnyAgentWorking: Bool {
        sessions.contains { $0.state == .working }
    }

    /// How many sessions are waiting on the human, which the icon may render as
    /// a count when more than one.
    public var waitingSessionCount: Int {
        sessions.count { $0.state.kind == .waiting }
    }
}
