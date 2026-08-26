import Foundation
import Testing

@testable import AgentBarCore
@testable import AgentBarIngest

/// The step asks for a p99, and a number nobody records is a number nobody
/// notices moving.
///
/// **Which statistic is asserted depends on how the process was started.** A
/// tail measured under `swift test --parallel` is not a property of this code:
/// swift-testing runs the whole suite concurrently in one process on one
/// cooperative pool, and a CI runner has three cores and — at the time of
/// writing — 112 other suites to schedule beside this one. Over twenty-two CI
/// runs the median held between 0.30 ms and 0.88 ms while the p99 walked from
/// 8 ms to 120 ms in step with the number of tests co-scheduled alongside it.
/// Same binary, three orders of magnitude of spread, none of it ingest. The p99
/// finally crossed the ceiling and failed a pull request that had not touched
/// this module.
///
/// So the loaded run asserts the **median**, which a handful of 120 ms stalls
/// cannot move, and `make timing-proofs` — which runs this suite alone and
/// serially — asserts the tail. Nothing is given up by the split: every
/// regression this test exists to catch moves the median. A per-request
/// handshake, a lock held across a socket read, an accidental sleep — those cost
/// milliseconds on *every* request, not on four out of three hundred.
///
/// `DeadlineTests.expiresPromptly` reached the same conclusion from the other
/// direction, and for the same reason.
@Suite("Latency", .serialized)
struct LatencyTests {
    /// Far above anything healthy, and far below the smallest budget an agent
    /// gives a hook: Codex caps `SessionEnd` at one second. Asserted against the
    /// tail, and only where a tail says something about this code.
    static let ceiling = Duration.milliseconds(100)

    /// What a median may be while the rest of the suite competes for the same
    /// three cores. About ten times the worst median seen over twenty-two CI
    /// runs — 0.88 ms on a kept-alive connection, 2.37 ms including the connect
    /// — which is slack enough for any loaded runner and nowhere near enough to
    /// hide a regression that costs milliseconds per request.
    static let keepAliveMedianCeiling = Duration.milliseconds(10)
    static let connectionMedianCeiling = Duration.milliseconds(25)

    /// Set by `make timing-proofs`, which runs this suite with `--no-parallel`
    /// and nothing else in the process. Absent under `make test`.
    static let isIsolated =
        ProcessInfo.processInfo.environment["AGENTBAR_LATENCY_PROOF"] == "1"

    @Test("Answers on a kept-alive connection well inside a hook's budget")
    func measuresKeepAliveLatency() async throws {
        try await EndpointFactory.withEndpoint { harness in
            let client = try harness.client()
            try await client.open()
            defer { client.close() }

            var samples: [Duration] = []
            let clock = ContinuousClock()
            for index in 0..<300 {
                let body = EventPayload.json(
                    kind: "toolStarted", session: "latency",
                    extra: [
                        "tool": #"{"name": "Bash", "invocation": "swift test"}"#,
                        "toolUseId": "\"tool-\(index)\"",
                    ])
                let started = clock.now
                try await client.write(
                    TestHTTPClient.request(
                        path: IngestRoute.events.path, token: harness.token, body: body))
                let response = try await client.readResponse()
                samples.append(clock.now - started)
                #expect(response.status == 200)
            }
            report("keep-alive", samples)
            #expect(percentile(samples, 50) < LatencyTests.keepAliveMedianCeiling)
            if LatencyTests.isIsolated {
                #expect(percentile(samples, 99) < LatencyTests.ceiling)
            }
        }
    }

    @Test("Answers a fresh connection well inside a hook's budget")
    func measuresConnectionLatency() async throws {
        try await EndpointFactory.withEndpoint { harness in
            var samples: [Duration] = []
            let clock = ContinuousClock()
            for index in 0..<60 {
                let started = clock.now
                _ = try await harness.post(
                    token: harness.token,
                    body: EventPayload.json(kind: "turnStarted", session: "fresh-\(index)"))
                samples.append(clock.now - started)
            }
            report("connect + post", samples)
            #expect(percentile(samples, 50) < LatencyTests.connectionMedianCeiling)
            if LatencyTests.isIsolated {
                // p95, not p99, even here: nearest-rank over 60 samples puts
                // index 99 % at 59, which is the *maximum*. Asserting that would
                // mean every one of 60 connection handshakes has to beat the
                // ceiling, and one descheduled connect fails the suite — a
                // measurement running alone is still a measurement on a shared
                // VM. p95 admits only the two worst round trips. The keep-alive
                // test has 300 samples and can afford a real p99.
                #expect(percentile(samples, 95) < LatencyTests.ceiling)
            }
        }
    }

    /// Nearest-rank, which is exact but degenerates: for `rank` high enough
    /// relative to `samples.count` the index lands on the last element and the
    /// "percentile" is the maximum. Check the arithmetic before asserting on a
    /// small sample.
    private func percentile(_ samples: [Duration], _ rank: Int) -> Duration {
        guard !samples.isEmpty else { return .zero }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, max(0, (rank * sorted.count) / 100))
        return sorted[index]
    }

    /// Prints which statistic was in force alongside the numbers, so a CI log
    /// says on its face whether its tail was asserted or merely recorded.
    private func report(_ label: String, _ samples: [Duration]) {
        // Both components. `attoseconds` is only the sub-second part, so
        // reading it alone printed a 1.2 s sample as "200.000 ms" — and a
        // multi-second stall is precisely the event this line exists to show.
        let milliseconds = { (duration: Duration) -> String in
            let parts = duration.components
            return String(
                format: "%.3f ms",
                Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15)
        }
        let mode = LatencyTests.isIsolated ? "isolated: tail asserted" : "loaded: median asserted"
        // The mode sits next to the label rather than at the end of the line so
        // that one fixed string proves both that the measurement ran *and* that
        // the strict statistic was in force. `make timing-proofs` greps for
        // exactly that string: without it the target would pass on a run where
        // the variable never reached the process and no tail was asserted.
        print(
            "ingest latency [\(label)] (\(mode)) n=\(samples.count) "
                + "p50=\(milliseconds(percentile(samples, 50))) "
                + "p95=\(milliseconds(percentile(samples, 95))) "
                + "p99=\(milliseconds(percentile(samples, 99)))")
    }
}
