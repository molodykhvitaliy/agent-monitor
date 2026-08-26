import AgentBarCore
import Foundation
import Testing

@testable import CodexAdapter

/// The two sentences a report gives the card, and the one distinction that
/// decides whether an empty panel says `All quiet` or shows the onboarding card.
///
/// Both used to live in the app target, which has no test target — so a rule
/// that governs the panel's headline behaviour was covered by nothing.
@Suite("Codex drift summary")
struct DriftSummaryTests {

    private static func report(_ state: CodexInstallState) -> CodexInstallReport {
        CodexInstallReport(
            hooksURL: URL(filePath: "/tmp/hooks.json"), state: state, overlaps: [], warnings: [])
    }

    @Test("No drift, no sentence")
    func nothingToSummarise() {
        #expect(Self.report(.installed).driftSummary == nil)
        #expect(Self.report(.notInstalled).driftSummary == nil)
        #expect(!Self.report(.installed).silencesEveryHandler)
    }

    @Test("One drift reads as its own sentence")
    func oneDriftIsItsOwnSentence() {
        let drift = CodexInstallDrift.missingHandler(event: "Stop")
        #expect(Self.report(.needsRepair([drift])).driftSummary == drift.description)
    }

    /// A moved app is one fact, not eight identical lines nobody reads.
    @Test("The rest are counted rather than listed")
    func theRestAreCounted() {
        let summary = Self.report(
            .needsRepair([
                .missingHandler(event: "Stop"),
                .missingHandler(event: "SessionEnd"),
                .timeoutChanged(event: "Stop", found: 600, expected: 2),
            ])
        ).driftSummary
        #expect(summary == "no hook on Stop and 2 more")
    }

    /// The distinction the panel's empty state turns on. A stale timeout leaves
    /// hooks that still run; a helper that is not there leaves nine hooks that
    /// fail inside the user's own session.
    @Test("Only a helper that Codex cannot run silences everything")
    func onlyAMissingHelperSilencesEverything() {
        #expect(
            Self.report(.needsRepair([.helperMissing(path: "/gone")])).silencesEveryHandler)
        #expect(
            Self.report(.needsRepair([.helperMoved(found: "/old", expected: "/new")]))
                .silencesEveryHandler)
        #expect(
            !Self.report(.needsRepair([.timeoutChanged(event: "Stop", found: 600, expected: 2)]))
                .silencesEveryHandler)
        #expect(!Self.report(.needsRepair([.duplicateHandler(event: "Stop")])).silencesEveryHandler)
    }
}

/// The helper's whole budget, against the one second Codex gives a `SessionEnd`
/// hook.
///
/// > **The arithmetic that used to omit its first term.** The drain ceiling and
/// > the relay total were chosen against each other and their sum described as
/// > the worst path — leaving out `execve` and dyld, which
/// > `HelperTimingProof` measured at 74.2 ms max over forty runs. This is that
/// > sum, spawn included, and it is asserted rather than argued so the next
/// > change to either constant has to answer for the margin.
@Suite("Codex helper budget")
struct HelperBudgetTests {

    @Test("The worst helper run fits inside the SessionEnd timeout")
    func theWorstRunFits() {
        let cap = Duration.seconds(CodexHookHandler.sessionEndTimeout)
        #expect(CodexHookHandler.worstCaseHelperRun < cap)
    }

    /// Not merely "fits": a margin thin enough to be lost to one slow spawn is
    /// not a margin.
    ///
    /// 150 ms is the floor, and the floor is where it is because the two
    /// constants under it are each already about three times their own measured
    /// worst case — the drain's ceiling against a 105 ms 4 MB payload on a
    /// loaded machine, the allowance against a 74.2 ms spawn. Buying a wider
    /// margin here would mean tightening one of those towards the case it exists
    /// to survive, and dropping a real event is a worse outcome than a
    /// `SessionEnd` hook Codex stops at one second: by then the payload has
    /// either been delivered or it has not, and nothing waits on the answer.
    @Test("And leaves 150 ms in hand on top of that")
    func theMarginIsRealRatherThanNominal() {
        let cap = Duration.seconds(CodexHookHandler.sessionEndTimeout)
        #expect(cap - CodexHookHandler.worstCaseHelperRun >= .milliseconds(150))
    }

    @Test("The allowance covers twice the worst spawn ever measured")
    func theAllowanceIsGenerous() {
        // 74.2 ms max over forty runs, HelperTimingProof, 2026-08-26.
        #expect(CodexHookHandler.helperSpawnAllowance >= .milliseconds(150))
    }

    /// The eight other events have a much larger cap, so the same budget leaves
    /// more than a second spare there. Stated so a future change that tightens
    /// `defaultTimeout` towards `sessionEndTimeout` fails here first.
    @Test("Every other event has over a second of headroom")
    func theOtherEventsAreComfortable() {
        let cap = Duration.seconds(CodexHookHandler.defaultTimeout)
        #expect(cap - CodexHookHandler.worstCaseHelperRun > .seconds(1))
    }
}
