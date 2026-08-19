import AgentBarCore
import Foundation

/// What a decoder is told about the request its bytes came from.
public struct EventDecodingContext: Sendable {
    /// When the endpoint finished reading the request, and the only clock an
    /// event may be stamped from.
    ///
    /// Neither provider timestamps its hook payloads, and a stamp taken from a
    /// body would let a caller poison the store's high-water mark — one event
    /// dated in the future refuses every genuine event after it. Receipt time is
    /// both the best answer available and the only one that cannot be abused.
    public let receivedAt: Date
    public let transport: IngestTransport
    /// Resolves `cwd` into the project a session is grouped under. Injected so a
    /// layer allowed to read git metadata can supply a better answer than the
    /// path-only default.
    public let resolver: any ProjectResolving

    public init(receivedAt: Date, transport: IngestTransport, resolver: any ProjectResolving) {
        self.receivedAt = receivedAt
        self.transport = transport
        self.resolver = resolver
    }
}

/// Turns one provider's request body into domain events.
///
/// This is the boundary: everything a provider's payload looks like stops at an
/// implementation of this protocol, and everything above it sees `AgentEvent`.
/// A body that describes nothing AgentBar tracks decodes to no events rather
/// than to an error — an unrecognised event is not a fault.
public protocol EventDecoding: Sendable {
    func decode(_ body: Data, in context: EventDecodingContext) throws -> [AgentEvent]
}

/// Decodes a request body and applies what it finds to the store.
///
/// Always answers 200 with an empty body, whatever happens. A decoder that
/// refuses a payload is AgentBar's problem to fix, and reporting it as a hook
/// failure would put our bug in the user's transcript on a path where we are
/// supposed to be invisible. The reason survives as a diagnostic instead.
public struct EventIngestHandler: IngestHandling {
    private let store: SessionStore
    private let decoders: [IngestRoute: any EventDecoding]
    private let resolver: any ProjectResolving
    private let diagnostics: any IngestDiagnosticSink
    private let stateChanges: any StateChangeSink

    public init(
        store: SessionStore,
        decoders: [IngestRoute: any EventDecoding],
        resolver: any ProjectResolving = PathProjectResolver(),
        diagnostics: any IngestDiagnosticSink = SilentDiagnostics(),
        stateChanges: any StateChangeSink = UnobservedStateChanges()
    ) {
        self.store = store
        self.decoders = decoders
        self.resolver = resolver
        self.diagnostics = diagnostics
        self.stateChanges = stateChanges
    }

    public var routes: Set<IngestRoute> { Set(decoders.keys) }

    public func handle(_ request: IngestRequest) async -> IngestResponse {
        guard let decoder = decoders[request.route] else { return .noOpinion }
        let context = EventDecodingContext(
            receivedAt: request.receivedAt, transport: request.transport, resolver: resolver)
        do {
            let events = try decoder.decode(request.body, in: context)
            guard !events.isEmpty else { return .noOpinion }
            let outcomes = await store.apply(contentsOf: events)
            let ignored = outcomes.filter(\.wasIgnored).count
            diagnostics.record(
                .eventsAccepted(
                    path: request.route.path, applied: outcomes.count - ignored, ignored: ignored))
            // Reported after the diagnostic and before the response, so a slow
            // observer shows up as latency in the one place that measures it
            // rather than as a hook that timed out.
            let changes = outcomes.compactMap(\.change)
            if !changes.isEmpty { stateChanges.record(changes) }
        } catch {
            diagnostics.record(
                .payloadRejected(
                    path: request.route.path, reason: "\(error)", byteCount: request.body.count))
        }
        return .noOpinion
    }
}

extension ApplyOutcome {
    fileprivate var wasIgnored: Bool {
        guard case .ignored = self else { return false }
        return true
    }

    fileprivate var change: StateChange? {
        guard case .changed(let change) = self else { return nil }
        return change
    }
}
