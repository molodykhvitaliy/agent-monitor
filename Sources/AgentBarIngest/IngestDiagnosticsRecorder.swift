import AgentBarCore
import Foundation
import Synchronization

/// What the endpoint has counted since it started.
///
/// One field per question a user asks when nothing is arriving, and no field
/// that would need explaining. `applied` and `ignored` are the two halves of
/// "did the events do anything", and the rest are the four ways a request can be
/// turned away with the caller none the wiser — which is the whole reason a
/// counter exists at all: every one of those answers the hook with an empty 200
/// or a bare status, so from outside they are indistinguishable from silence.
nonisolated public struct IngestCounters: Sendable, Hashable {
    public var deliveries = 0
    public var applied = 0
    public var ignored = 0
    /// A payload that reached the handler and could not be decoded. This is the
    /// adapter parse failure the step asks to be visible rather than swallowed.
    public var rejected = 0
    public var unauthorized = 0
    public var malformed = 0
    public var unroutable = 0
    public var handlerTimeouts = 0
    public var transportFailures = 0
    public var connectionsRefused = 0

    public init() {}
}

/// One thing the endpoint said, kept so a surface can show it.
nonisolated public struct IngestDiagnosticEntry: Sendable, Hashable, Identifiable {
    public let id: Int
    public let at: Date
    public let severity: IngestDiagnostic.Severity
    public let message: String

    public init(id: Int, at: Date, severity: IngestDiagnostic.Severity, message: String) {
        self.id = id
        self.at = at
        self.severity = severity
        self.message = message
    }
}

/// Everything the recorder holds, as one value.
nonisolated public struct IngestDiagnosticsSnapshot: Sendable, Hashable {
    public let counters: IngestCounters
    /// Most recent first.
    public let recent: [IngestDiagnosticEntry]

    public init(counters: IngestCounters, recent: [IngestDiagnosticEntry]) {
        self.counters = counters
        self.recent = recent
    }
}

/// Counts diagnostics and keeps the last few, on the way to wherever they were
/// already going.
///
/// > **A decorator, never a replacement.** It forwards every diagnostic to the
/// > sink it wraps — `SystemDiagnostics` in the app — so adding a surface does
/// > not take anything out of the unified log, which is still the only record
/// > that survives a crash.
///
/// > **Bounded, like everything else the endpoint holds.** `limit` entries and
/// > no more; the oldest goes when the newest arrives. A diagnostics buffer that
/// > grew with traffic would be a memory leak wearing a feature's clothes, on
/// > the one path a busy day drives hardest.
///
/// A `Mutex` rather than an actor: `IngestDiagnosticSink.record` is synchronous
/// and is called from inside connection handling, where a suspension point would
/// change the order things happen in for the sake of a counter.
nonisolated public final class IngestDiagnosticsRecorder: IngestDiagnosticSink {
    /// How many entries are kept. Enough to cover a burst of hook traffic and
    /// still fit on a screen once filtered.
    public static let defaultLimit = 100

    private struct State {
        var counters = IngestCounters()
        var recent: [IngestDiagnosticEntry] = []
        var nextID = 0
    }

    private let state = Mutex(State())
    private let forward: any IngestDiagnosticSink
    private let limit: Int
    private let clock: any TimeSource

    public init(
        forwardingTo forward: any IngestDiagnosticSink = SystemDiagnostics(),
        limit: Int = IngestDiagnosticsRecorder.defaultLimit,
        clock: any TimeSource = SystemTimeSource()
    ) {
        self.forward = forward
        self.limit = max(1, limit)
        self.clock = clock
    }

    public func record(_ diagnostic: IngestDiagnostic) {
        let now = clock.wallTime
        state.withLock { state in
            Self.count(diagnostic, into: &state.counters)
            state.recent.append(
                IngestDiagnosticEntry(
                    id: state.nextID, at: now, severity: diagnostic.severity,
                    message: diagnostic.message))
            state.nextID += 1
            if state.recent.count > limit {
                state.recent.removeFirst(state.recent.count - limit)
            }
        }
        forward.record(diagnostic)
    }

    public func snapshot() -> IngestDiagnosticsSnapshot {
        state.withLock { state in
            IngestDiagnosticsSnapshot(
                counters: state.counters, recent: state.recent.reversed())
        }
    }

    /// The whole of the counting, as a pure function so it can be tested
    /// without a recorder.
    ///
    /// Every case is written out. A `default` would silently stop counting a
    /// case added later — which is the failure mode a diagnostics surface can
    /// least afford, because nothing about the interface would look wrong.
    static func count(_ diagnostic: IngestDiagnostic, into counters: inout IngestCounters) {
        switch diagnostic {
        case .eventsAccepted(_, let applied, let ignored):
            counters.deliveries += 1
            counters.applied += applied
            counters.ignored += ignored
        case .payloadRejected:
            counters.rejected += 1
        case .unauthorized:
            counters.unauthorized += 1
        case .malformedRequest:
            counters.malformed += 1
        case .routeNotFound, .methodNotAllowed:
            counters.unroutable += 1
        case .handlerTimedOut:
            counters.handlerTimeouts += 1
        case .transportFailure:
            counters.transportFailures += 1
        case .connectionsAtCapacity:
            counters.connectionsRefused += 1
        case .started, .stopped, .portUnavailable, .portMoved, .staleSocketRemoved,
            .unixSocketUnavailable, .credentialReplaced, .credentialPermissionsTightened:
            break
        }
    }
}
