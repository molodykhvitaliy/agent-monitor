import AgentBarCore
import Foundation

@testable import AgentBarUI

/// Sessions and snapshots for the view-level suites.
///
/// Built directly rather than driven through `SessionStore`: these suites are
/// about what a reading *renders as*, and constructing the reading is the
/// shortest way to reach a state the store would need a scripted session to
/// produce.
enum UIFixture {
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    static func session(
        _ id: String = "session-1",
        provider: Provider = .claudeCode,
        project: String = "/Users/dev/agentbar",
        state: SessionState = .working,
        tool: ToolRef? = nil,
        subagents: Int = 0,
        timeInState: Duration = .seconds(38),
        silence: Duration = .seconds(38)
    ) -> Session {
        Session(
            id: SessionID(id),
            provider: provider,
            project: PathProjectResolver().project(for: URL(filePath: project)),
            model: nil,
            state: state,
            currentTool: state == .working ? tool : nil,
            activeSubagentCount: subagents,
            startedAt: epoch,
            lastEventAt: epoch,
            uptime: .seconds(600),
            timeInState: timeInState,
            timeSinceLastEvent: silence)
    }

    static func snapshot(_ sessions: [Session]) -> StoreSnapshot {
        let grouped = Dictionary(grouping: sessions) { $0.project.id }
        return StoreSnapshot(
            takenAt: epoch,
            projects: grouped.values.compactMap { group in
                guard let first = group.first else { return nil }
                return ProjectGroup(project: first.project, sessions: group)
            })
    }

    static func status(
        _ provider: Provider = .claudeCode,
        _ condition: IntegrationCondition,
        preventsEvents: Bool? = nil
    ) -> IntegrationStatus {
        IntegrationStatus(
            provider: provider, condition: condition, preventsEvents: preventsEvents)
    }

    static func project(_ path: String) -> ProjectRef {
        PathProjectResolver().project(for: URL(filePath: path))
    }
}

/// A `PanelServices` a test drives by hand.
@MainActor
final class StubServices: PanelServices {
    var storedSnapshot: StoreSnapshot = .empty
    var storedStatuses: [IntegrationStatus] = []
    var storedWindows: [UsageWindow] = []
    var result: IntegrationActionResult = .changed

    private(set) var sweeps = 0
    private(set) var snapshots = 0
    private(set) var statusReads = 0
    private(set) var performed: [(action: IntegrationAction, provider: Provider)] = []

    func snapshot() async -> StoreSnapshot {
        snapshots += 1
        return storedSnapshot
    }

    func sweep() async { sweeps += 1 }

    func integrationStatuses() async -> [IntegrationStatus] {
        statusReads += 1
        return storedStatuses
    }

    func perform(
        _ action: IntegrationAction, for provider: Provider
    ) async -> IntegrationActionResult {
        // Suspends before recording, because the real one does: every install
        // action crosses into `IngestService` or touches the disk. Without a
        // suspension point here nothing concurrent can interleave, and a test
        // for re-entrancy would pass against code that had no guard at all.
        await Task.yield()
        performed.append((action, provider))
        return result
    }

    func usageWindows() async -> [UsageWindow] { storedWindows }

    /// Counted rather than ignored: this is the whole of the "limits refresh
    /// while you are looking" feature at the seam, and the default
    /// implementation on `PanelServices` is a no-op — so a stub that did not
    /// override it would let the feature be deleted with a green suite.
    private(set) var usageRefreshRequests = 0

    func requestUsageRefresh() { usageRefreshRequests += 1 }

    var caffeineIndicator = CaffeineIndicator()
    private(set) var caffeineToggles = 0

    func caffeine() -> CaffeineIndicator { caffeineIndicator }

    func toggleCaffeine() { caffeineToggles += 1 }
}
