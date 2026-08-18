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
