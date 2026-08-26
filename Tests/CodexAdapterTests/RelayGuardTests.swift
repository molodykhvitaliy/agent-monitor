import AgentBarCore
import AgentBarIngest
import Foundation
import Testing

@testable import CodexAdapter

/// What the relay refuses, and how fast it gives up.
///
/// Split from the delivery suite because these are the paths that decide whether
/// the helper can ever be the reason an agent waits — or the reason something
/// leaves this machine.
@Suite("Codex relay guards")
struct RelayGuardTests {

    @Test("No endpoint description at all is silent and instant")
    func reportsUnknownEndpoint() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "agentbar-none-\(UUID().uuidString)", directoryHint: .isDirectory)
        let relay = CodexHelperRelay(discoveryURL: directory.appending(path: "endpoint.json"))
        let started = ContinuousClock.now
        #expect(relay.relay(Data(#"{"hook_event_name":"Stop"}"#.utf8)) == .endpointUnknown)
        #expect(ContinuousClock.now - started < .milliseconds(50))
    }

    @Test("An endpoint that has gone is given up on quickly")
    func givesUpOnADeadEndpoint() throws {
        // The shape of a crash: a description left behind by a process that is
        // no longer there. Written by hand rather than by stopping a live
        // endpoint, because a listener that is still winding down can still
        // accept a connection — which would make this test measure the wrong
        // thing on a busy machine.
        let home = try ScratchCodexHome()
        let discoveryURL = home.directory.appending(path: "endpoint.json")
        let tokenURL = home.directory.appending(path: "ingest-token")
        try Data(String(repeating: "a", count: 32).utf8).write(to: tokenURL)
        try EndpointDiscoveryFile(url: discoveryURL).publish(
            EndpointDescriptor(
                // Port 1 and a socket path that does not exist: both refuse
                // immediately, which is exactly what a stopped AgentBar does.
                port: 1,
                socketPath: home.directory.appending(path: "gone.sock")
                    .path(percentEncoded: false),
                tokenPath: tokenURL.path(percentEncoded: false),
                processIdentifier: 1,
                startedAt: Date()))

        let relay = CodexHelperRelay(discoveryURL: discoveryURL)
        let started = ContinuousClock.now
        let outcome = relay.relay(try Fixtures.data("stop"))
        let elapsed = ContinuousClock.now - started
        guard case .undelivered = outcome else {
            Issue.record("expected undelivered, got \(outcome)")
            return
        }
        // Both routes refused, and a refusal is immediate. The whole point is
        // that an agent never waits on AgentBar being gone.
        #expect(elapsed < .milliseconds(250))
    }

    @Test("A token file that is not a token is reported as such, not sent")
    func refusesAnUnusableToken() async throws {
        try await RelayTests.withEndpoint { endpoint in
            try Data("\n".utf8).write(to: endpoint.paths.tokenURL)
            let outcome = endpoint.relay().relay(try Fixtures.data("stop"))
            guard case .undelivered(let reason) = outcome else {
                Issue.record("expected undelivered, got \(outcome)")
                return
            }
            #expect(reason.contains("token"))
        }
    }

    @Test("An empty payload is not a request")
    func refusesEmptyPayload() async throws {
        try await RelayTests.withEndpoint { endpoint in
            #expect(endpoint.relay().relay(Data()) == .nothingToSend)
        }
    }

    @Test("A payload past the endpoint's own limit is dropped rather than sent to be refused")
    func dropsAnOversizedPayload() async throws {
        try await RelayTests.withEndpoint { endpoint in
            let huge = Data(repeating: 0x20, count: CodexHelperRelay.maximumPayloadBytes + 1)
            #expect(
                endpoint.relay().relay(huge)
                    == .payloadTooLarge(bytes: CodexHelperRelay.maximumPayloadBytes + 1))
            #expect(await endpoint.store.snapshot().sessions.isEmpty)
        }
    }

    @Test("A description naming a host off this machine is refused, not dialled")
    func refusesANonLoopbackHost() throws {
        let home = try ScratchCodexHome()
        let discoveryURL = home.directory.appending(path: "endpoint.json")
        let tokenURL = home.directory.appending(path: "ingest-token")
        try Data(String(repeating: "a", count: 32).utf8).write(to: tokenURL)
        // A planted description. The payload carries a prompt, a working
        // directory and a tool's arguments, and the request carries a bearer
        // token; ADR-0002 says none of it leaves this machine, and the file is
        // the one place that could say otherwise.
        try EndpointDiscoveryFile(url: discoveryURL).publish(
            EndpointDescriptor(
                host: "198.51.100.7", port: 80, socketPath: nil,
                tokenPath: tokenURL.path(percentEncoded: false), processIdentifier: 1,
                startedAt: Date()))

        let outcome = CodexHelperRelay(discoveryURL: discoveryURL).relay(
            try Fixtures.data("stop"))
        guard case .undelivered(let reason) = outcome else {
            Issue.record("expected undelivered, got \(outcome)")
            return
        }
        #expect(reason.contains("loopback"))
    }

    @Test("A description pointing the token somewhere else entirely is refused")
    func refusesATokenOutsideItsOwnDirectory() throws {
        let home = try ScratchCodexHome()
        let discoveryURL = home.directory.appending(path: "endpoint.json")
        let elsewhere = home.directory.appending(path: "secrets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let planted = elsewhere.appending(path: "auth.json")
        try Data(String(repeating: "b", count: 32).utf8).write(to: planted)
        try EndpointDiscoveryFile(url: discoveryURL).publish(
            EndpointDescriptor(
                port: 1, socketPath: nil, tokenPath: planted.path(percentEncoded: false),
                processIdentifier: 1, startedAt: Date()))

        // The helper reads whatever file the description names, so the
        // description must not be able to name any file: pointing it at a
        // credential store would make the helper read one.
        let outcome = CodexHelperRelay(discoveryURL: discoveryURL).relay(
            try Fixtures.data("stop"))
        guard case .undelivered(let reason) = outcome else {
            Issue.record("expected undelivered, got \(outcome)")
            return
        }
        #expect(reason.contains("beside"))
    }

    @Test("The whole relay is bounded once, not once per destination")
    func boundsTheWholeRelay() throws {
        let home = try ScratchCodexHome()
        let discoveryURL = home.directory.appending(path: "endpoint.json")
        let tokenURL = home.directory.appending(path: "ingest-token")
        try Data(String(repeating: "a", count: 32).utf8).write(to: tokenURL)
        try EndpointDiscoveryFile(url: discoveryURL).publish(
            EndpointDescriptor(
                port: 1,
                socketPath: home.directory.appending(path: "gone.sock")
                    .path(percentEncoded: false),
                tokenPath: tokenURL.path(percentEncoded: false), processIdentifier: 1,
                startedAt: Date()))

        let timeouts = RelayTimeouts(total: .milliseconds(120))
        let relay = CodexHelperRelay(discoveryURL: discoveryURL, timeouts: timeouts)
        let started = ContinuousClock.now
        _ = relay.relay(try Fixtures.data("stop"))
        // Two destinations, one budget. Both are refused instantly here; what
        // this pins is that the ladder cannot spend the budget twice.
        #expect(ContinuousClock.now - started < timeouts.total + .milliseconds(80))
    }

}

