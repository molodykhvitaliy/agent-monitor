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
@Suite("Process transport", .serialized, .timeLimit(.minutes(1)))
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

    /// Never reads stdin at all, so closing it teaches this child nothing.
    ///
    /// The waiting is a loop of short sleeps rather than one long one, here and
    /// in `silent`. `sh` defers `SIGTERM` while a foreground child is running,
    /// so a `sleep 600` would leave the fake alive for ten minutes after the
    /// signal — reparented to launchd, and accumulating one per run. The real
    /// `codex` is a compiled binary that dies in 0.01 s; this is the harness
    /// paying for being a shell script.
    ///
    /// The distinction matters for `killsAChildThatAppearedDuringTeardown`: a
    /// child that loops on `read` exits the moment stdin closes, which would let
    /// that test pass without the signal it exists to prove.
    static let stubborn = "while :; do sleep 0.1; done\n"

    /// Handshakes and then says nothing at all, for ten minutes.
    static let silent = """
        while IFS= read -r line; do
          case "$line" in
            *initialize*)
              printf '{"id":1,"result":{"userAgent":"AgentBar/9.9.9 (x; y) z (AgentBar; 0.1.0)",\
        "codexHome":"/x","platformFamily":"unix","platformOs":"macos"}}\\n'
              while :; do sleep 0.1; done ;;
          esac
        done
        """

    /// Waits for the child to go, or gives up. Polled rather than slept through:
    /// `SIGTERM` lands in single-digit milliseconds and the reaping is
    /// Foundation's, so the answer is usually immediate.
    ///
    /// > **Bounded by the clock rather than by a count of sleeps, and
    /// > generously.** `Process.isRunning` turns false when *Foundation* reaps
    /// > the child, on a queue this test does not own; on a machine saturated
    /// > enough — a CI runner, or this repository's own suite running beside a
    /// > build — that reaping is simply late. Two hundred ten-millisecond sleeps
    /// > looks like two seconds and is not: it is two hundred sleeps that each
    /// > take as long as the scheduler feels like, and it still ran out. A
    /// > passing test pays none of the ceiling below, because it returns the
    /// > moment the child is gone; only a real regression waits for it.
    static let exitAllowance: Duration = .seconds(10)

    static func waitForExit(_ transport: CodexProcessTransport) async -> Bool {
        let deadline = ContinuousClock.now + exitAllowance
        while ContinuousClock.now < deadline {
            if !transport.isChildRunning { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !transport.isChildRunning
    }

    /// Ignores `SIGTERM` outright. `trap "" TERM` is the shell saying "this
    /// signal is not mine to handle", which is exactly what a wedged or
    /// signal-blocking child looks like from outside.
    ///
    /// It announces itself on stdout, and the announcement is load-bearing:
    /// `Process.run()` returns as soon as the child exists, which is well before
    /// `sh` has read the first line of the script. A signal sent into that
    /// window lands on a shell that has not installed the trap yet and kills it
    /// for ordinary reasons — so the test would pass with the escalation deleted.
    static let deaf = """
        trap "" TERM
        printf 'trapping\\n'
        while :; do sleep 0.1; done
        """

    /// `terminate()` is a request. A transport whose guarantee is "the child is
    /// always killed" has to be able to keep it against a child that declines,
    /// or the guarantee is really about the child's manners — and a menu-bar app
    /// that spawns one of these per reading and leaves it running is the process
    /// leak this project cannot ship.
    @Test("A child that ignores SIGTERM is killed anyway")
    func killsAChildThatIgnoresTermination() async throws {
        let fake = try FakeCodex(body: Self.deaf)
        let transport = CodexProcessTransport(
            executable: fake.executable, terminationGrace: .milliseconds(200))
        var lines = try transport.start().makeAsyncIterator()
        #expect(await lines.next() != nil, "the child has to be trapping before it is signalled")

        transport.end()

        #expect(await Self.waitForExit(transport), "SIGTERM was ignored and nothing followed it")
    }

    /// The escalation must not outlive the child it was armed against: a signal
    /// aimed at a process identifier the kernel has already handed to somebody
    /// else is worse than the leak it was meant to close.
    @Test("A child that exits on the signal leaves no kill behind it")
    func disarmsTheKillWhenTheChildGoes() async throws {
        let fake = try FakeCodex(body: Self.answering)
        let transport = CodexProcessTransport(
            executable: fake.executable, terminationGrace: .seconds(30))
        _ = try transport.start()

        transport.end()
        #expect(await Self.waitForExit(transport))

        // The termination handler runs on Foundation's own queue, so the
        // disarming lands a moment after the exit does.
        for _ in 0..<100 where transport.hasPendingKill {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!transport.hasPendingKill)
    }

    /// Floods stdout with one enormous line, then answers properly.
    ///
    /// `head -c` from `/dev/zero` through `tr` is a megabyte and a half of `a`,
    /// which is what an unbounded `pending` buffer would hold for the whole
    /// exchange. The newline after it is deliberate and is what the recovery is
    /// about: framing resumes at the **next** newline, so a message glued
    /// directly onto unterminated output is lost either way — that is a fact
    /// about the child, not about the cap.
    static let unterminated = """
        head -c 1500000 /dev/zero | tr '\\0' 'a'
        printf '\\n'
        while IFS= read -r line; do
          case "$line" in
            *initialize*)
              printf '{"id":1,"result":{"userAgent":"AgentBar/9.9.9 (x; y) z (AgentBar; 0.1.0)",\
        "codexHome":"/x","platformFamily":"unix","platformOs":"macos"}}\\n' ;;
          esac
        done
        """

    /// The last buffer in this file that could grow without a bound.
    ///
    /// A child writing megabytes with no newline in them is not sending a reply
    /// this transport can parse, and holding it to the end of a twenty-second
    /// budget would trade a parse failure for heap growth. What has to survive
    /// the drop is **framing**: the next newline resynchronises, and the reply
    /// after it is delivered as though nothing had happened.
    @Test("An enormous line is dropped rather than buffered, and framing recovers")
    func recoversFromUnterminatedOutput() async throws {
        let fake = try FakeCodex(body: Self.unterminated)
        let transport = CodexProcessTransport(executable: fake.executable)
        let version = try await AppServerExchange.run(
            transport: transport, clientVersion: "0.1.0", budget: .seconds(10)
        ) { _, version in version }

        #expect(version.raw == "9.9.9", "framing did not recover after the buffer was dropped")
        #expect(await Self.waitForExit(transport))
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
                while :; do sleep 0.1; done
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

    /// The other direction of the same hole. A second `start()` would overwrite
    /// the first child's handles, leaving it running with nothing able to reach
    /// it — and `end()` would then kill only the second.
    @Test("Starting twice leaves the first child reachable and the second uncreated")
    func refusesToStartTwice() async throws {
        let fake = try FakeCodex(body: Self.answering)
        let transport = CodexProcessTransport(executable: fake.executable)
        _ = try transport.start()
        #expect(transport.spawnCount == 1)
        #expect(throws: AppServerError.disconnected) {
            _ = try transport.start()
        }
        #expect(transport.spawnCount == 1, "a live transport must not create a second child")
        transport.end()
        #expect(await Self.waitForExit(transport))
    }

    /// The interleaving the post-`run()` guard exists for, and the only one that
    /// cannot be produced from outside: `end()` arrives while the spawn is in
    /// flight, finds a `Process` that is not running yet, and sends no signal.
    /// Without the guard the child comes up with nothing left to kill it.
    @Test("A child that appears after end() is killed by the spawn itself")
    func killsAChildThatAppearedDuringTeardown() async throws {
        // Deliberately a child that ignores stdin: `end()` has already closed it
        // by the time this one starts, and a child that read stdin would exit on
        // the EOF rather than on the signal being tested.
        let fake = try FakeCodex(body: Self.stubborn)
        let transport = CodexProcessTransport(executable: fake.executable)
        transport.willSpawn = { [weak transport] in transport?.end() }

        #expect(throws: AppServerError.disconnected) {
            _ = try transport.start()
        }
        #expect(transport.spawnCount == 1, "the point of this test is that a child was created")
        #expect(
            await Self.waitForExit(transport),
            "a child created after end() must be killed by start() itself")
    }

    /// A child that fails on a bad config writes to stderr and exits, and the
    /// exchange's very next act is to send `initialize` into a pipe with no
    /// reader. That raises `SIGPIPE`, which no `catch` can answer — a crash here
    /// would break the rule that AgentBar's absence is indistinguishable from
    /// its never having existed.
    @Test("Writing to a child that has already exited throws instead of killing us")
    func survivesWritingToADeadChild() async throws {
        let fake = try FakeCodex(body: "echo 'bad config' >&2\nexit 3\n")
        let transport = CodexProcessTransport(executable: fake.executable)
        _ = try transport.start()
        #expect(await Self.waitForExit(transport))

        // Repeatedly, because the window this closes is a race and one write is
        // a weak way to lose a coin toss.
        for _ in 0..<20 {
            #expect(throws: AppServerError.disconnected) {
                try transport.send(Data(#"{"id":1,"method":"initialize"}"#.utf8))
            }
        }
        #expect(transport.diagnostics()?.contains("bad config") == true)
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
