import AgentBarCore
import SwiftUI

/// The provider × event matrix: one row per verb, one column per provider.
///
/// A `Grid` rather than a fixed two-column layout, for the reason the Limits
/// section is a repeating component: the columns come from the providers the
/// assembly registered. Today that is Claude Code alone, and a Codex column
/// before step 09 lands would offer settings for notifications that cannot
/// arrive — the same mistake as a hardcoded `1 of 2` in the footer.
struct NotificationMatrixView: View {
    let model: SettingsModel

    @Environment(\.accessibilityPreferences) private var accessibility

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 14) {
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
        .disabled(!model.preferences.isEnabled)
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
                StateShapeView(
                    kind: verb.shape,
                    size: StateShapeView.rowSize(for: verb.shape),
                    color: (verb.shape.accent ?? .ink400).color)
                Text(verb.title)
                    .font(DesignTokens.Text.rowTitle)
            }
            Text(verb.explanation)
                .font(DesignTokens.Text.caption)
                .foregroundStyle(accessibility.secondaryInk.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 190, alignment: .leading)
        .accessibilityElement(children: .combine)
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
            .frame(width: 210, alignment: .leading)
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
        .frame(width: 170)
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
