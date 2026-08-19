import Foundation
import Testing

@testable import AgentBarCore
@testable import AgentBarIngest

/// The step asks for a p99, and a number nobody records is a number nobody
/// notices moving.
///
/// The assertion is deliberately loose — a shared CI runner under load is not a
/// benchmarking environment, and a tight bound here would fail for reasons that
/// have nothing to do with this code. What it does catch is the class of
/// regression that matters: a per-request handshake, a lock held across a
/// socket read, an accidental sleep. Those cost milliseconds, not microseconds.
@Suite("Latency", .serialized)
struct LatencyTests {
    /// Far above anything healthy, and far below the smallest budget an agent
    /// gives a hook: Codex caps `SessionEnd` at one second.
    static let ceiling = Duration.milliseconds(100)

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
            #expect(percentile(samples, 99) < LatencyTests.ceiling)
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
            // p95, not p99: nearest-rank over 60 samples puts index 99 % at 59,
            // which is the *maximum*. Asserting that would require every one of
            // 60 connection handshakes on a shared runner to beat the ceiling,
            // and one descheduled connect would fail the suite. p95 still admits
            // only the two worst round trips. The keep-alive test has 300
            // samples and can afford a real p99.
            #expect(percentile(samples, 95) < LatencyTests.ceiling)
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

    private func report(_ label: String, _ samples: [Duration]) {
        let milliseconds = { (duration: Duration) -> String in
            String(format: "%.3f ms", Double(duration.components.attoseconds) / 1e15)
        }
        print(
            "ingest latency [\(label)] n=\(samples.count) "
                + "p50=\(milliseconds(percentile(samples, 50))) "
                + "p95=\(milliseconds(percentile(samples, 95))) "
                + "p99=\(milliseconds(percentile(samples, 99)))")
    }
}
