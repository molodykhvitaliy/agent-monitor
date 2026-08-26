import AgentBarCore
import AgentBarIngest
import Foundation
import Testing

@testable import CodexAdapter

/// The one claim in this step that a unit test cannot make: the compiled helper
/// finishes inside the budget Codex gives a `SessionEnd` hook.
///
/// Gated behind an environment variable, like the live power proof, because it
/// needs a **built binary** rather than only the package:
///
/// ```
/// make build
/// AGENTBAR_HELPER_BINARY="$(…)/AgentBar.app/Contents/MacOS/agentbar-helper" \
///   swift test --filter HelperTimingProof
/// ```
///
/// What it measures is the whole run as Codex experiences it — spawn, dynamic
/// linking, the socket round trip and exit — because that is the number the
/// one-second cap applies to. It does not measure the shell Codex wraps the
/// command in, which adds a millisecond or two of its own.
/// `.timeLimit`: `drainsALargePayload` joins a writer thread through a
/// semaphore with no deadline of its own, same reasoning as `RelayTests`.
@Suite("Helper timing proof", .serialized, .timeLimit(.minutes(1)))
struct HelperTimingProof {
    static var binary: URL? {
        guard let path = ProcessInfo.processInfo.environment["AGENTBAR_HELPER_BINARY"],
            FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return URL(filePath: path)
    }

    /// How much of the run may be the helper's own work, over and above what it
    /// costs this machine to start *any* process at all.
    ///
    /// The measurement is taken against `/bin/cat`, which drains stdin exactly as
    /// the helper must and does nothing else, so the difference between the two
    /// is the helper: dynamic linking, reading two small files, one socket round
    /// trip.
    ///
    /// **This is a regression alarm, not the requirement.** The requirement is
    /// Codex's own: a thousand milliseconds for a `SessionEnd` hook. Measured on
    /// the developer's Mac the helper's own share was 5.5 ms with the machine
    /// idle and 11 ms with several builds running — and the baseline moved with
    /// it, from 1.0 ms to 1.9 ms, which is what a loaded machine does to every
    /// process launch. The number here has to sit above the loaded case or the
    /// suite fails for the machine's reasons rather than the code's.
    static let budget = Duration.milliseconds(25)
    /// A ceiling on the whole run regardless — still forty times inside the cap
    /// the number actually has to respect.
    static let ceiling = Duration.milliseconds(100)
    static let runs = 40

    @Test("The compiled helper delivers a payload in single-digit milliseconds")
    func measuresTheHelper() async throws {
        guard let binary = Self.binary else { return }
        try await RelayTests.withEndpoint { endpoint in
            let payload = try Fixtures.data("pre-tool-use-shell")
            let discovery = endpoint.paths.discoveryURL.path(percentEncoded: false)
            let baseline = try Self.measure(
                URL(filePath: "/bin/cat"), payload: payload, discovery: nil)
            let helper = try Self.measure(binary, payload: payload, discovery: discovery)

            print(
                """
                agentbar-helper: p50 \(helper.median), p95 \(helper.p95), \
                min \(helper.minimum), max \(helper.maximum) over \(Self.runs) runs
                /bin/cat baseline: p50 \(baseline.median), p95 \(baseline.p95)
                """)

            #expect(helper.median - baseline.median < Self.budget)
            #expect(helper.p95 < Self.ceiling)

            // Every run delivered. A fast helper that dropped its payload would
            // pass a timing test and fail the product; the store is the only
            // thing that can tell the two apart.
            let snapshot = await endpoint.store.snapshot()
            #expect(snapshot.sessions.count == 1)
        }
    }

    struct Samples {
        let sorted: [Duration]
        var minimum: Duration { sorted[0] }
        var median: Duration { sorted[sorted.count / 2] }
        var p95: Duration { sorted[Int(Double(sorted.count) * 0.95)] }
        var maximum: Duration { sorted[sorted.count - 1] }
    }

    static func measure(_ binary: URL, payload: Data, discovery: String?) throws -> Samples {
        var samples: [Duration] = []
        for _ in 0..<runs {
            samples.append(try run(binary, payload: payload, discovery: discovery))
        }
        return Samples(sorted: samples.sorted())
    }