/// The two conversions that turn a budget into a syscall's own timeout.
///
/// > **Zero means opposite things to the two of them, and only one of those is
/// > safe.** `poll` reads `0` as *return immediately*; `SO_SNDTIMEO` and
/// > `SO_RCVTIMEO` read `{0, 0}` as *block for ever*. A duration too small to
/// > round up therefore has to floor at one microsecond on the socket path,
/// > because the alternative is an unbounded syscall in the one process that
/// > must never outlive the agent that spawned it.
@Suite("Relay timeout conversion")
struct RelayTimeoutConversionTests {

    @Test(
        "A sub-microsecond socket timeout never becomes no timeout",
        arguments: [
            Duration.nanoseconds(1), .nanoseconds(500), .nanoseconds(999), .zero,
        ])
    func socketTimeoutsFloorAtOneMicrosecond(duration: Duration) {
        let value = RelaySocket.timeval(for: duration)
        #expect(value.tv_sec > 0 || value.tv_usec > 0, "{0, 0} means no timeout at all")
    }

    @Test("An ordinary timeout converts exactly")
    func ordinaryTimeoutsConvertExactly() {
        let value = RelaySocket.timeval(for: .milliseconds(150))
        #expect(value.tv_sec == 0)
        #expect(value.tv_usec == 150_000)
        let seconds = RelaySocket.timeval(for: .seconds(2))
        #expect(seconds.tv_sec == 2)
        #expect(seconds.tv_usec == 0)
    }

    /// The sibling conversion floors at zero on purpose, and the direction is
    /// what makes that safe — this pins the asymmetry so neither is "fixed" to
    /// match the other.
    @Test("The poll conversion still floors at zero")
    func pollTimeoutsFloorAtZero() {
        #expect(RelaySocket.milliseconds(.zero) == 0)
        #expect(RelaySocket.milliseconds(.nanoseconds(1)) == 0)
        #expect(RelaySocket.milliseconds(.milliseconds(120)) == 120)
    }

    /// A budget that has already run out is a refusal, not a socket with no
    /// timeout on it.
    ///
    /// Driven against `configure` directly. Through `exchange` the connect gives
    /// up on a spent budget first, so this guard would never be reached — and a
    /// guard nothing reaches is a guard nothing proves.
    @Test("Arming a socket with no budget left refuses rather than blocking")
    func aSpentBudgetIsARefusal() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        #expect(throws: RelaySocketError.timedOut) {
            try RelaySocket.configure(
                descriptor, timeouts: RelayTimeouts(),
                deadline: ContinuousClock.now - .seconds(1))
        }
    }

    /// And the ordinary path actually arms the kernel, rather than calling
    /// `setsockopt` and discarding what it said.
    @Test("A live budget arms both socket timeouts")
    func aLiveBudgetArmsTheKernel() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        try RelaySocket.configure(
            descriptor, timeouts: RelayTimeouts(), deadline: ContinuousClock.now + .seconds(5))

        for option in [SO_SNDTIMEO, SO_RCVTIMEO] {
            var value = timeval()
            var size = socklen_t(MemoryLayout<timeval>.size)
            #expect(getsockopt(descriptor, SOL_SOCKET, option, &value, &size) == 0)
            #expect(
                value.tv_sec > 0 || value.tv_usec > 0,
                "option \(option) was left at {0, 0}, which POSIX reads as no timeout")
        }
    }
}
