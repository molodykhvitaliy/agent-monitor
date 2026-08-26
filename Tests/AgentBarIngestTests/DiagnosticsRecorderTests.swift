import AgentBarCore
import Foundation
import Testing

@testable import AgentBarIngest

/// The counters behind the diagnostics surface.
///
/// Every rejected request is answered with an empty 200 or a bare status, so
/// from outside the endpoint a refusal and silence are the same thing. These
/// counters are the only place the difference survives, which is why the count
/// itself is worth a suite.
@Suite("Ingest diagnostics recorder")
struct DiagnosticsRecorderTests {

    /// A sink that keeps what it was handed, so the decorator can be shown to
    /// forward rather than to swallow.
    private final class Collecting: IngestDiagnosticSink, @unchecked Sendable {
        private(set) var messages: [String] = []
        func record(_ diagnostic: IngestDiagnostic) { messages.append(diagnostic.message) }
    }

    @Test("Accepted events are counted in both halves")
    func acceptedEventsAreCounted() {
        var counters = IngestCounters()
        IngestDiagnosticsRecorder.count(
            .eventsAccepted(path: "/v1/hooks/claude-code", applied: 3, ignored: 1), into: &counters)
        IngestDiagnosticsRecorder.count(
            .eventsAccepted(path: "/v1/hooks/codex", applied: 2, ignored: 0), into: &counters)

        #expect(counters.deliveries == 2)
        #expect(counters.applied == 5)
        #expect(counters.ignored == 1)
    }

    /// The one this whole surface exists for: a payload an adapter could not
    /// decode is invisible to the agent that sent it, so it has to be visible
    /// here.
    @Test("A payload that could not be decoded is counted")
    func rejectedPayloadsAreCounted() {
        var counters = IngestCounters()
        IngestDiagnosticsRecorder.count(
            .payloadRejected(path: "/v1/hooks/codex", reason: "unknown event", byteCount: 42),
            into: &counters)
        #expect(counters.rejected == 1)
    }

    /// A key path would be the natural argument here and is not `Sendable`, so
    /// the counter is named and read through a switch instead.
    enum Counted: String, Sendable {
        case unauthorized
        case malformed
        case unroutable
        case handlerTimeouts
        case transportFailures
        case connectionsRefused

        func value(in counters: IngestCounters) -> Int {
            switch self {
            case .unauthorized: counters.unauthorized
            case .malformed: counters.malformed
            case .unroutable: counters.unroutable
            case .handlerTimeouts: counters.handlerTimeouts
            case .transportFailures: counters.transportFailures
            case .connectionsRefused: counters.connectionsRefused
            }
        }
    }

    @Test(
        "Every way a request is turned away has a counter",
        arguments: [
            (
                IngestDiagnostic.unauthorized(
                    path: "/v1/events", transport: .loopback, reason: .tokenMismatch),
                Counted.unauthorized
            ),
            (.malformedRequest(.headTooLarge, transport: .loopback), .malformed),
            (.routeNotFound(path: "/nope", method: "POST"), .unroutable),
            (.methodNotAllowed(path: "/v1/events", method: "GET"), .unroutable),
            (.handlerTimedOut(path: "/v1/events"), .handlerTimeouts),
            (.transportFailure(reason: "broken pipe"), .transportFailures),
            (.connectionsAtCapacity(limit: 64), .connectionsRefused),
        ] as [(IngestDiagnostic, Counted)]
    )
    func refusalsAreCounted(diagnostic: IngestDiagnostic, counter: Counted) {
        var counters = IngestCounters()
        IngestDiagnosticsRecorder.count(diagnostic, into: &counters)
        #expect(counter.value(in: counters) == 1)
    }

    @Test("Lifecycle notices are kept but counted as nothing")
    func lifecycleIsNotACounter() {
        var counters = IngestCounters()
        IngestDiagnosticsRecorder.count(.started(port: 47821, socketPath: nil), into: &counters)
        IngestDiagnosticsRecorder.count(.portMoved(from: 47821, to: 47822), into: &counters)
        IngestDiagnosticsRecorder.count(.stopped, into: &counters)
        #expect(counters == IngestCounters())
    }

    /// A diagnostics buffer that grew with traffic would be a memory leak
    /// wearing a feature's clothes, on the path a busy day drives hardest.
    @Test("The log is bounded and newest-first")
    func theLogIsBounded() {
        let recorder = IngestDiagnosticsRecorder(forwardingTo: SilentDiagnostics(), limit: 3)
        for port in UInt16(1)...UInt16(10) {
            recorder.record(.portUnavailable(port))
        }
        let snapshot = recorder.snapshot()
        #expect(snapshot.recent.count == 3)
        #expect(snapshot.recent.first?.message.contains("port 10") == true)
        #expect(snapshot.recent.last?.message.contains("port 8") == true)
        // Every entry is still distinct, so a list keyed on the id cannot
        // collapse two of them into one row.
        #expect(Set(snapshot.recent.map(\.id)).count == 3)
    }

    /// A surface must not cost the unified log anything: the log is the only
    /// record that survives a crash.
    @Test("Everything is forwarded as well as counted")
    func nothingIsSwallowed() {
        let downstream = Collecting()
        let recorder = IngestDiagnosticsRecorder(forwardingTo: downstream)
        recorder.record(.stopped)
        recorder.record(.handlerTimedOut(path: "/v1/events"))
        #expect(downstream.messages.count == 2)
        #expect(recorder.snapshot().counters.handlerTimeouts == 1)
    }
}
