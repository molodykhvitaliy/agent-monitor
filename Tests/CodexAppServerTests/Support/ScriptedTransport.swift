import Foundation
import Testing

@testable import CodexAppServer

/// An App Server that answers from a script instead of from OpenAI.
///
/// Everything above the process boundary is exercised through this: the
/// handshake, correlation by id, out-of-order replies, notifications arriving in
/// the middle, an error, a silence and a disconnection. The one thing it cannot
/// prove is that a real child is killed, which is why `ProcessTransportTests`
/// exists and runs against `/bin/cat`.
final class ScriptedTransport: AppServerTransport, @unchecked Sendable {
    /// What the server does when it is asked something.
    enum Reaction: Sendable {
        /// Reply to this request's id with the given JSON body as `result`.
        case result(String)
        /// Reply with a JSON-RPC error.
        case failure(code: Int, message: String)
        /// Say nothing at all, which is how a timeout is provoked.
        case silence
        /// End the stream, as a child exiting does.
        case disconnect
    }

    /// Lines pushed before any request is answered — the notifications a real
    /// server interleaves from the first moment.
    var preamble: [String] = []
    /// Reactions by method, in the order the methods are called.
    var reactions: [String: [Reaction]] = [:]
    /// Extra lines emitted alongside each reply, to prove they are ignored.
    var noiseWithEveryReply: [String] = []

    private(set) var sent: [String] = []
    private(set) var ended = false
    private(set) var endCount = 0
    private(set) var started = false

    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?

    init(userAgent: String = "AgentBar/0.147.0 (Mac OS 27.0.0; arm64) unknown (AgentBar; 0.1.0)") {
        let handshake = #"""
            {"userAgent":"\#(userAgent)","codexHome":"/x","platformFamily":"unix",\#
            "platformOs":"macos"}
            """#
        reactions["initialize"] = [.result(handshake)]
    }

    func start() throws -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        lock.withLock {
            started = true
            self.continuation = continuation
        }
        for line in preamble { continuation.yield(Data(line.utf8)) }
        return stream
    }

    func send(_ line: Data) throws {
        let text = String(data: line, encoding: .utf8) ?? ""
        struct Envelope: Decodable {
            let id: Int?
            let method: String
        }
        let envelope = try? JSONDecoder().decode(Envelope.self, from: line)
        let continuation: AsyncStream<Data>.Continuation? = lock.withLock {
            guard !ended else { return nil }
            sent.append(text)
            return self.continuation
        }
        guard let continuation, let envelope, let id = envelope.id else { return }

        let reaction = lock.withLock { () -> Reaction? in
            guard var queued = reactions[envelope.method], !queued.isEmpty else { return nil }
            let next = queued.removeFirst()
            reactions[envelope.method] = queued
            return next
        }
        for noise in noiseWithEveryReply { continuation.yield(Data(noise.utf8)) }
        switch reaction {
        case .result(let body):
            continuation.yield(Data(#"{"id":\#(id),"result":\#(body)}"#.utf8))
        case .failure(let code, let message):
            continuation.yield(
                Data(#"{"id":\#(id),"error":{"code":\#(code),"message":"\#(message)"}}"#.utf8))
        case .silence:
            break
        case .disconnect:
            end()
        case nil:
            // An unscripted method is answered as one a server does not know,
            // which is what a real one does.
            continuation.yield(
                Data(
                    #"""
                    {"id":\#(id),"error":{"code":-32600,"message":"Invalid request: \#
                    unknown variant `\#(envelope.method)`"}}
                    """#.utf8))
        }
    }

    func end() {
        let continuation: AsyncStream<Data>.Continuation? = lock.withLock {
            endCount += 1
            guard !ended else { return nil }
            ended = true
            let value = self.continuation
            self.continuation = nil
            return value
        }
        continuation?.finish()
    }

    /// The methods that were asked for, in order.
    var methodsCalled: [String] {
        lock.withLock { sent }.compactMap { line in
            struct Envelope: Decodable { let method: String }
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(Envelope.self, from: data).method
        }
    }
}
