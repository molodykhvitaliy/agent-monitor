import AgentBarCore
import Foundation
import Testing

@testable import ClaudeCodeAdapter

/// The two sentences a report gives the card.
///
/// Both used to live in the app target, which has no test target — so the rule
/// that decides whether an empty panel says `All quiet` or shows the onboarding
/// card was covered by nothing.
@Suite("Claude Code drift summary")
struct DriftSummaryTests {

    private static func report(_ state: ClaudeCodeInstallState) -> ClaudeCodeInstallReport {
        ClaudeCodeInstallReport(
            settingsURL: URL(filePath: "/tmp/settings.json"), state: state, overlaps: [],
            warnings: [])
    }

    @Test("No drift, no sentence")
    func nothingToSummarise() {
        #expect(Self.report(.installed).driftSummary == nil)
        #expect(Self.report(.notInstalled).driftSummary == nil)
        #expect(!Self.report(.installed).silencesEveryHandler)
    }

    @Test("One drift reads as its own sentence, the rest are counted")
    func oneSentenceAndACount() {
        let first = ClaudeCodeInstallDrift.tokenChanged
        #expect(Self.report(.needsRepair([first])).driftSummary == first.description)
        #expect(
            Self.report(.needsRepair([first, .missingHandler(event: "Stop")])).driftSummary
                == "\(first.description) and 1 more")
    }

    /// A stale token leaves handlers that run and are refused; an allow-list
    /// that does not name AgentBar leaves handlers that never run at all. Only
    /// the second is silence.
    @Test("Only an allow-list that excludes AgentBar silences everything")
    func onlyTheAllowListSilencesEverything() {
        #expect(Self.report(.needsRepair([.urlNotAllowed])).silencesEveryHandler)
        #expect(!Self.report(.needsRepair([.tokenChanged])).silencesEveryHandler)
        #expect(
            !Self.report(.needsRepair([.endpointChanged(found: "a", expected: "b")]))
                .silencesEveryHandler)
    }
}
