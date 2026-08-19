import Foundation
import Testing

@testable import CodexAppServer

/// The conversation itself: the handshake, correlation, the deadline, and the
/// promise that the child is ended on every path.
@Suite("App Server exchange", .timeLimit(.minutes(1)))
struct ExchangeTests {

    static func run<Answer: Sendable>(
        _ transport: ScriptedTransport,
        budget: Duration = .seconds(20),
        _ body: @Sendable @escaping (AppServerExchange, CodexVersion) async throws -> Answer
    ) async throws -> Answer {
        try await AppServerExchange.run(
            transport: transport, clientVersion: "0.1.0", budget: budget, body)
    }

    /// Anything before `initialized` is refused with `-32600 "Not initialized"`,
    /// so the order is not optional politeness.
    @Test("The handshake happens before anything is asked")
    func handshakesFirst() async throws {
        let transport = ScriptedTransport()
        transport.reactions[AccountMethods.rateLimits] = [
            .result(String(data: try Fixtures.data("rate-limits-live"), encoding: .utf8) ?? "{}")
        ]
        _ = try await Self.run(transport) { exchange, _ in
            try await AccountMethods.readRateLimits(on: exchange)
        }
        #expect(
            transport.methodsCalled == ["initialize", "initialized", "account/rateLimits/read"])
    }

    @Test("The Codex version comes out of the handshake, not a second process")
    func readsTheVersionFromTheUserAgent() async throws {
        let transport = ScriptedTransport(
            userAgent: "AgentBar/0.148.2 (Mac OS 27.0.0; arm64) unknown (AgentBar; 0.1.0)")
        let version = try await Self.run(transport) { _, version in version }
        #expect(version.raw == "0.148.2")
    }

    @Test(
        "A user agent that is not the expected shape still identifies the build",
        arguments: [
            ("codex-cli 0.147.0", "codex-cli 0.147.0"),
            ("AgentBar/", "AgentBar/"),
            ("", ""),
        ])
    func degradesOnAnOddUserAgent(agent: String, expected: String) {
        #expect(CodexVersion(userAgent: agent).raw == expected)
    }

    /// `account/read` is rejected without `params`; the other two take none.
    /// Sending the wrong one is a `-32600` that looks like a bug in Codex.
    @Test("Each method sends the parameter shape the server demands")
    func sendsTheRightParameters() async throws {
        let transport = ScriptedTransport()
        transport.reactions[AccountMethods.account] = [
            .result(String(data: try Fixtures.data("account-chatgpt"), encoding: .utf8) ?? "{}")
        ]
        transport.reactions[AccountMethods.usage] = [
            .result(String(data: try Fixtures.data("usage-live"), encoding: .utf8) ?? "{}")
        ]
        _ = try await Self.run(transport) { exchange, _ in
            _ = try await AccountMethods.readAccount(on: exchange)
            _ = try await AccountMethods.readTokenUsage(on: exchange)
        }
        let account = try #require(transport.sent.first { $0.contains("account/read") })
        // Exactly `{}`, which is stronger than asserting the absence of the one
        // flag that belongs there: an empty object cannot carry any flag, and
        // the flag in question asks Codex to renew a credential.
        #expect(account.contains(#""params":{}"#))
        let usage = try #require(transport.sent.first { $0.contains("account/usage/read") })
        #expect(!usage.contains("params"))
        // The handshake introduces AgentBar by its own name and version.
        let initialize = try #require(transport.sent.first)
        #expect(initialize.contains(#""name":"AgentBar""#))
        #expect(initialize.contains(#""version":"0.1.0""#))
        // `jsonrpc` is omitted on the wire — sending it is not what the binary
        // parses against.
        #expect(!initialize.contains("jsonrpc"))
    }

    /// Notifications interleave with replies from the first moment —
    /// `configWarning` arrives before anything has been asked for.
    @Test("Notifications and unreadable lines are stepped over")
    func ignoresEverythingElse() async throws {
        let transport = ScriptedTransport()
        transport.preamble = [
            #"{"method":"configWarning","params":{"summary":"rules"}}"#,
            #"{"method":"remoteControl/status/changed","params":{"status":"disabled"}}"#,
        ]
        transport.noiseWithEveryReply = [
            "this is not json at all",
            #"{"method":"thread/started"}"#,
            #"{"error":{"code":-1,"message":"no id here"}}"#,
        ]
        transport.reactions[AccountMethods.rateLimits] = [
            .result(String(data: try Fixtures.data("rate-limits-live"), encoding: .utf8) ?? "{}")
        ]
        let windows = try await Self.run(transport) { exchange, _ in
            RateLimitMapping.windows(from: try await AccountMethods.readRateLimits(on: exchange))
        }
        #expect(windows.count == 1)
    }

    /// An unrecognised method is `-32600` — invalid request, not method not
    /// found — because the envelope fails against a closed enum of methods.
    @Test("A method the server does not implement is reported as such")
    func recognisesAnUnimplementedMethod() async throws {
        let transport = ScriptedTransport()
        // The scripted server answers an unscripted method exactly as the real
        // one does.
        await #expect(throws: AppServerError.unimplemented(method: AccountMethods.rateLimits)) {
            try await Self.run(transport) { exchange, _ in
                try await AccountMethods.readRateLimits(on: exchange)
            }
        }
    }

    @Test("An ordinary refusal is reported with its code")
    func reportsARejection() async throws {
        let transport = ScriptedTransport()
        transport.reactions[AccountMethods.rateLimits] = [
            .failure(code: -32000, message: "upstream unavailable")
        ]
        await #expect(
            throws: AppServerError.rejected(code: -32000, message: "upstream unavailable")
        ) {
            try await Self.run(transport) { exchange, _ in
                try await AccountMethods.readRateLimits(on: exchange)
            }
        }
    }

    /// The requirement the step names in as many words: an RPC that never
    /// answers must not hang the reader, and the child must be killed.
    @Test("A silent server is killed when the budget runs out")
    func killsASilentServer() async throws {
        let transport = ScriptedTransport()
        transport.reactions[AccountMethods.rateLimits] = [.silence]
        await #expect(throws: AppServerError.timedOut(.milliseconds(120))) {
            try await Self.run(transport, budget: .milliseconds(120)) { exchange, _ in
                try await AccountMethods.readRateLimits(on: exchange)
            }
        }
        #expect(transport.ended, "the child must be ended when the deadline fires")
    }

    /// A server that never even answers `initialize` is the same hazard one step
    /// earlier, and the same answer has to hold.
    @Test("A server that never completes the handshake is killed too")
    func killsAServerThatNeverHandshakes() async throws {
        let transport = ScriptedTransport()
        transport.reactions["initialize"] = [.silence]
        await #expect(throws: AppServerError.timedOut(.milliseconds(120))) {
            try await Self.run(transport, budget: .milliseconds(120)) { exchange, _ in
                try await AccountMethods.readRateLimits(on: exchange)
            }
        }
        #expect(transport.ended)
    }

    @Test("A child that exits mid-call resumes the caller rather than stranding it")
    func reportsADisconnection() async throws {
        let transport = ScriptedTransport()
        transport.reactions[AccountMethods.rateLimits] = [.disconnect]
        await #expect(throws: AppServerError.disconnected) {
            try await Self.run(transport, budget: .seconds(5)) { exchange, _ in
                try await AccountMethods.readRateLimits(on: exchange)
            }
        }
    }

    /// The line that makes "no process is ever left behind" a property rather
    /// than an intention: the success path ends the child as firmly as the
    /// timeout does.
    @Test("The child is ended on the success path as well")
    func endsTheChildAfterASuccessfulRead() async throws {
        let transport = ScriptedTransport()
        transport.reactions[AccountMethods.rateLimits] = [
            .result(String(data: try Fixtures.data("rate-limits-live"), encoding: .utf8) ?? "{}")
        ]
        _ = try await Self.run(transport) { exchange, _ in
            try await AccountMethods.readRateLimits(on: exchange)
        }
        #expect(transport.ended)
    }

    @Test("A body that throws still ends the child")
    func endsTheChildWhenTheBodyThrows() async {
        struct Boom: Error {}
        let transport = ScriptedTransport()
        await #expect(throws: Boom.self) {
            try await Self.run(transport) { _, _ in throw Boom() }
        }
        #expect(transport.ended)
    }

    /// `Task.value` is not cancellation-aware, so without a cancellation
    /// handler a cancelled refresh would leave the child running until the
    /// budget expired — up to twenty seconds after `QuotaService.stop()`
    /// returned. The claim is "killed on every path", and this is one of them.
    @Test("Cancelling the caller kills the child immediately")
    func endsTheChildWhenTheCallerIsCancelled() async throws {
        let transport = ScriptedTransport()
        transport.reactions[AccountMethods.rateLimits] = [.silence]
        let started = AsyncStream<Void>.makeStream()

        let work = Task {
            try await Self.run(transport, budget: .seconds(30)) { exchange, _ in
                started.continuation.finish()
                return try await AccountMethods.readRateLimits(on: exchange)
            }
        }
        // Wait until the exchange is genuinely in flight, so this cancels work
        // rather than a task that has not begun.
        for await _ in started.stream {}

        let clock = ContinuousClock()
        let start = clock.now
        work.cancel()
        // `CancellationError`, not `.disconnected`: which name is reported
        // depends on who did the killing, and this is us.
        await #expect(throws: CancellationError.self) { try await work.value }
        let elapsed = clock.now - start

        #expect(transport.ended)
        // **The timing is the assertion.** Without a cancellation handler this
        // test still passes — the budget's own timer kills the child eventually
        // — it just takes the full thirty seconds. Only the elapsed time can
        // tell "cancelled" from "waited out".
        #expect(
            elapsed < .seconds(5),
            "cancellation took \(elapsed): the child waited for the budget, not for the cancel")
    }

    /// The interlock between the cancellation handler and the transport's
    /// refusal to start after ending. `onCancel` runs *before* `operation` when
    /// the caller is already cancelled, so the transport is ended before the
    /// work task reaches `start()` — and "no child was spawned" holds only
    /// because `start()` refuses.
    @Test("A caller cancelled before the exchange begins starts nothing")
    func startsNothingWhenAlreadyCancelled() async throws {
        let transport = ScriptedTransport()
        let work = Task {
            // Cancelled before this runs, so the handler fires immediately.
            try await Self.run(transport, budget: .seconds(30)) { exchange, _ in
                try await AccountMethods.readRateLimits(on: exchange)
            }
        }
        work.cancel()
        await #expect(throws: (any Error).self) { try await work.value }
        #expect(transport.ended)
        #expect(!transport.started, "the transport must refuse to start once it has been ended")
    }

    /// A message carrying both an id and a method is the server asking us
    /// something, not answering. Unreachable today — AgentBar never starts a
    /// thread — but server ids come from the server's own counter and would
    /// collide with ours, and this sits one layer from the never-auto-approve
    /// rule.
    @Test("A server-originated request is not mistaken for a reply")
    func doesNotTreatAServerRequestAsAReply() async throws {
        let transport = ScriptedTransport()
        transport.noiseWithEveryReply = [
            #"{"id":2,"method":"execCommandApproval","params":{"command":"rm -rf /"}}"#
        ]
        transport.reactions[AccountMethods.rateLimits] = [
            .result(String(data: try Fixtures.data("rate-limits-live"), encoding: .utf8) ?? "{}")
        ]
        let windows = try await Self.run(transport, budget: .seconds(5)) { exchange, _ in
            RateLimitMapping.windows(from: try await AccountMethods.readRateLimits(on: exchange))
        }
        // The approval request shares the id of the call in flight and arrives
        // first. Reading it as the reply would fail as `.undecodable`.
        #expect(windows.count == 1)
    }

    @Test("A reply whose body is not what the method promised is reported, not crashed")
    func reportsAnUndecodableResult() async throws {
        let transport = ScriptedTransport()
        transport.reactions[AccountMethods.rateLimits] = [.result(#"{"nothing":"useful"}"#)]
        await #expect(throws: AppServerError.self) {
            try await Self.run(transport) { exchange, _ in
                try await AccountMethods.readRateLimits(on: exchange)
            }
        }
    }
}
