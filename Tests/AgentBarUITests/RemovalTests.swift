import AgentBarCore
import Foundation
import Testing

@testable import AgentBarUI

/// The uninstaller's vocabulary and the window's half of the flow.
///
/// What the app target actually deletes is the two installers' `uninstall()`,
/// which have suites of their own. What is testable here is the part a user
/// reads: that a clean removal says so, that a refusal is never counted as a
/// success, and that a step AgentBar declined to touch is never counted as a
/// failure.
@MainActor
@Suite("Removal")
struct RemovalTests {

    private static func step(
        _ id: String, _ outcome: RemovalOutcome
    ) -> RemovalStep {
        RemovalStep(id: id, title: id, location: "~/\(id)", outcome: outcome)
    }

    @Test("A removal with nothing left behind says so")
    func cleanRemovalReadsClean() {
        let report = RemovalReport(steps: [
            Self.step("hooks", .removed(detail: "backed up")),
            Self.step("helper", .nothingToRemove),
        ])
        #expect(!report.hasFailures)
        #expect(report.failures.isEmpty)
        #expect(report.summary.contains("never been installed"))
    }

    /// The whole point of the report: a step that did not happen has to be
    /// visible, and the summary has to count it.
    @Test("A refusal is counted and named")
    func failureIsCounted() {
        let report = RemovalReport(steps: [
            Self.step("hooks", .removed()),
            Self.step("helper", .failed(reason: "permission denied", remedy: "delete it by hand")),
        ])
        #expect(report.hasFailures)
        #expect(report.failures.map(\.id) == ["helper"])
        #expect(report.summary.contains("1 of 2"))
    }

    /// `config.toml` is the case this exists for. AgentBar never writes that
    /// file, so the trust record it leaves is not a failure of the removal — and
    /// counting it as one would make every clean uninstall report look unclean.
    @Test("Something deliberately left alone is not a failure")
    func leftAloneIsNotAFailure() {
        let report = RemovalReport(steps: [
            Self.step("hooks", .removed()),
            Self.step(
                "trust",
                .leftAlone(reason: "AgentBar never writes this file", remedy: "delete the table")),
        ])
        #expect(!report.hasFailures)
        #expect(report.leftAlone.map(\.id) == ["trust"])
        #expect(report.summary.contains("never been installed"))
    }

    @Test("Every outcome has a shape as well as a colour")
    func everyOutcomeHasASilhouette() {
        let outcomes: [RemovalOutcome] = [
            .removed(), .nothingToRemove, .leftAlone(reason: "a", remedy: "b"),
            .failed(reason: "a", remedy: "b"),
        ]
        let shapes = outcomes.map(SettingsView.shape(for:))
        let inks = outcomes.map(SettingsView.ink(for:))
        let verdicts = outcomes.map(SettingsView.verdict(for:))
        #expect(Set(shapes).count == outcomes.count)
        #expect(Set(inks).count == outcomes.count)
        #expect(Set(verdicts).count == outcomes.count)
    }

    // MARK: - The window's half

    @Test("Removing runs once and keeps its report")
    func removalRunsOnceAndIsRemembered() async {
        let services = StubSettingsServices()
        let model = SettingsModel(services: services)
        #expect(model.removal == nil)

        await model.removeEverything()
        #expect(services.removals == 1)
        #expect(model.removal?.steps.count == 1)
        #expect(!model.isRemoving)
    }

    /// The report names files the user still has to open by hand. It must not
    /// disappear because they touched a toggle afterwards.
    @Test("An edit afterwards does not clear the report")
    func reportSurvivesAnEdit() async {
        let services = StubSettingsServices()
        let model = SettingsModel(services: services)
        await model.removeEverything()
        model.setEnabled(false)
        #expect(model.removal != nil)
    }

    /// A clean removal stops the endpoint and deletes the helper, so a self-test
    /// taken afterwards reports both as faults and offers remedies that would
    /// undo the removal — beside a summary saying nothing is left. The section
    /// says *not checked* instead.
    @Test("A removal does not leave a self-test telling the user to undo it")
    func removalDropsTheSelfTest() async {
        let services = StubSettingsServices()
        let model = SettingsModel(services: services)
        await model.refresh()
        #expect(model.diagnostics != nil)
        let readingsBefore = services.diagnosticsRuns

        await model.removeEverything()
        #expect(model.hasRemoved)
        #expect(model.diagnostics == nil)
        #expect(
            services.diagnosticsRuns == readingsBefore,
            "the removal re-ran the self-test it had just invalidated")

        // Asking for one anyway is what makes it meaningful again.
        await model.runDiagnostics()
        #expect(!model.hasRemoved)
        #expect(model.diagnostics != nil)
    }

    @Test("Reveal and Quit reach the assembly, and nothing else does")
    func lastStepIsTheUsers() async {
        let services = StubSettingsServices()
        let model = SettingsModel(services: services)
        model.revealApplication()
        model.quitApplication()
        #expect(services.reveals == 1)
        #expect(services.quits == 1)
    }
}
