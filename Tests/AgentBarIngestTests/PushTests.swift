import Foundation
import Synchronization
import Testing

@testable import AgentBarCore
@testable import AgentBarIngest

/// The push leg the panel and the notifications hang off.
///
/// Before it existed the handler counted `apply()`'s outcomes for a diagnostic
/// and dropped them, so a session going `waiting` — the one thing AgentBar is
/// for — was visible only to whoever next took a snapshot.
@Suite("Ingest push")
struct IngestPushTests {
    private func handler(
        store: SessionStore, sink: any StateChangeSink
    ) -> EventIngestHandler {
        EventIngestHandler(
            store: store, decoders: [.events: NativeEventDecoder()], stateChanges: sink)
    }

    private func request(_ json: String) -> IngestRequest {
        IngestRequest(
            route: .events, query: nil, headers: HTTPHeaders(), body: Data(json.utf8),
            transport: .loopback, receivedAt: Date())
    }

    @Test("A state move reaches the observer without anyone taking a snapshot")
    func reportsChanges() async {
        let sink = CollectingStateChanges()
        let handler = handler(store: SessionStore(), sink: sink)

        _ = await handler.handle(request(EventPayload.json(kind: "waitingInput")))

        let changes = sink.recorded
        #expect(changes.count == 1)
        #expect(changes.first?.to == .waitingInput(question: nil))
        #expect(changes.first?.provider == .claudeCode)
        #expect(changes.first?.project.name == "agentbar")
    }

    @Test("A batch reports its moves in the order they happened")
    func reportsBatchInOrder() async {
        let sink = CollectingStateChanges()
        let handler = handler(store: SessionStore(), sink: sink)
        let batch =
            "[\(EventPayload.json(kind: "turnStarted")), "
            + "\(EventPayload.json(kind: "waitingInput"))]"

        _ = await handler.handle(request(batch))

        // One call carrying both, not two calls: an observer that has to
        // reassemble a request's moves would report a session twice.
        #expect(sink.calls == 1)
        #expect(sink.recorded.map(\.to) == [.working, .waitingInput(question: nil)])
    }

    /// A busy session emits `toolStarted` and `toolFinished` several times a
    /// second and stays `working` throughout. Reporting those would wake the
    /// status item, and step 07's notifications, for nothing.
    @Test("An event that moved nothing reports nothing")
    func staysQuietWhenNothingMoved() async {
        let sink = CollectingStateChanges()
        let store = SessionStore()
        let handler = handler(store: store, sink: sink)

        _ = await handler.handle(request(EventPayload.json(kind: "turnStarted")))
        let afterFirst = sink.calls
        _ = await handler.handle(
            request(EventPayload.json(kind: "toolStarted", extra: ["toolUseId": "\"t1\""])))

        #expect(afterFirst == 1)
        #expect(sink.calls == 1, "a heartbeat is not news")
    }

    @Test("A body that decodes to nothing reports nothing")
    func staysQuietOnAnEmptyBody() async {
        let sink = CollectingStateChanges()
        let handler = handler(store: SessionStore(), sink: sink)

        _ = await handler.handle(request(""))
        _ = await handler.handle(request("{ not json"))

        #expect(sink.calls == 0)
    }

    /// The handler must answer whatever an observer does, because the answer is
    /// a hook's response and a hook that fails shows up in the user's
    /// transcript — on a path where AgentBar is meant to be invisible.
    @Test("The response does not depend on the observer")
    func answersRegardless() async {
        let handler = handler(store: SessionStore(), sink: UnobservedStateChanges())
        let response = await handler.handle(request(EventPayload.json(kind: "waitingInput")))
        #expect(response.status == .ok)
        #expect(response.body.isEmpty)
    }
}

/// Records every batch it is handed, and how many times it was called.
final class CollectingStateChanges: StateChangeSink {
    private let batches = Mutex<[[StateChange]]>([])

    func record(_ changes: [StateChange]) {
        batches.withLock { $0.append(changes) }
    }

    var calls: Int { batches.withLock { $0.count } }
    var recorded: [StateChange] { batches.withLock { $0.flatMap(\.self) } }
}
