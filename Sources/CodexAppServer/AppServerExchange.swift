import Foundation
import os

/// One conversation with one App Server, from spawn to kill.
///
/// An exchange is used once. It handshakes, asks what it was asked to ask, and
/// ends the transport — **always**, on every path, including cancellation and
/// the deadline. There is no reconnect and no keep-alive: a child that has to be
/// killed is a child we no longer trust, and the next reading spawns a fresh one
/// for a little over a second (measured 1.39 s end to end).
///
/// The whole exchange shares **one** budget rather than each call having its
/// own. What the caller needs bounded is how long a refresh can take, and a
/// per-call timeout multiplies rather than bounds it.
///
/// **Replies are routed, not awaited in order.** The server answers out of order
/// — `account/usage/read` was observed replying before an earlier
/// `account/rateLimits/read` — and interleaves notifications with replies from
/// the first moment. So one pump reads the stream and hands each line to
/// whichever call is waiting for that id; everything else is dropped.
public actor AppServerExchange {
    private static let logger = Logger(
        subsystem: "com.molodykhvitalii.AgentBar", category: "quota")

    /// The name AgentBar introduces itself by.
    public static let clientName = "AgentBar"

    /// How long the whole exchange may take before the child is killed.
    ///
    /// Generous on purpose. `account/rateLimits/read` is a network round trip
    /// made by Codex, measured at 1.4 s here and 3.2 s on the day the plan was
    /// written; the budget has to cover a bad connection without ever becoming
    /// unbounded. Nothing waits on this — the panel renders the previous
    /// reading, or none at all.
    public static let defaultBudget: Duration = .seconds(20)

    private let transport: any AppServerTransport
    private let clientVersion: String
    private var nextID = 1
    private var pump: Task<Void, Never>?
    /// Calls waiting for a reply, by the id they sent. The method is kept
    /// alongside so a rejection can name what was refused.
    private var waiting: [JSONRPC.RequestID: (method: String, reply: Reply)] = [:]
    private var closed = false

    private typealias Reply = CheckedContinuation<Data, any Error>

    public init(transport: any AppServerTransport, clientVersion: String) {
        self.transport = transport
        self.clientVersion = clientVersion
    }

    /// Runs `body` against a started, handshaken server and then ends it.
    ///
    /// The deadline and the teardown both live here rather than in the caller,
    /// because "the child is never leaked" is only true if there is exactly one
    /// place that can forget.
    public static func run<Answer: Sendable>(
        transport: any AppServerTransport,
        clientVersion: String,
        budget: Duration = defaultBudget,
        _ body: @Sendable @escaping (AppServerExchange, CodexVersion) async throws -> Answer
    ) async throws -> Answer {
        let exchange = AppServerExchange(transport: transport, clientVersion: clientVersion)
        let expired = OSAllocatedUnfairLock(initialState: false)

        let work = Task {
            let version = try await exchange.begin()
            return try await body(exchange, version)
        }
        let timer = Task {
            try? await Task.sleep(for: budget)
            guard !Task.isCancelled else { return }
            expired.withLock { $0 = true }
            // Killing the child is what unblocks the reader: the stream finishes
            // when the process goes, so every waiting call is resumed rather
            // than asked politely to stop.
            transport.end()
            work.cancel()
        }
        defer {
            timer.cancel()
            // The success path ends the child too. This is the line that makes
            // "no process is ever left behind" true rather than aspirational.
            transport.end()
        }
        do {
            // `Task.value` is not cancellation-aware: without this handler,
            // cancelling the caller would leave the child running until the
            // budget expired — up to twenty seconds after `QuotaService.stop()`
            // returned. The handler is what makes "killed on every path,
            // cancellation included" true rather than intended.
            return try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                transport.end()
                work.cancel()
            }
        } catch {
            // A killed child surfaces as `disconnected` or as cancellation.
            // Which name to report depends on who did the killing: the deadline
            // is a fact about Codex, and cancellation is a fact about us.
            if expired.withLock({ $0 }) { throw AppServerError.timedOut(budget) }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// Starts the server and completes the mandatory handshake.
    ///
    /// Anything sent before `initialized` is refused with
    /// `-32600 "Not initialized"`, so this is not optional politeness.
    func begin() async throws -> CodexVersion {
        let stream = try transport.start()
        pump = Task { [weak self] in
            for await line in stream { await self?.deliver(line) }
            await self?.streamEnded()
        }

        let reply = try await call(
            method: "initialize",
            params: .clientInfo(name: Self.clientName, version: clientVersion),
            returning: InitializeReply.self)
        try send(.notification(method: "initialized"))
        return CodexVersion(userAgent: reply.userAgent)
    }

    /// Sends one request and waits for the reply carrying its id.
    ///
    /// Internal, and `AccountMethods` is the public way in. A caller outside
    /// this module has no business naming a method string or a parameter shape:
    /// the set of calls AgentBar makes is closed, and keeping it closed here is
    /// what makes "AgentBar asks Codex for three things" checkable.
    func call<Payload: Decodable & Sendable>(
        method: String,
        params: JSONRPC.Parameters,
        returning: Payload.Type
    ) async throws -> Payload {
        guard !closed else { throw AppServerError.disconnected }
        let id = JSONRPC.RequestID(nextID)
        nextID += 1
        try send(.request(id: id, method: method, params: params))

        let line = try await withCheckedThrowingContinuation { continuation in
            waiting[id] = (method, continuation)
        }
        do {
            return try JSONRPC.result(Payload.self, from: line)
        } catch {
            throw AppServerError.undecodable("\(method): \(error)")
        }
    }

    // MARK: - The pump

    private func deliver(_ line: Data) {
        switch JSONRPC.decode(line: line) {
        case .result(let id, let payload):
            waiting.removeValue(forKey: id)?.reply.resume(returning: payload)
        case .failure(let id, let error):
            guard let waiter = waiting.removeValue(forKey: id) else { return }
            // A method the server does not implement is `-32600`, not
            // `-32601`: the envelope fails to deserialise against a closed enum
            // of method names. It is the one error worth a different answer,
            // because it means this Codex has no account API rather than that
            // this call went wrong.
            waiter.reply.resume(
                throwing: error.looksUnimplemented
                    ? AppServerError.unimplemented(method: waiter.method)
                    : AppServerError.rejected(code: error.code, message: error.message))
        case .request(let id, let method):
            // Nothing answers it, and nothing ever will on this connection —
            // but an unanswered request from the server is the one piece of
            // traffic here that could matter, so it is discoverable in the log
            // rather than only in a test.
            Self.logger.notice(
                """
                codex app-server asked for \(method, privacy: .public), id \
                \(id, privacy: .public) — AgentBar starts no thread and answers no requests
                """)
        case .unrelated:
            // A notification, or a reply whose id could not be read. Both are
            // ordinary traffic — `configWarning` arrives before anything is
            // even asked for.
            break
        }
    }

    /// The server's output ended: it exited, or it was killed. Nothing more will
    /// arrive, so every waiting call is answered rather than left suspended.
    private func streamEnded() {
        closed = true
        let stranded = waiting
        waiting.removeAll()
        for (_, waiter) in stranded {
            waiter.reply.resume(throwing: AppServerError.disconnected)
        }
    }

    private func send(_ message: JSONRPC.Outgoing) throws {
        let encoded: Data
        do {
            // `withoutEscapingSlashes` is not cosmetic. Foundation escapes `/`
            // as `\/` by default, so a method name would go out as
            // `account\/rateLimits\/read`. The server accepts that — verified
            // against 0.147.0 on 2026-08-19 — but it is a difference from what
            // every other client sends, on a surface labelled experimental, for
            // nothing.
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            encoded = try encoder.encode(message)
        } catch {
            // Encoding a closed value type cannot fail in practice; reporting it
            // as a start failure keeps the caller's error surface closed.
            throw AppServerError.cannotStart("request could not be encoded: \(error)")
        }
        try transport.send(encoded)
    }

    /// The handshake's reply, hand-written rather than generated.
    ///
    /// The two handshake types are the one part of the protocol the generator
    /// does not cover: `InitializeParams` has to be *encoded*, and the generator
    /// emits decoders only, because nothing else AgentBar sends carries a body.
    /// Only `userAgent` is read — `codexHome`, `platformFamily` and `platformOs`
    /// are declared by the schema and of no use here.
    private struct InitializeReply: Decodable, Sendable {
        let userAgent: String
    }
}
