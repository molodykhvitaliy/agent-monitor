import AgentBarCore
import Foundation
import Testing

@testable import AgentBarPower

/// Whether the live proof was asked for.
///
/// A free type rather than a member of the suite: a `@Suite` trait cannot refer
/// to the type it is attached to. Same arrangement as `RenderOutput` in
/// `AgentBarUITests`.
enum LivePowerProof {
    nonisolated static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["AGENTBAR_POWER_LIVE"] != nil
    }

    /// What `pmset` says **this process** is holding, if anything.
    ///
    /// Filtered by pid rather than by name: AgentBar itself may well be running
    /// on the developer's machine while the proof runs, and a proof that read
    /// the app's assertion and called it its own would pass without having
    /// taken anything.
    static func heldAssertions() -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(bytes: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .filter { $0.contains("pid \(ProcessInfo.processInfo.processIdentifier)(") }
            .joined(separator: "\n")
    }

    /// The name this suite's own assertions carry, so a run is legible in
    /// `pmset` while it happens.
    static let name = "AgentBar test proof"
}

/// The real IOKit path, end to end, against a real `SessionStore`.
///
/// Off unless asked for, because it takes a real power assertion and reads
/// `pmset`: a suite that kept the developer's Mac awake every time it ran would
/// be its own bug. Everything it proves about *when* an assertion is taken is
/// already covered without IOKit; what only this can show is that the calls
/// themselves do what the header says.
///
/// ```
/// AGENTBAR_POWER_LIVE=1 swift test --filter AgentBarPowerTests
/// ```
@MainActor
@Suite(
    "Live power assertion",
    .serialized,
    .disabled(if: !LivePowerProof.isEnabled, "set AGENTBAR_POWER_LIVE to run"))
struct LiveAssertionProof {

    /// A watchdog measured in seconds rather than minutes, so the release the
    /// step's validation asks for can actually be waited out. Every ratio the
    /// real policy encodes is preserved.
    private static let impatient = WatchdogPolicy(
        workingTimeout: .seconds(4),
        openToolTimeout: .seconds(16),
        waitingTimeout: .seconds(30),
        restingTimeout: .seconds(60),
        evictionTimeout: .seconds(60))

    @Test("The assertion appears in pmset, and the watchdog takes it away")
    func watchdogReleasesARealAssertion() async throws {
        let store = SessionStore(watchdog: Self.impatient)
        let assertion = IOKitPowerAssertion()
        let controller = CaffeineController(
            assertion: assertion, settings: InMemoryCaffeineSettings())
        defer { controller.stop() }
        await controller.start { await store.snapshot() }

        await store.apply(
            AgentEvent(
                provider: .claudeCode,
                sessionId: SessionID("live-proof"),
                kind: .turnStarted,
                cwd: URL(filePath: "/Users/dev/agentbar"),
                timestamp: Date()))
        await controller.evaluate()
        #expect(assertion.isHeld)
        #expect(
            LivePowerProof.heldAssertions().contains("PreventUserIdleSystemSleep"),
            "the assertion is not visible to pmset")

        // Past the allowance for silent work. Nothing sweeps: `unknown` is
        // derived on read, which is what makes the release inevitable.
        try await Task.sleep(for: .seconds(6))
        await controller.evaluate()
        #expect(!assertion.isHeld)
        #expect(LivePowerProof.heldAssertions().isEmpty)
    }

    /// The safety net, with the lease shortened so it can be watched. Nothing
    /// renews here — which is exactly the failure it exists for: a live process
    /// that has stopped evaluating.
    @Test("An unrenewed lease expires by itself")
    func leaseExpires() async throws {
        let assertion = IOKitPowerAssertion()
        defer { try? assertion.release() }
        try assertion.take(
            name: LivePowerProof.name, details: "lease proof", lease: .seconds(2))
        #expect(LivePowerProof.heldAssertions().contains(LivePowerProof.name))
        #expect(assertion.isHeld)

        try await Task.sleep(for: .seconds(4))
        #expect(
            LivePowerProof.heldAssertions().isEmpty,
            "the lease did not expire — the safety net is not a net")
        // The holder still owns the id, and must not report a hold on the
        // strength of it: that is the one direction the indicator may not lie in.
        #expect(!assertion.isHeld)

        // And re-arming brings it back, which is how a recovered app recovers.
        try assertion.renew(details: "lease proof, re-armed", lease: .seconds(30))
        #expect(LivePowerProof.heldAssertions().contains(LivePowerProof.name))
        #expect(assertion.isHeld)
    }
}
