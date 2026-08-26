import AgentBarCore
import SwiftUI

/// The provider × event matrix: one row per verb, one column per provider.
///
/// A `Grid` rather than a fixed two-column layout, for the reason the Limits
/// section is a repeating component: the columns come from the providers the
/// assembly registered. Today that is Claude Code alone, and a Codex column
/// before step 09 lands would offer settings for notifications that cannot
/// arrive — the same mistake as a hardcoded `1 of 2` in the footer.
///
/// > **The provider columns are elastic, the verb column is not.** Fixed widths
/// > for all three made the matrix the widest thing in the window, and a matrix
/// > wider than the window it sits in does not shrink — it is clipped, and what
/// > gets clipped is the verb labels on the left. The verb column holds a fixed
/// > amount of text and keeps a fixed width; the provider columns share what is
/// > left, down to a floor below which the sound picker stops being readable.
struct NotificationMatrixView: View {
    let model: SettingsModel

    @Environment(\.accessibilityPreferences) private var accessibility

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Self.columnSpacing, verticalSpacing: 14) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                ForEach(model.providers, id: \.self) { provider in
                    header(for: provider)
                }
            }
            ForEach(NotificationVerb.allCases) { verb in
                GridRow(alignment: .top) {
                    label(for: verb)
                    ForEach(model.providers, id: \.self) { provider in
                        cell(provider: provider, verb: verb)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!model.preferences.isEnabled)
    }

    /// The verb column. Wide enough for `An agent is blocked and needs you` on
    /// two lines, and no wider — every point here is one the provider columns
    /// do not get.
    static let labelWidth: CGFloat = 168
    /// The floor for a provider column: a checkbox, and a sound picker still
    /// wide enough to read a name in.
    static let cellMinimumWidth: CGFloat = 172
    static let columnSpacing: CGFloat = 16

    /// The narrowest the matrix can be drawn without clipping, at `providers`
    /// columns. `SettingsWindowLayout` sizes the window against this, because a
    /// matrix wider than its window is not shrunk — it is cut off, and what
    /// gets cut off is the verb labels on the left.
    static func minimumWidth(providers: Int) -> CGFloat {
        labelWidth + CGFloat(providers) * (cellMinimumWidth + columnSpacing)
    }

    private func header(for provider: Provider) -> some View {
        HStack(spacing: DesignTokens.Space.small) {
            ProviderBadge(provider: provider, size: 18)
            Text(provider.displayName)
                .font(DesignTokens.Text.rowTitle)
        }
        .accessibilityAddTraits(.isHeader)
    }

    /// The verb, its state shape and one line saying what it actually is.
    private func label(for verb: NotificationVerb) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Row.detailGap) {
            HStack(spacing: DesignTokens.Row.shapeGap) {
                // The shape says which state, and the colour comes from the
                // event's own attachment ramp rather than from the state's
                // accent — so the matrix, the banner and the settings preview
                // agree about what colour a `Finished` is. They would not
                // otherwise: `finished` announces the *idle* state, which is the
                // one state with no accent at all.
                verbShape(for: verb)
                Text(verb.title)
                    .font(DesignTokens.Text.rowTitle)
            }
            Text(verb.explanation)
                .font(DesignTokens.Text.caption)
                .foregroundStyle(accessibility.secondaryInk.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: Self.labelWidth, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Approval keeps the waiting agent but encloses it in a shield, matching
    /// its notification art and remaining distinct from Question and Waiting
    /// when colour is unavailable. Other verbs keep their state silhouette.
    @ViewBuilder
    private func verbShape(for verb: NotificationVerb) -> some View {
        let accent = AttachmentRamp.ramp(for: verb).accent
        if verb == .approval {
            ZStack {
                ApprovalShield()
                    .stroke(
                        accent,
                        style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: 16, height: 18)
                AgentGlyphView(state: .working, size: 10, tint: accent)
            }
            .frame(width: 20, height: 20)
        } else {
            StateShapeView(
                kind: verb.shape,
                size: StateShapeView.rowSize(for: verb.shape),
                color: accent)
        }
    }

    @ViewBuilder
    private func cell(provider: Provider, verb: NotificationVerb) -> some View {
        if let cell = model.preferences.cell(for: provider, verb: verb) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.tiny) {
                Toggle(
                    isOn: Binding(
                        get: { cell.isEnabled },
                        set: { model.setCellEnabled($0, provider: provider, verb: verb) })
                ) {
                    Text(
                        "Notify",
                        comment: "Matrix cell toggle: whether this event notifies at all"
                    )
                    .font(DesignTokens.Text.caption)
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel(
                    String(
                        localized: "Notify about \(verb.title) for \(provider.displayName)",
                        comment: "Matrix cell toggle, spoken"))

                HStack(spacing: DesignTokens.Space.tiny) {
                    soundPicker(cell)
                    playButton(cell)
                }
                .disabled(!cell.isEnabled)

                if let problem = cell.problem {
                    Text(problem)
                        .font(DesignTokens.Text.caption)
                        .foregroundStyle(ColorToken.stateFailed.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minWidth: Self.cellMinimumWidth, maxWidth: .infinity, alignment: .leading)
        }
    }

    private func soundPicker(_ cell: NotificationCell) -> some View {
        Picker(
            selection: Binding(
                get: { cell.soundID },
                set: { model.setSound($0, provider: cell.provider, verb: cell.verb) })
        ) {
            ForEach(SoundGroup.allCases) { group in
                let choices = model.soundChoices.filter { $0.group == group }
                if !choices.isEmpty {
                    Section(group.title) {
                        ForEach(choices) { choice in
                            Text(choice.name).tag(choice.id)
                        }
                    }
                }
            }
        } label: {
            Text("Sound", comment: "Matrix cell sound picker")
        }
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .accessibilityLabel(
            String(
                localized: "Sound for \(cell.verb.title) from \(cell.provider.displayName)",
                comment: "Matrix cell sound picker, spoken"))
    }

    /// Auditions the selected sound.
    ///
    /// The only check available without sending a real notification, and the
    /// reason it is here at all: `UNNotificationSound(named:)` falls back to the
    /// default silently, so hearing it is the difference between "my sound" and
    /// "a sound".
    @ViewBuilder
    private func playButton(_ cell: NotificationCell) -> some View {
        let choice = model.soundChoices.first { $0.id == cell.soundID }
        Button {
            if let choice { model.preview(choice) }
        } label: {
            Image(systemName: "play.circle")
                .font(.system(size: 14))
                .foregroundStyle(accessibility.secondaryInk.color)
        }
        .buttonStyle(.plain)
        .disabled(choice?.isPlayable != true)
        .help(String(localized: "Play this sound", comment: "Matrix cell preview button"))
        .accessibilityLabel(
            String(localized: "Play this sound", comment: "Matrix cell preview button"))
    }
}
