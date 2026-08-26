import AgentBarCore
import SwiftUI

/// The section a user opens when nothing is happening.
///
/// > **Step 11's requirement, in one place.** *"A user who sees nothing
/// > happening can find out why from inside the app."* Until now the answer to
/// > that was Console.app: `IngestDiagnostics` reached `os_log` and stopped
/// > there, so an adapter parse failure — the one class of fault the endpoint
/// > deliberately hides from the caller, because a hook must never see an error
/// > — was invisible to the person it was happening to.
///
/// Three blocks, in the order the question gets answered. The **self-test** says
/// whether each link in the chain exists at all. The **counters** say whether
/// anything has arrived and what was turned away. The **log** says what the
/// endpoint actually reported, newest first.
extension SettingsView {

    var diagnosticsSection: some View {
        Section {
            diagnosticsControls
            if model.hasRemoved, model.diagnostics == nil {
                // Not a fault, and not a reading either. See
                // `SettingsModel.removeEverything()`: a self-test taken after a
                // removal reports the removal as breakage and offers remedies
                // that would undo it.
                Text(
                    """
                    Not checked. AgentBar has just been removed on this Mac, so these \
                    checks would describe an app that is deliberately no longer connected.
                    """,
                    comment: "Diagnostics after a removal"
                )
                .font(DesignTokens.Text.caption)
                .foregroundStyle(accessibility.secondaryInk.color)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let report = model.diagnostics {
                ForEach(report.checks) { check in
                    diagnosticsCheckRow(check)
                }
                diagnosticsCounters(report)
                Text(report.resources)
                    .font(DesignTokens.Text.caption.monospacedDigit())
                    .foregroundStyle(accessibility.secondaryInk.color)
                    .fixedSize(horizontal: false, vertical: true)
                diagnosticsLog(report)
            }
        } header: {
            sectionHeader(SettingsSection.diagnostics.title, anchor: .diagnostics)
        } footer: {
            footnote(
                String(
                    localized: """
                        AgentBar answers every hook with success whatever happens, so a payload \
                        it could not read is invisible to the agent that sent it. This is where \
                        those show up.
                        """,
                    comment: "Explains why a diagnostics surface exists"))
        }
    }

    @ViewBuilder private var diagnosticsControls: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.small) {
            if let report = model.diagnostics {
                StateShapeView(
                    kind: Self.summaryVerdict(report).indicator.kind,
                    size: StateShapeView.rowSize(for: Self.summaryVerdict(report).indicator.kind),
                    color: Self.summaryVerdict(report).indicator.color.color)
                Text(report.summary)
                    .font(DesignTokens.Text.body)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.hasRemoved {
                Text("Removed", comment: "Diagnostics summary after a removal")
                    .font(DesignTokens.Text.body)
                    .foregroundStyle(accessibility.secondaryInk.color)
            } else {
                Text("Checking…", comment: "Diagnostics before the first reading")
                    .font(DesignTokens.Text.body)
                    .foregroundStyle(accessibility.secondaryInk.color)
            }
            Spacer(minLength: DesignTokens.Space.small)
            Button {
                Task { await model.runDiagnostics() }
            } label: {
                Text("Run Again", comment: "Button")
            }
            .disabled(model.isDiagnosing)
            Button(action: model.copyDiagnostics) {
                Text("Copy", comment: "Button that copies the diagnostics report")
            }
            .disabled(model.diagnostics == nil)
            if model.didCopyDiagnostics {
                Text("Copied", comment: "Confirmation beside the diagnostics Copy button")
                    .font(DesignTokens.Text.caption)
                    .foregroundStyle(accessibility.secondaryInk.color)
            }
        }
    }

    private func diagnosticsCheckRow(_ check: DiagnosticsCheck) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.tiny) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.small) {
                StateShapeView(
                    kind: check.verdict.indicator.kind,
                    size: StateShapeView.rowSize(for: check.verdict.indicator.kind),
                    color: check.verdict.indicator.color.color)
                Text(check.title)
                    .font(DesignTokens.Text.rowTitle)
                Spacer(minLength: DesignTokens.Space.small)
                Text(check.detail)
                    .font(DesignTokens.Text.caption)
                    .foregroundStyle(accessibility.secondaryInk.color)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let remedy = check.remedy {
                Text(remedy)
                    .font(DesignTokens.Text.caption)
                    .foregroundStyle(check.verdict.indicator.color.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// One wrapped line of `label n`, monospaced digits so the numbers do not
    /// dance while a busy session moves them.
    private func diagnosticsCounters(_ report: DiagnosticsReport) -> some View {
        FlowingCounters(counters: report.counters)
    }

    @ViewBuilder private func diagnosticsLog(_ report: DiagnosticsReport) -> some View {
        if report.recent.isEmpty {
            Text(
                "The endpoint has reported nothing since it started.",
                comment: "Empty diagnostics log"
            )
            .font(DesignTokens.Text.caption)
            .foregroundStyle(accessibility.secondaryInk.color)
        } else {
            VStack(alignment: .leading, spacing: DesignTokens.Space.tiny) {
                ForEach(report.recent) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.small) {
                        Text(entry.at.formatted(date: .omitted, time: .standard))
                            .font(DesignTokens.Text.caption.monospacedDigit())
                            .foregroundStyle(accessibility.secondaryInk.color)
                        Text(entry.message)
                            .font(DesignTokens.Text.caption)
                            .foregroundStyle(entry.severity.color.color)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .textSelection(.enabled)
        }
    }

    /// The worst verdict in the report, which is what the summary line shows.
    static func summaryVerdict(_ report: DiagnosticsReport) -> DiagnosticsVerdict {
        if report.hasFault { return .fail }
        if report.hasWarning { return .warn }
        return .pass
    }
}

/// The counters, laid out as a wrapping run of `label n` pairs.
///
/// A `Grid` would give them columns nobody needs and a fixed width the window
/// would then have to honour; `ViewThatFits` would drop some of them. A flow
/// layout keeps every counter visible at any window width, which is the only
/// requirement this block has.
private struct FlowingCounters: View {
    let counters: [DiagnosticsCounter]

    @Environment(\.accessibilityPreferences) private var accessibility

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(counters)
            wrapped
        }
    }

    private var wrapped: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.tiny) {
            ForEach(Array(counters.chunked(into: 3).enumerated()), id: \.offset) { pair in
                row(pair.element)
            }
        }
    }

    private func row(_ counters: [DiagnosticsCounter]) -> some View {
        HStack(spacing: DesignTokens.Space.medium) {
            ForEach(counters) { counter in
                HStack(spacing: DesignTokens.Space.tiny) {
                    Text(counter.label)
                        .font(DesignTokens.Text.caption)
                        .foregroundStyle(accessibility.secondaryInk.color)
                    Text(counter.value, format: .number)
                        .font(DesignTokens.Text.caption.monospacedDigit())
                        .foregroundStyle(
                            counter.isFault && counter.value > 0
                                ? ColorToken.stateFailed.color : ColorToken.ink900.color)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

extension Array {
    /// Fixed-size runs, last one short. Used only by the counter block, which
    /// needs a stable wrap rather than a layout that reflows per character.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
