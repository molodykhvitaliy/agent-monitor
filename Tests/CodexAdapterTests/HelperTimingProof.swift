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
@Suite("Helper timing proof", .serialized)
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
    /// trip. Comparing against a baseline rather than against a fixed number is
    /// what keeps this from failing because the machine was busy — which it will
    /// be, since the thing being measured runs while an agent is working.
    static let budget = Duration.milliseconds(10)
    /// A ceiling on the whole run regardless. Codex's smallest allowance is a
    /// thousand milliseconds, so this is a regression alarm rather than a limit.
    static let ceiling = Duration.milliseconds(50)
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

    @Test("The helper exits successfully with no endpoint to talk to")
    func survivesWithoutAnEndpoint() throws {
        guard let binary = Self.binary else { return }
        // No discovery file exists for this process's environment unless
        // AgentBar is running; either way the exit status must be zero and both
        // streams must be empty, because Codex reads a non-zero exit from
        // `PreToolUse` as a block.
        let result = try Self.execute(
            binary, payload: Data(#"{"hook_event_name":"Stop"}"#.utf8),
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
        // the first 64 KB.
        #expect(result.status == 0)
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

        // Written from another thread: a payload larger than the pipe buffer
        // blocks until the helper reads it, which is the behaviour under test.
        nonisolated(unsafe) var wrote = 0
        let writer = Thread {
            input.fileHandleForWriting.write(payload)
            wrote = payload.count
            try? input.fileHandleForWriting.close()
        }
        writer.start()

        let collected = output.fileHandleForReading.readDataToEndOfFile()
        let collectedErrors = errorOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus, output: collected, errorOutput: collectedErrors,
            wrote: wrote)
    }
}
