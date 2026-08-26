import Foundation

/// A session's state moving, reported so the rest of the app can react to the
/// move rather than diff two snapshots.
///
/// Carries the provider and project as well as the states, because a
/// notification needs all four and looking them up afterwards would race with
/// the session having ended in the meantime.
public struct StateChange: Sendable, Hashable {
    public let sessionId: SessionID
    public let provider: Provider
    public let project: ProjectRef
    /// `nil` when this event registered the session.
    public let from: SessionState?
    /// `nil` when the session left the store.
    public let to: SessionState?
    /// When the store observed the change, for display only.
    public let at: Date

    public init(
        sessionId: SessionID,
        provider: Provider,
        project: ProjectRef,
        from: SessionState?,
        to: SessionState?,
        at: Date
    ) {
        self.sessionId = sessionId
        self.provider = provider
        self.project = project
        self.from = from
        self.to = to
        self.at = at
    }

    /// Whether this change is a turn coming to an end.
    ///
    /// `idle` and `failed` both are — one is the agent stopping, the other the
    /// turn failing, and work was done either way. `unknown` deliberately is
    /// **not**: the watchdog giving up says nothing about whether a turn
    /// finished, and a caller that treated it as one would act on every session
    /// that merely went quiet. A change with no `from` is a registration rather
    /// than a turn, so it is not one either.
    ///
    /// Provider-neutral on purpose. The Codex quota reading is the one caller
    /// today and it adds `provider == .codex` itself; the *rule* is about the
    /// domain, and it belongs where `swift test` can reach it.
    public var endsATurn: Bool {
        guard from != nil else { return false }
        switch to?.kind {
        case .idle, .failed: return true
        default: return false
        }
    }
}

/// What the store did with an event.
///
/// Every case is ordinary: an ignored event is a diagnostic, never a failure.
/// Duplicated and out-of-order deliveries are normal with asynchronous hooks,
/// and a provider whose hooks are installed twice produces nothing but
/// `duplicate`.
public enum ApplyOutcome: Sendable, Hashable {
    /// Applied, and the session's state moved.
    case changed(StateChange)
    /// Applied as a heartbeat; the state stayed where it was.
    case unchanged(SessionID)
    /// Not applied, and it left no trace. A delivery that says nothing new must
    /// not renew the watchdog either, or a session whose every event is refused
    /// would be believed for ever.
    case ignored(IgnoreReason)
}

/// Why an event did not change anything.
public enum IgnoreReason: String, Sendable, Hashable, CustomStringConvertible {
    /// Already seen: same session, same kind, same tool call.
    case duplicate
    /// Older than an event already applied to this session.
    case outOfOrder
    /// The session ended before this event was stamped.
    case sessionAlreadyEnded
    /// A terminal event for a session the store never saw start.
    case unknownSession
    /// Stamped implausibly far in the future. Both providers run on this
    /// machine, so this is a fault in the event, not clock skew — and honouring
    /// it would refuse every genuine event that followed.
    case implausibleTimestamp

    public var description: String { rawValue }
}
