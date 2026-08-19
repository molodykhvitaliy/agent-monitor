import AgentBarCore
import AgentBarIngest
import Darwin
import Foundation
import Testing

@testable import CodexAdapter

/// The helper's half of the integration: bytes in on stdin, one POST out.
///
/// The suite runs the relay against a **live endpoint** rather than a stub. The
/// helper is the one piece of AgentBar that runs inside somebody else's process
/// tree with a millisecond budget, and a test that mocked the socket would prove
/// nothing about the part that can actually fail.
@Suite("Codex helper relay")
struct RelayTests {

    /// An endpoint with a real store behind it and the Codex decoder registered.
    struct LiveEndpoint {
        let directory: URL
        let paths: IngestPaths
        let store: SessionStore
        let service: IngestService
        let bound: BoundEndpoint

        static func start(withSocket: Bool = true) async throws -> LiveEndpoint {
            // Short on purpose. A Unix socket path is capped at 103 bytes and
            // the per-user temporary directory already spends about fifty of
            // them, so a full UUID here would leave the endpoint unable to bind
            // the socket this suite exists to exercise.
            let unique = UUID().uuidString.prefix(8).lowercased()
            let directory = URL(filePath: NSTemporaryDirectory())
                .appending(path: "agentbar-\(unique)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let paths = IngestPaths(directory: directory)
            let store = SessionStore()
            let service = IngestService(
                paths: paths,
                store: store,
                configuration: IngestConfiguration(
                    preferredPort: UInt16.random(in: 40000...44000),
                    portAttempts: 32,
                    socketPath: withSocket ? paths.socketURL : nil),
                decoders: [CodexEventDecoder.route: CodexEventDecoder()])
            let bound = try await service.start()
            return LiveEndpoint(
                directory: directory, paths: paths, store: store, service: service, bound: bound)
        }

        func relay(timeouts: RelayTimeouts = RelayTimeouts()) -> CodexHelperRelay {
            CodexHelperRelay(discoveryURL: paths.discoveryURL, timeouts: timeouts)
        }

        func tearDown() async {
            await service.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func withEndpoint(
        withSocket: Bool = true, _ body: (LiveEndpoint) async throws -> Void
    ) async throws {
        let endpoint = try await LiveEndpoint.start(withSocket: withSocket)
        do {
            try await body(endpoint)
        } catch {
            await endpoint.tearDown()
            throw error
        }
        await endpoint.tearDown()
    }

    // MARK: - Delivery

    @Test("A payload relayed over the Unix socket reaches the store")
    func deliversOverUnixSocket() async throws {
        try await Self.withEndpoint { endpoint in
            #expect(endpoint.bound.socketPath != nil)
            let outcome = endpoint.relay().relay(try Fixtures.data("user-prompt-submit"))
            #expect(outcome == .delivered(status: 200))

            let snapshot = await endpoint.store.snapshot()
            let session = try #require(snapshot.sessions.first)
            #expect(session.provider == .codex)
            #expect(session.state == .working)
            #expect(session.project.name == "probe")
        }
    }

    @Test("An endpoint with no Unix socket is still reached on the port")
    func fallsBackToTheLoopbackPort() async throws {
        try await Self.withEndpoint(withSocket: false) { endpoint in
            #expect(endpoint.bound.socketPath == nil)
            let outcome = endpoint.relay().relay(try Fixtures.data("session-start"))
            #expect(outcome == .delivered(status: 200))
            #expect(await endpoint.store.snapshot().sessions.count == 1)
        }
    }

    @Test("A whole session relayed one payload at a time drives the store")
    func replaysASession() async throws {
        try await Self.withEndpoint { endpoint in
            let relay = endpoint.relay()
            for payload in try Fixtures.session("session-with-tools").dropLast() {
                #expect(relay.relay(payload) == .delivered(status: 200))
            }
            let beforeEnd = await endpoint.store.snapshot()
            #expect(beforeEnd.sessions.count == 1)
            #expect(beforeEnd.sessions.first?.state == .idle)

            // `SessionEnd` retires it, which is the path Codex only ever takes
            // on the main thread — it does not fire for subagents.
            let end = try #require(try Fixtures.session("session-with-tools").last)
            #expect(relay.relay(end) == .delivered(status: 200))
            #expect(await endpoint.store.snapshot().sessions.isEmpty)
        }
    }

    @Test("A subagent's events are counted against the session that spawned it")
    func countsSubagents() async throws {
        try await Self.withEndpoint { endpoint in
            let relay = endpoint.relay()
            let payloads = try Fixtures.session("session-with-subagent")
            // Up to and including `SubagentStart`.
            for payload in payloads.prefix(3) { _ = relay.relay(payload) }
            let running = try #require(await endpoint.store.snapshot().sessions.first)
            #expect(running.activeSubagentCount == 1)

            for payload in payloads.dropFirst(3) { _ = relay.relay(payload) }
            let finished = try #require(await endpoint.store.snapshot().sessions.first)
            // `SessionEnd` does not fire for a subagent, so `SubagentStop` is the
            // only thing that can close one — and it has to be enough.
            #expect(finished.activeSubagentCount == 0)
            #expect(finished.state == .idle)
        }
    }

    // MARK: - The request itself

    @Test("The request is the one the endpoint expects, byte for byte")
    func buildsTheRequest() throws {
        let token = try #require(IngestToken("0123456789abcdef0123456789abcdef"))
        let request = CodexHelperRelay.request(
            payload: Data(#"{"a":1}"#.utf8), token: token, host: "127.0.0.1", port: 47821)
        let text = try #require(String(data: request, encoding: .utf8))
        #expect(text.hasPrefix("POST /v1/hooks/codex HTTP/1.1\r\n"))
        #expect(text.contains("Host: 127.0.0.1:47821\r\n"))
        #expect(text.contains("Authorization: Bearer \(token.value)\r\n"))
        #expect(text.contains("Content-Type: application/json\r\n"))
        #expect(text.contains("Content-Length: 7\r\n"))
        // No second request follows: the process is about to end.
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{\"a\":1}"))
    }

    @Test("The Unix socket is tried first and the port is the fallback")
    func prefersTheUnixSocket() {
        let withSocket = EndpointDescriptor(
            port: 47821, socketPath: "/tmp/ingest.sock", tokenPath: "/tmp/token",
            processIdentifier: 1, startedAt: Date())
        #expect(
            CodexHelperRelay.destinations(for: withSocket) == [
                .unixSocket(path: "/tmp/ingest.sock"),
                .loopback(host: "127.0.0.1", port: 47821),
            ])

        let withoutSocket = EndpointDescriptor(
            port: 47821, socketPath: nil, tokenPath: "/tmp/token", processIdentifier: 1,
            startedAt: Date())
        #expect(
            CodexHelperRelay.destinations(for: withoutSocket) == [
                .loopback(host: "127.0.0.1", port: 47821)
            ])
    }

    @Test("A status line is read for the diagnostic, and anything else is not guessed at")
    func readsTheStatus() {
        #expect(CodexHelperRelay.status(of: Data("HTTP/1.1 200 OK\r\n\r\n".utf8)) == 200)
        #expect(CodexHelperRelay.status(of: Data("HTTP/1.1 401 Unauthorized\r\n".utf8)) == 401)
        #expect(CodexHelperRelay.status(of: Data()) == nil)
        #expect(CodexHelperRelay.status(of: Data("nonsense".utf8)) == nil)
    }

    // MARK: - Standard input

    @Test("Standard input is drained to the end even past the size that will be relayed")
    func drainsStandardInput() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        let (readEnd, writeEnd) = (descriptors[0], descriptors[1])

        // Far more than a pipe buffer holds, so the writer blocks and can only
        // finish if the reader keeps reading. A helper that stopped at its own
        // limit would leave this write incomplete — and hand Codex an EPIPE.
        let payload = [UInt8](repeating: 0x61, count: 512 * 1024)
        let writer = Task.detached {
            var written = 0
            payload.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                while written < buffer.count {
                    let count = Darwin.write(writeEnd, base + written, buffer.count - written)
                    if count > 0 {
                        written += count
                    } else if errno != EINTR {
                        break
                    }
                }
            }
            close(writeEnd)
            return written
        }

        let drained = StandardInput.drain(limit: 1024, from: readEnd)
        close(readEnd)
        let written = await writer.value

        #expect(written == payload.count)
        #expect(drained.total == payload.count)
        #expect(drained.data.count == 1024)
    }
}
