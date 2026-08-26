import AgentBarCore
import SwiftUI

/// The last section of the settings window: the door out.
///
/// > **Why an uninstaller is a feature and not a courtesy.** AgentBar's first
/// > non-negotiable is that both tools behave exactly as if it had never existed
/// > when it is not running — *including when it has been uninstalled*. Dragging
/// > `AgentBar.app` to the Trash does not satisfy that on its own: nine `http`
/// > handlers stay in `~/.claude/settings.json` posting into a refused port, and
/// > nine `command` handlers stay in `~/.codex/hooks.json` spawning a helper
/// > that still exists, on every tool call, for ever. The installers have always
/// > known how to undo all of it; what was missing was a door.
///
/// > **It never guesses on the way out.** Every step removes exactly what
/// > AgentBar wrote, by the marker it wrote it with. A step that cannot do that
/// > — a settings file that will not parse, a file the filesystem refuses to
/// > delete — does **not** fall back to something that looks similar. It reports
/// > the file and the thing to look for in it, and the sequence carries on to
/// > the next step.
extension SettingsView {

    var removalSection: some View {
        Section {
            removalControls
            if let report = model.removal {
                removalSummary(report)
                ForEach(report.steps) { step in
                    removalRow(step)
                }
                lastStep
            }
        } header: {
            sectionHeader(SettingsSection.removal.title, anchor: .removal)
        } footer: {
            footnote(
                String(
                    localized: """
                        Moving AgentBar to the Trash does not remove its hooks. Claude Code \
                        would go on posting to a port nobody is holding, and Codex would go on \
                        running a helper on every tool call. Do this first.
                        """,
                    comment: "Explains why an uninstaller exists"))
        }
    }

    @ViewBuilder private var removalControls: some View {
        HStack(spacing: DesignTokens.Space.small) {
            Button(role: .destructive) {
                isConfirmingRemoval = true
            } label: {
                Text("Remove AgentBar's Hooks and Files…", comment: "Button")
            }
            .disabled(model.isRemoving)
            if model.isRemoving {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: DesignTokens.Space.small)
        }
        .confirmationDialog(
            Text("Remove AgentBar from Claude Code and Codex?", comment: "Confirmation title"),
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await model.removeEverything() }
            } label: {
                Text("Remove", comment: "Confirmation button")
            }
            Button(role: .cancel) {
            } label: {
                Text("Cancel", comment: "Confirmation button")
            }
        } message: {
            Text(
                """
                This deletes the hooks AgentBar added to ~/.claude/settings.json and \
                ~/.codex/hooks.json, its Codex helper, its login item, and the files it keeps \
                in Application Support. Each configuration file is backed up beside itself \
                first. Nothing you or another tool put there is touched.
                """,
                comment: "Confirmation message listing exactly what is removed")
        }
    }

    private func removalSummary(_ report: RemovalReport) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.small) {
            StateShapeView(
                kind: report.hasFailures ? .failed : .working,
                size: StateShapeView.rowSize(for: report.hasFailures ? .failed : .working),
                color: (report.hasFailures ? ColorToken.stateFailed : .connected).color)
            Text(report.summary)
                .font(DesignTokens.Text.body)
                .foregroundStyle(
                    report.hasFailures ? ColorToken.stateFailed.color : ColorToken.ink900.color
                )
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// One step, with its own outcome and — when it failed — the instruction
    /// that replaces it.
    private func removalRow(_ step: RemovalStep) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.tiny) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.small) {
                StateShapeView(
                    kind: Self.shape(for: step.outcome),
                    size: StateShapeView.rowSize(for: Self.shape(for: step.outcome)),
                    color: Self.ink(for: step.outcome).color)
                Text(step.title)
                    .font(DesignTokens.Text.rowTitle)
                Text(step.location)
                    .font(DesignTokens.Text.caption.monospaced())
                    .foregroundStyle(accessibility.secondaryInk.color)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: DesignTokens.Space.small)
                Text(Self.verdict(for: step.outcome))
                    .font(DesignTokens.Text.caption)
                    .foregroundStyle(Self.ink(for: step.outcome).color)
            }
            switch step.outcome {
            case .failed(let reason, let remedy):
                Text(reason)
                    .font(DesignTokens.Text.caption)
                    .foregroundStyle(ColorToken.stateFailed.color)
                    .fixedSize(horizontal: false, vertical: true)
                instruction(remedy)
            case .leftAlone(let reason, let remedy):
                Text(reason)
                    .font(DesignTokens.Text.caption)
                    .foregroundStyle(accessibility.secondaryInk.color)
                    .fixedSize(horizontal: false, vertical: true)
                instruction(remedy)
            case .removed(let detail):
                if let detail { instruction(detail) }
            case .nothingToRemove:
                EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// A line the user is meant to act on, so it can be selected and copied.
    private func instruction(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.Text.caption)
            .foregroundStyle(accessibility.secondaryInk.color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /// The one thing AgentBar will not do for the user.
    ///
    /// A running application that unlinks its own bundle is a trick, and the
    /// honest end of an uninstall is the user dragging the app away themselves.
    /// So the flow stops one step short and says so, with both halves of that
    /// step to hand.
    private var lastStep: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.small) {
            Text(
                "AgentBar itself is still where you put it. Quit it, then move it to the Trash.",
                comment: "The last step of an uninstall, which the user takes"
            )
            .font(DesignTokens.Text.body)
            .fixedSize(horizontal: false, vertical: true)
            // Both tools read their hook configuration when a session starts, so
            // a session that was already running keeps the definitions that were
            // there. Nothing hangs — every handler AgentBar installed carries an
            // explicit timeout — but a user watching for the change deserves to
            // know why it is not immediate.
            Text(
                """
                Sessions that are already running keep the old configuration until they end.
                """,
                comment: "Why the change is not immediate in a running session"
            )
            .font(DesignTokens.Text.caption)
            .foregroundStyle(accessibility.secondaryInk.color)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DesignTokens.Space.small) {
                Button(action: model.revealApplication) {
                    Text("Reveal AgentBar in Finder", comment: "Button")
                }
                Button(action: model.quitApplication) {
                    Text("Quit AgentBar", comment: "Button")
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Vocabulary

    /// Every outcome gets a silhouette as well as a colour, which is the rule
    /// everywhere else in this app and matters most on the one surface a user
    /// reads when something has gone wrong.
    static func shape(for outcome: RemovalOutcome) -> SessionStateKind {
        switch outcome {
        case .removed: .working
        case .nothingToRemove: .idle
        case .leftAlone: .unknown
        case .failed: .failed
        }
    }

    static func ink(for outcome: RemovalOutcome) -> ColorToken {
        switch outcome {
        case .removed: .connected
        case .nothingToRemove: .ink400
        case .leftAlone: .stateUnknown
        case .failed: .stateFailed
        }
    }

    static func verdict(for outcome: RemovalOutcome) -> String {
        switch outcome {
        case .removed:
            String(localized: "Removed", comment: "Removal outcome")
        case .nothingToRemove:
            String(localized: "Nothing there", comment: "Removal outcome")
        case .leftAlone:
            String(localized: "Left alone", comment: "Removal outcome")
        case .failed:
            String(localized: "Still there", comment: "Removal outcome")
        }
    }
}
