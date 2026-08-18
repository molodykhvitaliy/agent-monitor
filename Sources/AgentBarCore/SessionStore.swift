import Foundation

/// The single source of truth for what every agent is doing.
///
/// An actor because it holds the only mutable state in the app: adapters are
/// value transformers and everything above consumes the immutable readings this
/// hands out.
///
/// It owns no timer. `sweep()` must be called by whoever owns the run loop —
/// nothing else retires a session whose agent died, and nothing else tells the
/// rest of the app that one has. A store nobody sweeps still reports every
/// session's state correctly, because `unknown` is derived from silence rather
/// than stored; what a missed sweep costs is the transitions and the retiring,
/// never a wrong state.
public actor SessionStore {
    /// The finished list doubles as the guard against a late event reviving a
    /// session that ended, so it cannot be switched off.
    static let minimumHistoryLimit = 32

    private let clock: any TimeSource
    private let watchdog: WatchdogPolicy
    private let historyLimit: Int

    private var records: [SessionID: SessionRecord] = [:]
    private var finished: [FinishedSession] = []
    private var ledger = DeduplicationLedger()

    public init(
        clock: any TimeSource = SystemTimeSource(),
        watchdog: WatchdogPolicy = .default,
        historyLimit: Int = 100
    ) {
        self.clock = clock
        self.watchdog = watchdog
        self.historyLimit = max(SessionStore.minimumHistoryLimit, historyLimit)
    }

    /// How far ahead of the store's own clock an event may be stamped.
    ///
    /// Both providers run on this machine and the adapters stamp on receipt, so
    /// a timestamp from the future is a fault, not skew. It is worth catching
    /// because `timestamp` is a high-water mark: one bad value would refuse
    /// every genuine event after it. Generous enough that a stamp taken a
    /// moment before this reading can never trip it.
    static let futureTolerance: TimeInterval = 5 * 60

    // MARK: - Ingesting events

    @discardableResult
    public func apply(_ event: AgentEvent) -> ApplyOutcome {
        let instant = clock.now
        guard event.timestamp <= clock.wallTime.addingTimeInterval(SessionStore.futureTolerance)
        else {
            return .ignored(.implausibleTimestamp)
        }
        guard let record = records[event.sessionId] else {
            return admit(event, at: instant)
        }
        if let fingerprint = fingerprint(for: event), !ledger.admit(fingerprint) {
            return .ignored(.duplicate)
        }
        guard isInOrder(event, for: record) else {
            return .ignored(.outOfOrder)
        }
        var updated = record
        updated.observe(event, at: instant)
        let disposition = transition(&updated, on: event)
        return commit(updated, previous: record.state, disposition: disposition)
    }

    @discardableResult
    public func apply(contentsOf events: [AgentEvent]) -> [ApplyOutcome] {
        events.map { apply($0) }
    }

    /// First event for a session the store does not know.
    ///
    /// Adopting it rather than waiting for a `sessionStarted` is what makes
    /// AgentBar useful when it launches while agents are already running. Only
    /// a farewell is refused: registering a session in order to remove it would
    /// be pure noise.
    private func admit(_ event: AgentEvent, at instant: MonotonicInstant) -> ApplyOutcome {
        guard !isAfterEnd(event) else { return .ignored(.sessionAlreadyEnded) }
        guard event.kind.tag != .sessionEnded else { return .ignored(.unknownSession) }
        if let fingerprint = fingerprint(for: event) { _ = ledger.admit(fingerprint) }
        var record = SessionRecord(admitting: event, at: instant)
        let disposition = transition(&record, on: event)
        return commit(record, previous: nil, disposition: disposition)
    }

    private func commit(
        _ record: SessionRecord, previous: SessionState?, disposition: Disposition
    ) -> ApplyOutcome {
        // What the rest of the app last heard, which is `unknown` if the
        // watchdog has already announced this session as quiet. Reporting the
        // recorded state instead would describe a move nobody saw begin.
        let observed = record.reportedUnknown ? SessionState.unknown : previous
        var settled = record
        settled.reportedUnknown = false

        switch disposition {
        case .keep:
            records[settled.id] = settled
            guard settled.state != observed else { return .unchanged(settled.id) }
            return .changed(change(settled, from: observed, to: settled.state))
        case .end:
            records[settled.id] = nil
            ledger.forget(sessionId: settled.id)
            // A session cannot have ended before the last event applied to it,
            // and this date is also the barrier a straggler is measured
            // against — taking the farewell's own stamp would leave the events
            // that outran it able to re-admit the session.
            remember(settled, endedAt: settled.lastEventAt, outcome: .ended)
            return .changed(change(settled, from: observed, to: nil))
        }
    }

    // MARK: - Admission guards

    /// Hooks are asynchronous, so a slow `PreToolUse` can land after the `Stop`
    /// that followed it; applying it would put a finished turn back to work.
    /// A session end is the exception — terminal, idempotent, and worth
    /// honouring late rather than leaving a ghost until the watchdog notices.
    /// It is still refused if it predates the session, which is how a resumed
    /// id survives its predecessor's farewell.
    private func isInOrder(_ event: AgentEvent, for record: SessionRecord) -> Bool {
        guard event.timestamp < record.lastEventAt else { return true }
        return event.kind.tag == .sessionEnded && event.timestamp >= record.startedAt
    }

    /// Claude Code reuses a session id when a session is resumed, so "this id
    /// ended" cannot mean "this id is finished for ever". A delivery stamped no
    /// later than the end is one of that session's own stragglers; anything
    /// newer is the session having come back.
    private func isAfterEnd(_ event: AgentEvent) -> Bool {
        guard let last = finished.last(where: { $0.sessionId == event.sessionId }) else {
            return false
        }
        return event.timestamp <= last.endedAt
    }

    /// Only tool calls are fingerprinted.
    ///
    /// Everything else is idempotent by construction — subagents are counted in
    /// a set, prompts and farewells are transitions — and fingerprinting an
    /// event whose id can legitimately recur would swallow the second one. What
    /// this buys is the diagnostic: a stream of `duplicate` outcomes is how a
    /// hook installed twice makes itself visible.
    private func fingerprint(for event: AgentEvent) -> EventFingerprint? {
        switch event.kind.tag {
        case .toolStarted, .toolFinished:
            guard let identity = event.toolUseId else { return nil }
            return EventFingerprint(
                sessionId: event.sessionId, kind: event.kind.tag, identity: identity.value)
        default:
            return nil
        }
    }

    // MARK: - Watchdog

    /// Applies the watchdog and reports what moved.
    ///
    /// The only thing this changes about a session's state is whether it has
    /// been announced as quiet; a session's reading is the same before and
    /// after. What a sweep really does is retire the sessions the watchdog has
    /// given up on, which is why it cannot be skipped for ever.
    @discardableResult
    public func sweep() -> [StateChange] {
        let instant = clock.now
        let changes = Array(records.keys).compactMap { retire($0, at: instant) }
        return changes.sorted { $0.sessionId < $1.sessionId }
    }

    private func retire(_ id: SessionID, at instant: MonotonicInstant) -> StateChange? {
        guard let record = records[id] else { return nil }
        switch verdict(for: record, at: instant) {
        case .keep:
            guard record.reportedUnknown else { return nil }
            records[id]?.reportedUnknown = false
            return change(record, from: .unknown, to: record.state)
        case .markUnknown:
            guard !record.reportedUnknown else { return nil }
            records[id]?.reportedUnknown = true
            return change(record, from: record.state, to: .unknown)
        case .evict:
            records[id] = nil
            ledger.forget(sessionId: id)
            // Dated when the session last spoke, not when the sweep noticed:
            // after an overnight sleep those are hours apart, and only the
            // first is true.
            remember(record, endedAt: record.lastEventAt, outcome: .lost)
            return change(record, from: record.reportedUnknown ? .unknown : record.state, to: nil)
        }
    }

    private func verdict(
        for record: SessionRecord, at instant: MonotonicInstant
    ) -> WatchdogVerdict {
        watchdog.verdict(
            for: record.state,
            hasOpenTool: record.hasOpenTool,
            silence: instant - record.lastInformedAt)
    }

    private func silenceAllowance(for record: SessionRecord) -> Duration {
        watchdog.silenceAllowance(for: record.state, hasOpenTool: record.hasOpenTool)
    }

    // MARK: - Reading

    public func snapshot() -> StoreSnapshot {
        let instant = clock.now
        var grouped: [ProjectID: [Session]] = [:]
        for record in records.values {
            let session = reading(of: record, at: instant)
            grouped[session.project.id, default: []].append(session)
        }
        return StoreSnapshot(
            takenAt: clock.wallTime,
            projects: grouped.values.compactMap(SessionStore.group),
            finished: Array(finished.reversed()))
    }

    /// One session as the UI sees it, with the watchdog applied on the way out.
    ///
    /// A session past the point of being retired still reads as `unknown` here
    /// rather than disappearing: removing it is the sweep's job, and a session
    /// that vanished without ever reaching the history would be a session
    /// nothing can account for.
    private func reading(of record: SessionRecord, at instant: MonotonicInstant) -> Session {
        let silence = instant - record.lastInformedAt
        var state = record.state
        var timeInState = instant - record.stateChangedAtInstant
        if verdict(for: record, at: instant) != .keep {
            state = .unknown
            timeInState = silence - silenceAllowance(for: record)
        }
        return Session(
            id: record.id,
            provider: record.provider,
            project: record.project,
            model: record.model,
            state: state,
            currentTool: state == .working ? record.currentTool : nil,
            activeSubagentCount: record.activeSubagents.count,
            startedAt: record.startedAt,
            lastEventAt: record.lastEventAt,
            uptime: instant - record.startedAtInstant,
            timeInState: timeInState,
            timeSinceLastEvent: silence)
    }

    private static func group(_ sessions: [Session]) -> ProjectGroup? {
        guard let first = sessions.first else { return nil }
        return ProjectGroup(project: first.project, sessions: sessions)
    }

    // MARK: - History

    private func remember(_ record: SessionRecord, endedAt: Date, outcome: FinishOutcome) {
        finished.append(
            FinishedSession(
                sessionId: record.id,
                provider: record.provider,
                project: record.project,
                startedAt: record.startedAt,
                endedAt: endedAt,
                finalState: record.state,
                outcome: outcome))
        guard finished.count > historyLimit else { return }
        finished.removeFirst(finished.count - historyLimit)
    }

    private func change(
        _ record: SessionRecord, from: SessionState?, to: SessionState?
    ) -> StateChange {
        StateChange(
            sessionId: record.id,
            provider: record.provider,
            project: record.project,
            from: from,
            to: to,
            at: clock.wallTime)
    }
}
