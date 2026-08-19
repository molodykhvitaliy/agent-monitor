import Foundation
import Testing

@testable import CodexAppServer

/// The part the scripted transport cannot prove: a real child, really spawned,
/// really killed.
///
/// The stand-in is a shell script that answers like an App Server — same
/// newline-delimited framing, same two replies — so this exercises spawn,
/// framing, the handshake and the kill together without `codex` being installed
/// anywhere. Ungated, unlike the render and power suites: it touches nothing but
/// a temporary directory and `/bin/sh`.
@Suite("Process transport", .serialized)
struct ProcessTransportTests {

    /// A fake `codex` in a temporary directory. Deleted when the test ends.
    struct FakeCodex: ~Copyable {
        let directory: URL
        var executable: URL { directory.appending(path: "codex") }

        init(body: String) throws {
            directory = URL(filePath: NSTemporaryDirectory())
                .appending(path: "agentbar-appserver-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try ("#!/bin/sh\n" + body).write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path(percentEncoded: false))
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    /// Answers `initialize` and `account/rateLimits/read`, and nothing else. The
    /// ids are fixed because the client's are: 1 for the handshake, 2 for the
    /// first call after it.
    static let answering = """
        while IFS= read -r line; do
          case "$line" in
            *initialize*)
              printf '{"id":1,"result":{"userAgent":"AgentBar/9.9.9 (x; y) z (AgentBar; 0.1.0)",\
        "codexHome":"/x","platformFamily":"unix","platformOs":"macos"}}\\n' ;;
            *rateLimits*)
              printf '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":\
        {"usedPercent":42,"windowDurationMins":10080,"resetsAt":1787200207}}}}\\n' ;;
          esac
        done
        """

    /// Handshakes and then says nothing at all, for ten minutes.
    static let silent = """
        while IFS= read -r line; do
          case "$line" in
            *initialize*)
              printf '{"id":1,"result":{"userAgent":"AgentBar/9.9.9 (x; y) z (AgentBar; 0.1.0)",\
        "codexHome":"/x","platformFamily":"unix","platformOs":"macos"}}\\n'
              sleep 600 ;;
          esac
        done
        """

    /// Waits for the child to go, or gives up. Polled rather than slept through:
    /// `SIGTERM` lands in single-digit milliseconds and the reaping is
    /// Foundation's, so the answer is usually immediate.
    static func waitForExit(_ transport: CodexProcessTransport) async -> Bool {
        for _ in 0..<200 {
            if !transport.isChildRunning { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test("A real child answers a real exchange")
    func talksToARealProcess() async throws {
        let fake = try FakeCodex(body: Self.answering)
        let transport = CodexProcessTransport(executable: fake.executable)
        let windows = try await AppServerExchange.run(
            transport: transport, clientVersion: "0.1.0", budget: .seconds(10)
        ) { exchange, version in
            #expect(version.raw == "9.9.9")
            return RateLimitMapping.windows(
                from: try await AccountMethods.readRateLimits(on: exchange))
        }
        #expect(windows.count == 1)
        #expect(windows.first?.fractionUsed == 0.42)
        #expect(await Self.waitForExit(transport), "the child must not outlive a successful read")
    }

    /// The step's own validation, run rather than asserted: force an RPC
    /// timeout and confirm the child is killed.
    @Test("A child that never answers is killed when the budget runs out")
    func killsASilentChild() async throws {
        let fake = try FakeCodex(body: Self.silent)
        let transport = CodexProcessTransport(executable: fake.executable)
        await #expect(throws: AppServerError.timedOut(.milliseconds(400))) {
            try await AppServerExchange.run(
                transport: transport, clientVersion: "0.1.0", budget: .milliseconds(400)
            ) { exchange, _ in
                try await AccountMethods.readRateLimits(on: exchange)
            }
        }
        #expect(await Self.waitForExit(transport), "a hung child must not survive its deadline")
    }

    /// Codex is not installed, or the override names something that is not
    /// there. Neither is a crash and neither is a hang.
    @Test("A binary that is not there is reported, not survived by a process")
    func reportsAMissingBinary() async {
        let transport = CodexProcessTransport(
            executable: URL(filePath: "/nowhere/agentbar/codex"))
        await #expect(throws: AppServerError.self) {
            _ = try await AppServerExchange.run(
                transport: transport, clientVersion: "0.1.0", budget: .seconds(5)
            ) { exchange, _ in
                try await AccountMethods.readRateLimits(on: exchange)
            }
        }
    }

    /// One JSON object is never split across two reads in practice, but "in
    /// practice" is not a framing rule.
    @Test("A line split across two reads is reassembled")
    func reassemblesASplitLine() async throws {
        let fake = try FakeCodex(
            body: """
                read -r line
                printf '{"id":1,"resu'
                sleep 0.2
                printf 'lt":{"userAgent":"AgentBar/7.7.7 (x; y) z (AgentBar; 0.1.0)",\
                "codexHome":"/x","platformFamily":"unix","platformOs":"macos"}}\\n'
                sleep 5
                """)
        let transport = CodexProcessTransport(executable: fake.executable)
        let version = try await AppServerExchange.run(
            transport: transport, clientVersion: "0.1.0", budget: .seconds(10)
        ) { _, version in version }
        #expect(version.raw == "7.7.7")
        #expect(await Self.waitForExit(transport))
    }

    /// stderr has to be drained: an unread pipe fills at 64 KB and blocks the
    /// writer, which for this child would be a hang rather than a diagnostic.
    @Test("A child that floods stderr still gets answered")
    func drainsStandardError() async throws {
        let fake = try FakeCodex(
            body: """
                pad=$(printf 'x%.0s' $(seq 1 120))
                i=0
                while [ $i -lt 400 ]; do
                  echo "warning line $i $pad" >&2
                  i=$((i+1))
                done
                \(Self.answering)
                """)
        let transport = CodexProcessTransport(executable: fake.executable)
        let version = try await AppServerExchange.run(
            transport: transport, clientVersion: "0.1.0", budget: .seconds(15)
        ) { _, version in version }
        #expect(version.raw == "9.9.9")
        // Bounded, and stripped of the control characters a log line must not
        // carry: this text came from outside the process.
        let diagnostics = try #require(transport.diagnostics())
        #expect(diagnostics.count <= CodexProcessTransport.diagnosticLimit)
        #expect(diagnostics.contains("warning line"))
    }

    /// The hole a review found: `end()` sets a flag every later `end()` returns
    /// on, so a `start()` after it would spawn a child that nothing was left to
    /// kill. It refuses instead.
    ///
    /// `spawnCount` is what makes this test worth having. A `start()` that
    /// spawned and then killed the child would throw the same error and leave
    /// `isChildRunning` false, so only the count can tell "refused" from
    /// "cleaned up after itself".
    @Test("Starting after ending spawns nothing at all")
    func refusesToStartAfterEnding() async throws {
        let fake = try FakeCodex(body: Self.answering)
        let transport = CodexProcessTransport(executable: fake.executable)
        transport.end()
        #expect(throws: AppServerError.disconnected) {
            _ = try transport.start()
        }
        #expect(transport.spawnCount == 0, "an ended transport must not create a child at all")
        #expect(!transport.isChildRunning)
        // And a second `end()` on a transport that never started is still fine.
        transport.end()
    }

    @Test("Ending twice is not an error")
    func endIsIdempotent() async throws {
        let fake = try FakeCodex(body: Self.answering)
        let transport = CodexProcessTransport(executable: fake.executable)
        _ = try transport.start()
        transport.end()
        transport.end()
        #expect(await Self.waitForExit(transport))
        #expect(throws: AppServerError.disconnected) {
            try transport.send(Data("{}".utf8))
        }
    }
}
