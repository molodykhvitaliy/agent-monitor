import AgentBarCore
import Foundation

/// Serves one connection until the peer goes away, it falls silent, or it sends
/// something unreadable.
///
/// Connections are kept alive between requests. A hook fires on every tool call,
/// so paying for a handshake each time would be a measurable cost on the one
/// path that must stay invisible.
struct IngestConnection: Sendable {
    private let channel: IngestChannel
    private let transport: IngestTransport
    private let router: IngestRouter
    private let limits: IngestLimits
    private let clock: any TimeSource
    private let diagnostics: any IngestDiagnosticSink

    init(
        channel: IngestChannel,
        transport: IngestTransport,
        router: IngestRouter,
        limits: IngestLimits,
        clock: any TimeSource,
        diagnostics: any IngestDiagnosticSink
    ) {
        self.channel = channel
        self.transport = transport
        self.router = router
        self.limits = limits
        self.clock = clock
        self.diagnostics = diagnostics
    }

    func serve(on queue: DispatchQueue) async {
        defer { channel.close() }
        do {
            try await channel.start(on: queue)
            try await run()
        } catch is CancellationError {
            // The endpoint is stopping, or the peer fell silent past the idle
            // timeout. Neither is worth a diagnostic.
        } catch let error as HTTPParseError {
            diagnostics.record(.malformedRequest(error, transport: transport))
        } catch {
            diagnostics.record(.transportFailure(reason: "\(error)"))
        }
    }

    private func run() async throws {
        var parser = HTTPRequestParser(limits: limits)
        var continueSent = false
        while true {
            do {
                while let request = try parser.next() {
                    continueSent = false
                    let keepAlive = try await answer(request.head, body: request.body)
                    guard keepAlive else { return }
                }
            } catch let error as HTTPParseError {
                // The stream is desynchronised: whatever follows cannot be
                // trusted to be a request, so the status goes back and the
                // connection ends.
                diagnostics.record(.malformedRequest(error, transport: transport))
                try? await channel.send(
                    HTTPResponseWriter.bytes(
                        for: IngestResponse(status: error.status), keepAlive: false))
                return
            }
            if !continueSent, let awaited = parser.awaitingBody, awaited.expectsContinue {
                continueSent = true
                try await channel.send(HTTPResponseWriter.continueResponse)
            }
            guard let chunk = try await readBeforeIdleTimeout() else { return }
            parser.append(chunk)
        }
    }

    /// Answers one request, reporting whether the connection stays open.
    private func answer(_ head: HTTPRequestHead, body: Data) async throws -> Bool {
        let response = await router.respond(
            to: head, body: body, transport: transport, receivedAt: clock.wallTime)
        // A refused request leaves nothing to reuse the connection for, and
        // closing makes a misconfigured client's retries visible as new
        // connections rather than hidden inside one.
        let keepAlive = head.keepsAlive && response.status == .ok
        try await channel.send(HTTPResponseWriter.bytes(for: response, keepAlive: keepAlive))
        return keepAlive
    }

    /// Reads, giving up if the peer says nothing for the idle timeout.
    ///
    /// The timeout closes the channel rather than merely abandoning the read:
    /// cancelling the task that awaits a `receive` does not reach into
    /// Network.framework's pending callback, so the only thing that ends it is
    /// the connection going away.
    private func readBeforeIdleTimeout() async throws -> Data? {
        try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                try await channel.receive(maximumLength: limits.maximumBodyBytes)
            }
            group.addTask {
                try await Task.sleep(for: limits.idleTimeout)
                channel.close()
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { return nil }
            return first
        }
    }
}
