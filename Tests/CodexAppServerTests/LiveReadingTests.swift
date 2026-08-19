import AgentBarCore
import Foundation
import Testing

@testable import CodexAppServer

/// The real thing: the installed `codex`, the developer's own account, the
/// whole path from discovery to `[QuotaWindow]`.
///
/// Gated behind `AGENTBAR_CODEX_LIVE=1`, like the render and power proofs, and
/// for the same reason — it reaches outside the process. It also costs a network
/// round trip made by Codex against a real account, so it must never run on a
/// timer or on a runner.
///
/// ```
/// AGENTBAR_CODEX_LIVE=1 swift test --filter LiveReading
/// ```
@Suite(
    "Live reading",
    .enabled(if: ProcessInfo.processInfo.environment["AGENTBAR_CODEX_LIVE"] == "1"),
    .serialized)
struct LiveReadingTests {

    @Test("The installed codex answers, and its answer becomes windows")
    func readsTheRealAccount() async throws {
        let executable = try #require(
            CodexExecutable.locate(),
            "no codex on this machine — the suite has nothing to talk to")
        print("codex: \(executable.url.path(percentEncoded: false))")

        let transport = CodexProcessTransport(executable: executable.url)
        let windows = try await AppServerExchange.run(
            transport: transport, clientVersion: "0.1.0"
        ) { exchange, version in
            print("codex version: \(version)")
            let response = try await AccountMethods.readRateLimits(on: exchange)
            print("buckets: \(response.rateLimitsByLimitId?.keys.sorted() ?? [])")
            return RateLimitMapping.windows(from: response)
        }

        for window in windows {
            let percent = window.fractionUsed.map { Int(($0 * 100).rounded()) }
            print(
                """
                window: id=\(window.limitId ?? "—") name=\(window.limitName ?? "—") \
                duration=\(window.windowDuration.map(String.init(describing:)) ?? "—") \
                used=\(percent.map { "\($0)%" } ?? "—") \
                resets=\(window.resetsAt.map(String.init(describing:)) ?? "—")
                """)
        }
        // A signed-in account reports at least one window. If this fails on a
        // machine with a working Codex, the mapping has stopped agreeing with
        // the protocol and `make schema-sync` is the next thing to run.
        #expect(!windows.isEmpty)
        #expect(windows.allSatisfy { ($0.fractionUsed ?? 0) >= 0 })
        #expect(await ProcessTransportTests.waitForExit(transport), "the child must be gone")
    }

    /// End to end through the service, which is what the app actually runs:
    /// discovery, the exchange, the mapping, and the reading the panel reads.
    @Test("The service fills its reading from the real account")
    func refreshesThroughTheService() async {
        let service = QuotaService(clientVersion: "0.1.0")
        await service.refresh(reason: "live test")
        let windows = await service.windows()
        #expect(!windows.isEmpty)
    }
}
