import AgentBarCore
import Foundation
import Testing

@testable import AgentBarUI

/// The diagnostics surface's own vocabulary.
///
/// What the checks actually find lives in the app target, next to the two
/// installers it asks. What is testable here is the part that decides what the
/// user sees: which verdict wins, what the summary says, and that the text put
/// on the clipboard carries every check and every remedy.
@MainActor
@Suite("Diagnostics")
struct DiagnosticsTests {

    private static func report(
        _ checks: [DiagnosticsCheck],
        counters: [DiagnosticsCounter] = [],
        recent: [DiagnosticsEntry] = []
    ) -> DiagnosticsReport {
        DiagnosticsReport(
            checks: checks, counters: counters, recent: recent, resources: "70 MB resident",
            takenAt: Date(timeIntervalSince1970: 0))
    }

    private static func check(
        _ id: String, _ verdict: DiagnosticsVerdict, remedy: String? = nil
    ) -> DiagnosticsCheck {
        DiagnosticsCheck(id: id, title: id, verdict: verdict, detail: "detail", remedy: remedy)
    }

    @Test("A fault outranks a warning, and a warning outranks nothing")
    func theWorstVerdictWins() {
        let clean = Self.report([Self.check("a", .pass), Self.check("b", .pass)])
        let warned = Self.report([Self.check("a", .pass), Self.check("b", .warn)])
        let failed = Self.report([Self.check("a", .warn), Self.check("b", .fail)])

        #expect(SettingsView.summaryVerdict(clean) == .pass)
        #expect(SettingsView.summaryVerdict(warned) == .warn)
        #expect(SettingsView.summaryVerdict(failed) == .fail)
        #expect(clean.summary.contains("in order"))
        #expect(warned.summary.contains("1 of 2"))
        #expect(failed.summary.contains("1 of 2"))
    }

    @Test("Every verdict carries a shape as well as a colour")
    func everyVerdictHasASilhouette() {
        let verdicts: [DiagnosticsVerdict] = [.pass, .warn, .fail]
        #expect(Set(verdicts.map { $0.indicator.kind }).count == 3)
        #expect(Set(verdicts.map { $0.indicator.color }).count == 3)
    }

    /// This text is what goes into a bug report, so nothing may be missing from
    /// it — least of all the remedy, which is the half the reader has to act on.
    @Test("The copied text carries every check, every remedy and every line")
    func plainTextIsComplete() {
        let report = Self.report(
            [
                Self.check("endpoint", .pass),
                Self.check("codex", .fail, remedy: "press Repair"),
            ],
            counters: [DiagnosticsCounter(id: "applied", label: "applied", value: 7)],
            recent: [
                DiagnosticsEntry(
                    id: 1, at: Date(timeIntervalSince1970: 0), severity: .fault,
                    message: "transport failure: broken pipe")
            ])
        let text = report.plainText

        #expect(text.contains("[PASS] endpoint"))
        #expect(text.contains("[FAIL] codex"))
        #expect(text.contains("→ press Repair"))
        #expect(text.contains("applied: 7"))
        #expect(text.contains("70 MB resident"))
        #expect(text.contains("transport failure: broken pipe"))
    }

    @Test("An empty log says so rather than being absent")
    func anEmptyLogIsStillARow() {
        let text = Self.report([Self.check("a", .pass)]).plainText
        #expect(!text.contains("newest first"))
    }

    // MARK: - The provider rows

    /// The rung → verdict table, which is where a diagnostics surface most
    /// easily starts lying: two of these six are choices or one button away
    /// from working, and painting them red would make the surface that exists
    /// to explain silence the thing that misexplains it.
    @Test(
        "Every integration rung maps to the verdict it deserves",
        arguments: [
            (IntegrationCondition.connected, DiagnosticsVerdict.pass),
            (.notConnected, .warn),
            (.needsRepair, .warn),
            (.notTrusted, .warn),
            (.notReceiving, .fail),
            (.settingsUnreadable, .fail),
        ] as [(IntegrationCondition, DiagnosticsVerdict)]
    )
    func everyRungHasAVerdict(condition: IntegrationCondition, verdict: DiagnosticsVerdict) {
        let check = DiagnosticsCheck(
            integration: IntegrationStatus(provider: .codex, condition: condition))
        #expect(check.verdict == verdict)
        #expect(check.detail == condition.statusLine)
        #expect(check.id == "integration.codex")
    }

    /// A working integration has nothing for the user to do, and inventing
    /// something would be worse than saying nothing.
    @Test("A connected provider gets no remedy")
    func connectedNeedsNothing() {
        let check = DiagnosticsCheck(
            integration: IntegrationStatus(provider: .claudeCode, condition: .connected))
        #expect(check.remedy == nil)
    }

    /// A drift sentence is a diagnosis, not an instruction. The row has to end
    /// with something the reader can act on.
    @Test("A diagnosis is followed by the button that answers it")
    func aDiagnosisGainsAnAction() {
        let check = DiagnosticsCheck(
            integration: IntegrationStatus(
                provider: .claudeCode, condition: .needsRepair,
                detail: "the installed handlers carry an old token"))
        let remedy = try? #require(check.remedy)
        #expect(remedy?.contains("the installed handlers carry an old token") == true)
        #expect(remedy?.contains("Repair") == true)
        #expect(remedy?.contains("Claude Code") == true)
    }

    /// `Installed, not trusted` already says to run `/hooks`, and the `Trust`
    /// button only re-reads what Codex decided — appending it would offer a
    /// control that cannot do what the sentence asks for.
    @Test("An instruction is left as it is")
    func anInstructionIsNotDecorated() {
        let check = DiagnosticsCheck(
            integration: IntegrationStatus(
                provider: .codex, condition: .notTrusted,
                detail: "Run /hooks in Codex and trust the AgentBar entries"))
        #expect(check.remedy == "Run /hooks in Codex and trust the AgentBar entries")
    }

    // MARK: - The window's half

    @Test("Opening the window takes a reading")
    func appearingRunsTheSelfTest() async {
        let services = StubSettingsServices()
        let model = SettingsModel(services: services)
        await model.refresh()
        #expect(services.diagnosticsRuns == 1)
        #expect(model.diagnostics != nil)
    }

    @Test("Copy puts the whole report on the clipboard")
    func copyCopiesTheReport() async {
        let services = StubSettingsServices()
        let model = SettingsModel(services: services)
        model.copyDiagnostics()
        #expect(services.copied.isEmpty, "nothing to copy before the first reading")

        await model.runDiagnostics()
        model.copyDiagnostics()
        #expect(services.copied == [services.diagnosticsReport.plainText])
        #expect(model.didCopyDiagnostics)

        // A fresh reading replaces what the clipboard holds, so the confirmation
        // has to go with it — otherwise the section claims a report has been
        // copied when what is on the clipboard is the one before it.
        await model.runDiagnostics()
        #expect(!model.didCopyDiagnostics)
    }
}