    @Test("Permission observation emits no decision even with no endpoint")
    func permissionResponseIsEmpty() throws {
        guard let binary = Self.binary else { return }
        // No discovery file exists for this process's environment unless
        // AgentBar is running; either way the exit status must be zero and both
        // streams must be empty, because Codex reads `PermissionRequest` stdout
        // as a decision.
        let result = try Self.execute(
            binary,
            payload: Data(
                """
                {"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/tmp",
                 "tool_name":"Bash","tool_input":{"command":"git push"}}
                """.utf8),
            discovery: "/nonexistent/endpoint.json")
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
        #expect(result.errorOutput.isEmpty)
    }

    @Test("A payload far larger than the relay will send still leaves the writer unharmed")
    func drainsALargePayload() throws {
        guard let binary = Self.binary else { return }
        let payload = Data(repeating: 0x20, count: 8 * 1024 * 1024)
        let result = try Self.execute(
            binary, payload: payload, discovery: "/nonexistent/endpoint.json")
        // The write completing at all is the assertion: a helper that exited
        // without draining would have handed the writer EPIPE somewhere around
        // the first 64 KB. The failure is asserted alongside the count, because
        // a count that was assigned regardless of the outcome would make this a
        // tautology — which is what it briefly was.
        #expect(result.status == 0)
        #expect(result.writeFailure == nil, "the writer was cut off: \(result.writeFailure as Any)")
        #expect(result.wrote == payload.count)
    }

    // MARK: - Running it

    static func run(_ binary: URL, payload: Data, discovery: String? = nil) throws -> Duration {
        let started = ContinuousClock.now
        _ = try execute(binary, payload: payload, discovery: discovery)
        return ContinuousClock.now - started
    }

    struct Result {
        let status: Int32
        let output: Data
        let errorOutput: Data
        let wrote: Int
        /// Why the write stopped short, when it did. Carried rather than
        /// discarded so a short write says *what went wrong* — `EPIPE` from a
        /// helper that stopped draining reads very differently from a
        /// descriptor that was never writable.
        let writeFailure: (any Error)?
    }

    static func execute(_ binary: URL, payload: Data, discovery: String? = nil) throws -> Result {
        let process = Process()
        process.executableURL = binary
        if let discovery {
            var environment = ProcessInfo.processInfo.environment
            environment[CodexHelperRelay.discoveryOverrideVariable] = discovery
            process.environment = environment
        }
        let input = Pipe()
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput
        try process.run()

        // The helper's own read is bounded (ADR-0013), so it can exit while this
        // payload is still going in — and writing into a child that has gone
        // raises SIGPIPE, which no `catch` can answer. The same guard the relay
        // socket carries, on the descriptor `Process` handed us. Asserted, not
        // discarded: this is the one syscall here whose failure is fatal to the
        // whole test process rather than to one expectation.
        try #require(fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0)

        // Written from another thread: a payload larger than the pipe buffer
        // blocks until the helper reads it, which is the behaviour under test.
        //
        // > **The failure is recorded, never swallowed.** `drainsALargePayload`
        // > asserts that the write completed, and that assertion is the only
        // > thing standing between a helper that stops draining and a green
        // > suite: it would hand this writer `EPIPE` around the first 64 KB. A
        // > `try?` here would eat that and report a whole write — the assertion
        // > would still pass and the helper would be doing exactly what the
        // > safe-superset rule forbids.
        let outcome = WriteOutcome()
        let writer = Thread {
            // `write(contentsOf:)` rather than the legacy `write(_:)`: the
            // legacy one reports EPIPE as an Objective-C exception, which Swift
            // cannot catch at all.
            do {
                try input.fileHandleForWriting.write(contentsOf: payload)
                outcome.finish(written: payload.count)
            } catch {
                outcome.finish(written: 0, failure: error)
            }
            try? input.fileHandleForWriting.close()
        }
        writer.start()

        let collected = output.fileHandleForReading.readDataToEndOfFile()
        let collectedErrors = errorOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Joined through the semaphore rather than read across threads. The
        // child having exited orders nothing with respect to the writer, so
        // reading the count here without the wait would be a race — and one
        // whose answer is the test's whole verdict.
        let (wrote, failure) = outcome.wait()
        return Result(
            status: process.terminationStatus, output: collected, errorOutput: collectedErrors,
            wrote: wrote, writeFailure: failure)
    }
}
