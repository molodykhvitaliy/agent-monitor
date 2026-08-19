import AgentBarCore
import Foundation

@testable import AgentBarPower

/// A `PowerAsserting` the test inspects instead of a real assertion.
///
/// A suite that took a real one would keep the developer's Mac awake while it
/// ran and would depend on IOKit answering, which is exactly the coupling the
/// seam exists to remove.
@MainActor
final class RecordingAssertion: PowerAsserting {
    /// What the holder was asked to do, in order. The whole point: the tests
    /// are about *when* an assertion is taken and released, not about IOKit.
    private(set) var calls: [Call] = []
    private(set) var details: [String] = []
    private(set) var leases: [Duration] = []

    /// Set to make the next `take` refuse, the way a system that would not give
    /// an assertion does.
    var refusesTake: PowerAssertionError?
    var refusesRenew: PowerAssertionError?
    var refusesRelease: PowerAssertionError?

    enum Call: Equatable {
        case take
        case renew
        case release
    }

    private(set) var isHeld = false

    var takes: Int { calls.count { $0 == .take } }
    var renewals: Int { calls.count { $0 == .renew } }
    var releases: Int { calls.count { $0 == .release } }
    var lastDetails: String? { details.last }

    func take(name: String, details: String, lease: Duration) throws {
        calls.append(.take)
        self.details.append(details)
        leases.append(lease)
        if let refusesTake { throw refusesTake }
        isHeld = true
    }

    func renew(details: String, lease: Duration) throws {
        calls.append(.renew)
        self.details.append(details)
        leases.append(lease)
        if let refusesRenew { throw refusesRenew }
    }

    func release() throws {
        guard isHeld else { return }
        calls.append(.release)
        // Dropped whatever happened, exactly as the real holder does: every
        // documented failure means the id is not one the system knows.
        isHeld = false
        if let refusesRelease { throw refusesRelease }
    }
}

/// A clock the test drives by hand.
///
/// Restated here rather than shared with `AgentBarCoreTests`: the two suites are
/// separate targets, and `TimeSource` is public precisely so a consumer can
/// supply its own. Advancing both readings together is also how a machine sleep
/// is simulated — one large jump is what `ContinuousClock` reports on wake.
final class ManualTimeSource: TimeSource, @unchecked Sendable {
    private var elapsed: Duration = .zero
    private var wall: Date

    init(wallTime: Date = Fixture.epoch) {
        wall = wallTime
    }

    var now: MonotonicInstant { MonotonicInstant.origin.advanced(by: elapsed) }

    var wallTime: Date { wall }

    func advance(by amount: Duration) {
        elapsed += amount
        wall = wall.addingTimeInterval(amount.seconds)
    }
}

extension Duration {
    var seconds: TimeInterval {
        let (whole, attoseconds) = components
        return TimeInterval(whole) + TimeInterval(attoseconds) * 1e-18
    }

    static func minutes(_ count: Int) -> Duration { .seconds(count * 60) }
    static func hours(_ count: Int) -> Duration { .seconds(count * 60 * 60) }
}

/// Event construction, so a test reads like the session it describes.
enum Fixture {
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    static func date(_ offset: TimeInterval) -> Date { epoch.addingTimeInterval(offset) }

    static func event(
        _ kind: EventKind,
        session: String = "session-1",
        cwd: String = "/Users/dev/agentbar",
        at offset: TimeInterval = 0,
        tool: ToolRef? = nil,
        toolUseId: String? = nil
    ) -> AgentEvent {
        AgentEvent(
            provider: .claudeCode,
            sessionId: SessionID(session),
            kind: kind,
            cwd: URL(filePath: cwd),
            timestamp: Fixture.date(offset),
            tool: tool,
            toolUseId: toolUseId.map(ToolUseID.init))
    }

    static let bash = ToolRef(name: "Bash", invocation: "swift test --parallel")

    /// A snapshot built by hand, for the decision tests that are not about a
    /// store at all.
    static func snapshot(states: [SessionState]) -> StoreSnapshot {
        let sessions = states.enumerated().map { index, state in
            Session(
                id: SessionID("session-\(index)"),
                provider: .claudeCode,
                project: PathProjectResolver().project(for: URL(filePath: "/Users/dev/agentbar")),
                model: nil,
                state: state,
                currentTool: state == .working ? bash : nil,
                activeSubagentCount: 0,
                startedAt: epoch,
                lastEventAt: epoch,
                uptime: .seconds(10),
                timeInState: .seconds(10),
                timeSinceLastEvent: .zero)
        }
        return StoreSnapshot(
            takenAt: epoch,
            projects: sessions.isEmpty
                ? [] : [ProjectGroup(project: sessions[0].project, sessions: sessions)])
    }
}

/// A snapshot source a test can stop in the middle of.
///
/// Reading the store suspends, and what happens across that suspension is where
/// the interesting failures live: `stop()` landing between the read and the
/// decision would otherwise leave an assertion nobody is left to release.
@MainActor
final class GatedSnapshotSource {
    private let store: SessionStore
    /// Set before the read that should be caught in the middle.
    var isGated = false

    private var held: CheckedContinuation<Void, Never>?
    private var watcher: CheckedContinuation<Void, Never>?
    private var hasArrived = false

    init(store: SessionStore) {
        self.store = store
    }

    func read() async -> StoreSnapshot {
        if isGated {
            hasArrived = true
            watcher?.resume()
            watcher = nil
            await withCheckedContinuation { held = $0 }
        }
        return await store.snapshot()
    }

    /// Returns once a read has reached the gate.
    func waitUntilReading() async {
        guard !hasArrived else { return }
        await withCheckedContinuation { watcher = $0 }
    }

    /// Lets the waiting read finish.
    func resume() {
        held?.resume()
        held = nil
    }
}
