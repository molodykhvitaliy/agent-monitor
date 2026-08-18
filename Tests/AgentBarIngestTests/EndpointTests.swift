import Foundation
import Network
import Synchronization
import Testing

@testable import AgentBarCore
@testable import AgentBarIngest

@Suite("Loopback endpoint", .serialized)
struct EndpointTests {

    /// The step's headline: a synthetic POST becomes a session the rest of the
    /// app can see.
    @Test("A posted event becomes a session in the store")
    func createsSession() async throws {
        try await EndpointFactory.withEndpoint { harness in
            let response = try await harness.post(
                token: harness.token, body: EventPayload.json(kind: "turnStarted"))
            #expect(response.status == 200)
            #expect(response.body.isEmpty)

            let snapshot = await harness.store.snapshot()
            let session = try #require(snapshot.sessions.first)
            #expect(snapshot.sessions.count == 1)
            #expect(session.id == SessionID("session-1"))
            #expect(session.state == .working)
            #expect(session.provider == .claudeCode)
            #expect(session.project.name == "agentbar")
        }
    }

    @Test("An unauthenticated request is refused without reaching the store")
    func refusesUnauthenticated() async throws {
        try await EndpointFactory.withEndpoint { harness in
            let missing = try await harness.post(
                token: nil, body: EventPayload.json(kind: "turnStarted"))
            #expect(missing.status == 401)
            #expect(missing.body.isEmpty)

            let wrong = try await harness.post(
                token: "not-the-token-not-the-token", body: EventPayload.json(kind: "turnStarted"))
            #expect(wrong.status == 401)

            let snapshot = await harness.store.snapshot()
            #expect(snapshot.sessions.isEmpty)
        }
    }

