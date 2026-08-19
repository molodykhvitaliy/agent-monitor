/// Where a session stands.
///
/// The vocabulary is fixed by the design system — Working, Waiting, Idle,
/// Failed, Unknown — with `waiting` split in two because the domain must
/// distinguish a prompt the human answers in the agent's own UI from one
/// AgentBar could answer itself.
public enum SessionState: Sendable, Hashable {
    /// Registered and alive, with no turn in flight.
    case idle
    case working
    /// Blocked on the human, answered elsewhere. Carries the question when the
    /// agent asked one — see `EventKind.waitingInput` and ADR-0005.
    case waitingInput(question: String?)
    /// Blocked on a permission decision. Reachable and unused by the MVP; the
    /// Approve/Deny backlog item turns it on without reshaping anything.
    case waitingPermission(PermissionRequestRef)
    case failed(reason: String)
    /// Silent for longer than the watchdog tolerates. Never a resting place a
    /// session reaches on purpose — it means AgentBar has no opinion any more.
    case unknown

    /// The line the waiting row and the `Question` notification render, when
    /// the waiting path had one to give. `nil` in every other state.
    public var question: String? {
        guard case .waitingInput(let question) = self else { return nil }
        return question
    }

    public var kind: SessionStateKind {
        switch self {
        case .idle: .idle
        case .working: .working
        case .waitingInput, .waitingPermission: .waiting
        case .failed: .failed
        case .unknown: .unknown
        }
    }
}

/// `SessionState` without its payload: what the icon, the row shape and the
/// notification matrix key off.
public enum SessionStateKind: String, Sendable, Hashable, CaseIterable {
    case idle
    case working
    case waiting
    case failed
    case unknown

    /// Lower sorts first. The status-bar icon shows the single most urgent
    /// state present across every session, and the order is a design-system
    /// decision: Waiting → Failed → Working → Unknown → Idle.
    public var attentionRank: Int {
        switch self {
        case .waiting: 0
        case .failed: 1
        case .working: 2
        case .unknown: 3
        case .idle: 4
        }
    }
}
