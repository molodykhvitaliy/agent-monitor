/// Identity of an event that could arrive twice.
///
/// Only tool calls get one. Everything else is idempotent by construction —
/// subagents are counted in a set, prompts and farewells are transitions — and
/// two genuine prompts in a row must not be mistaken for one delivered twice.
struct EventFingerprint: Hashable, Sendable {
    let sessionId: SessionID
    let kind: EventKindTag
    let identity: String
}

/// Remembers which events have already been seen.
///
/// Duplicates are not hypothetical. Hooks are delivered asynchronously and may
/// be retried, and AgentBar's own installer coexists with hooks the user
/// already had — a second registration of the same handler produces two
/// deliveries of every event. Bounded because a long session emits thousands.
struct DeduplicationLedger: Sendable {
    private var seen: Set<EventFingerprint> = []
    private var order: [EventFingerprint] = []
    private let capacity: Int

    init(capacity: Int = 512) {
        self.capacity = max(1, capacity)
    }

    /// Returns `false` when this fingerprint has been seen before.
    mutating func admit(_ fingerprint: EventFingerprint) -> Bool {
        guard seen.insert(fingerprint).inserted else { return false }
        order.append(fingerprint)
        guard order.count > capacity else { return true }
        seen.remove(order.removeFirst())
        return true
    }

    /// Called when a session leaves, so its fingerprints stop crowding out
    /// those of the sessions still running.
    mutating func forget(sessionId: SessionID) {
        guard seen.contains(where: { $0.sessionId == sessionId }) else { return }
        order.removeAll { $0.sessionId == sessionId }
        seen = Set(order)
    }
}