    /// A body we cannot read is our problem, not the agent's. Claude Code reads
    /// 2xx-with-an-empty-body as "the hook had nothing to say"; anything else
    /// would report our bug inside the user's tool call.
    @Test(
        "A body that cannot be decoded is answered with an empty 200",
        arguments: [
            "{", "null", #"{"provider": "nope", "sessionId": "s", "kind": "x", "cwd": "/"}"#,
        ]
    )
    func degradesOnMalformedBody(body: String) async throws {
        try await EndpointFactory.withEndpoint { harness in
            let response = try await harness.post(token: harness.token, body: body)
            #expect(response.status == 200)
            #expect(response.body.isEmpty)

            let snapshot = await harness.store.snapshot()
            #expect(snapshot.sessions.isEmpty)
            #expect(
                harness.diagnostics.contains {
                    if case .payloadRejected = $0 { return true }
                    return false
                })
        }
    }

    @Test("An unknown route is refused and a wrong method is distinguished")
    func refusesUnknownRoutes() async throws {
        try await EndpointFactory.withEndpoint { harness in
            let unknown = try await harness.post(
                path: "/v1/hooks/nobody", token: harness.token, body: "{}")
            #expect(unknown.status == 404)

            let client = try harness.client()
            try await client.open()
            defer { client.close() }
            try await client.write(
                TestHTTPClient.request(
                    method: "DELETE", path: IngestRoute.events.path, token: harness.token,
                    keepAlive: false))
            #expect(try await client.readResponse().status == 405)
        }
    }

    @Test("Health answers when authenticated and refuses when not")
    func answersHealth() async throws {
        try await EndpointFactory.withEndpoint { harness in
            let client = try harness.client()
            try await client.open()
            defer { client.close() }
            try await client.write(
                TestHTTPClient.request(
                    method: "GET", path: IngestRoute.health.path, token: harness.token))
            #expect(try await client.readResponse().status == 200)
            try await client.write(
                TestHTTPClient.request(
                    method: "GET", path: IngestRoute.health.path, token: nil, keepAlive: false))
            #expect(try await client.readResponse().status == 401)
        }
    }

    @Test("The Unix socket speaks the same protocol as the port")
    func servesUnixSocket() async throws {
        try await EndpointFactory.withEndpoint { harness in
            let socketPath = try #require(harness.bound.socketPath).path(percentEncoded: false)
            let client = TestHTTPClient.unixSocket(path: socketPath)
            try await client.open()
            defer { client.close() }
            try await client.write(
                TestHTTPClient.request(
                    path: IngestRoute.events.path, token: harness.token,
                    body: EventPayload.json(kind: "turnStarted", session: "over-socket"),
                    keepAlive: false))
            #expect(try await client.readResponse().status == 200)

            let snapshot = await harness.store.snapshot()
            #expect(snapshot.session("over-socket")?.state == .working)
        }
    }

    /// A socket anyone on the machine could connect to would be an
    /// unauthenticated path into the store if the token were ever relaxed.
    @Test("The socket is readable only by its owner, in a directory to match")
    func protectsSocket() async throws {
        try await EndpointFactory.withEndpoint { harness in
            let socket = try #require(harness.bound.socketPath)
            #expect(harness.directory.mode(of: socket) == 0o600)
            #expect(harness.directory.mode(of: harness.paths.directory) == 0o700)
        }
    }

    @Test("Several sessions posting at the same time all arrive")
    func handlesConcurrentSessions() async throws {
        try await EndpointFactory.withEndpoint { harness in
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<12 {
                    group.addTask {
                        let body = EventPayload.json(
                            kind: "turnStarted", session: "session-\(index)",
                            cwd: "/Users/dev/project-\(index % 3)")
                        _ = try? await harness.post(token: harness.token, body: body)
                    }
                }
            }
            let snapshot = await harness.store.snapshot()
            #expect(snapshot.sessions.count == 12)
            #expect(snapshot.projects.count == 3)
        }
    }

    /// A hook fires on every tool call, so a handshake per event would be a
    /// measurable cost on the one path that has to stay invisible.
    @Test("One connection carries many requests")
    func keepsConnectionAlive() async throws {
        try await EndpointFactory.withEndpoint { harness in
            let client = try harness.client()
            try await client.open()
            defer { client.close() }
            for index in 0..<25 {
                try await client.write(
                    TestHTTPClient.request(
                        path: IngestRoute.events.path, token: harness.token,
                        body: EventPayload.json(
                            kind: "toolStarted", session: "long-lived",
                            extra: [
                                "tool": #"{"name": "Bash"}"#, "toolUseId": "\"tool-\(index)\"",
                            ])))
                let response = try await client.readResponse()
                #expect(response.status == 200)
                #expect(response.headers["connection"] == "keep-alive")
            }
            let snapshot = await harness.store.snapshot()
            #expect(snapshot.session("long-lived")?.state == .working)
        }
    }

    @Test("A body past the limit is refused rather than buffered")
    func refusesOversizedBody() async throws {
        let limits = IngestLimits(maximumBodyBytes: 1024)
        try await EndpointFactory.withEndpoint(limits: limits) { harness in
            let client = try harness.client()
            try await client.open()
            defer { client.close() }
            try await client.write(
                "POST \(IngestRoute.events.path) HTTP/1.1\r\n"
                    + "Authorization: Bearer \(harness.token)\r\n"
                    + "Content-Length: 2048\r\n\r\n")
            #expect(try await client.readResponse().status == 413)
        }
    }

    @Test("A malformed request is answered and the connection closed")
    func refusesMalformedRequest() async throws {
        try await EndpointFactory.withEndpoint { harness in
            let client = try harness.client()
            try await client.open()
            defer { client.close() }
            try await client.write("POST /v1/events HTTP/9.9\r\n\r\n")
            let response = try await client.readResponse()
            #expect(response.status == 400)
            #expect(response.headers["connection"] == "close")
        }
    }

    /// A client that waits to be told to go ahead and never is stalls until its
    /// own timeout — inside an agent's tool call, caused by us.
    @Test("A client expecting 100-continue is told to proceed")
    func answersExpectContinue() async throws {
        try await EndpointFactory.withEndpoint { harness in
            let client = try harness.client()
            try await client.open()
            defer { client.close() }
            let body = EventPayload.json(kind: "turnStarted", session: "polite")
            try await client.write(
                "POST \(IngestRoute.events.path) HTTP/1.1\r\n"
                    + "Authorization: Bearer \(harness.token)\r\n"
                    + "Expect: 100-continue\r\n"
                    + "Content-Length: \(body.utf8.count)\r\n\r\n")
            try await Task.sleep(for: .milliseconds(100))
            try await client.write(body)
            #expect(try await client.readResponse().status == 200)
            let snapshot = await harness.store.snapshot()
            #expect(snapshot.session("polite") != nil)
        }
    }

    /// ADR-0002 rests on this being literally true, so it is asserted against a
    /// live listener rather than against the code that configures one.
    @Test("The endpoint answers on 127.0.0.1 and nowhere else")
    func bindsLoopbackOnly() async throws {
        try await EndpointFactory.withEndpoint { harness in
            guard let address = EndpointFactory.nonLoopbackAddress() else { return }
            let outside = try TestHTTPClient.host(address, port: harness.bound.port)
            await #expect(throws: (any Error).self) { try await outside.open() }
            outside.close()
        }
    }
}

/// Occupies a port so the ladder has something to climb over.
struct BlockingListener {
    private let listener: NWListener

    static func bind(port: UInt16) async throws -> BlockingListener {
        let parameters = NWParameters.tcp
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw TestHTTPClient.ClientError.invalidPort(port)
        }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { $0.cancel() }
        try await withCheckedThrowingContinuation { (continuation: VoidContinuation) in
            let box = Mutex<VoidContinuation?>(continuation)
            let settle: @Sendable ((any Error)?) -> Void = { error in
                let pending = box.withLock { current -> VoidContinuation? in
                    defer { current = nil }
                    return current
                }
                guard let pending else { return }
                if let error {
                    pending.resume(throwing: error)
                } else {
                    pending.resume()
                }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: settle(nil)
                case .failed(let error), .waiting(let error): settle(error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "blocker"))
        }
        return BlockingListener(listener: listener)
    }

    func cancel() {
        listener.cancel()
    }
}
