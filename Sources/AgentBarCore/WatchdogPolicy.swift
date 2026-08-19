/// How long silence is tolerated before a session stops being believed.
///
/// A session that never leaves `working` is the failure this exists to prevent:
/// it keeps the Mac awake for ever and tells the user an agent is busy when its
/// process died an hour ago. The intervals differ by state because silence
/// means different things in each — and because a single tool call can
/// legitimately run for a very long time.
public struct WatchdogPolicy: Sendable, Hashable {
    /// Silence tolerated while working with no tool call open. A model can
    /// think and stream for minutes without touching a tool, so this is not
    /// tight; it is not loose either, because nothing else bounds a dead agent.
    public var workingTimeout: Duration

    /// Silence tolerated while a tool call is open. A single `Bash` running a
    /// test suite or a full `xcodebuild` emits nothing for tens of minutes.
    /// Calling that session `unknown` would drop the power assertion in the
    /// middle of the build and put the Mac to sleep under it — a worse failure
    /// than holding the assertion a while after an agent has died.
    public var openToolTimeout: Duration

    /// Silence tolerated while waiting on the human. The state stays true for
    /// as long as nobody answers, so this is generous; it still expires,
    /// because a killed terminal leaves the same silence as a coffee break and
    /// `waiting` is the loudest thing the menu-bar icon can show.
    public var waitingTimeout: Duration

    /// Silence tolerated by a session that is idle or failed. Nothing more is
    /// expected from it, so this only decides when to stop claiming it is there.
    public var restingTimeout: Duration

    /// How long an `unknown` session stays on the list before it is retired.
    /// Without it, every agent that died without a `sessionEnded` would
    /// accumulate in the panel for ever.
    public var evictionTimeout: Duration

    public init(
        workingTimeout: Duration,
        openToolTimeout: Duration,
        waitingTimeout: Duration,
        restingTimeout: Duration,
        evictionTimeout: Duration
    ) {
        self.workingTimeout = workingTimeout
        self.openToolTimeout = openToolTimeout
        self.waitingTimeout = waitingTimeout
        self.restingTimeout = restingTimeout
        self.evictionTimeout = evictionTimeout
    }

    public static let `default` = WatchdogPolicy(
        workingTimeout: .seconds(15 * 60),
        openToolTimeout: .seconds(60 * 60),
        waitingTimeout: .seconds(2 * 60 * 60),
        restingTimeout: .seconds(8 * 60 * 60),
        evictionTimeout: .seconds(60 * 60)
    )

    /// How long this session may stay silent before it stops being believed.
    ///
    /// `.unknown` is never a recorded state — the store derives it — so its
    /// entry exists only to keep the switch total. A waiting session's question
    /// line is deliberately not read here: a payload must not move an
    /// allowance (ADR-0005).
    public func silenceAllowance(for state: SessionState, hasOpenTool: Bool) -> Duration {
        switch state {
        case .working: hasOpenTool ? openToolTimeout : workingTimeout
        case .waitingInput, .waitingPermission: waitingTimeout
        case .idle, .failed: restingTimeout
        case .unknown: evictionTimeout
        }
    }

    /// What should happen to a session that last spoke `silence` ago.
    ///
    /// Silence is the only input, which is what makes the answer stable: the
    /// reading handed to the UI and the sweep that acts on it ask the same
    /// question of the same fact and cannot drift. It also means a sign of life
    /// undoes the decay by itself — there is no stored `unknown` to climb back
    /// out of.
    ///
    /// Both stages are answered at once, so a session silent long enough to
    /// pass through `unknown` and out the far side is retired in a single
    /// verdict rather than lingering for one more sweep. That is exactly what
    /// happens when the Mac wakes from a night's sleep.
    public func verdict(
        for state: SessionState, hasOpenTool: Bool, silence: Duration
    ) -> WatchdogVerdict {
        let allowance = silenceAllowance(for: state, hasOpenTool: hasOpenTool)
        guard silence >= allowance else { return .keep }
        return silence - allowance >= evictionTimeout ? .evict : .markUnknown
    }
}

/// What the watchdog concluded about one session.
public enum WatchdogVerdict: Sendable, Hashable {
    /// Believe the session as it stands.
    case keep
    /// It has gone quiet: it reads as `unknown`.
    case markUnknown
    /// It has read as `unknown` long enough to retire.
    case evict
}
