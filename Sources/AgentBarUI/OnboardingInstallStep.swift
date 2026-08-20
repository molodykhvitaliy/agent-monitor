import AgentBarCore
import SwiftUI

/// The two steps that write into a file the user owns.
///
/// They are the reason this flow is not a slideshow: everything they show comes
/// from the same install report the panel's `Get Started` card reads, and every
/// button they offer is the same `IntegrationAction` that card dispatches. A
/// second install path would be a second set of bugs.

/// An install step. Same plumbing as the integration card, more room to explain
/// what it is about to write and where.
struct InstallStepView: View {
    @Bindable var model: OnboardingModel
    let step: OnboardingStep

    @Environment(\.accessibilityPreferences) private var accessibility

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignTokens.Row.badgeGap) {
                if let provider = step.provider { ProviderBadge(provider: provider) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.title)
                        .font(DesignTokens.Text.panelTitle)
                        .foregroundStyle(ColorToken.ink900.color)
                    if let subtitle = step.subtitle {
                        Text(subtitle)
                            .font(DesignTokens.Text.caption)
                            .foregroundStyle(accessibility.secondaryInk.color)
                    }
                }
                Spacer(minLength: 0)
            }

            Text(step.explanation)
                .font(DesignTokens.Text.body)
                .foregroundStyle(accessibility.secondaryInk.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DesignTokens.Space.medium)

            if step == .codex, let provider = step.provider {
                CodexStages(done: model.condition(for: provider).codexStagesDone)
                    .padding(.top, DesignTokens.Space.medium)
            }

            // What is read, and where it lives. In the step, never behind a
            // link: this is a write into a file the user owns.
            VStack(alignment: .leading, spacing: DesignTokens.Space.tiny) {
                ForEach(step.facts, id: \.self) { fact in
                    HStack(alignment: .top, spacing: DesignTokens.Space.tiny) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(ColorToken.connected.color)
                        Text(fact)
                            .font(DesignTokens.Text.caption)
                            .foregroundStyle(accessibility.secondaryInk.color)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.top, DesignTokens.Space.medium)

            if let provider = step.provider { statusRow(provider) }

            if step == .codex {
                Text(
                    """
                    Codex only runs hooks you've explicitly trusted — until then it stays silent.
                    """,
                    comment: "Footnote below the onboarding card"
                )
                .font(DesignTokens.Text.caption)
                .lineSpacing(3.5)
                .foregroundStyle(ColorToken.ink400.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DesignTokens.Space.small)
            }
        }
    }

    /// The live state and its one action, both derived from the report — never
    /// from anything this flow remembers.
    private func statusRow(_ provider: Provider) -> some View {
        let condition = model.condition(for: provider)
        return VStack(alignment: .leading, spacing: DesignTokens.Space.tiny) {
            HStack(spacing: DesignTokens.Space.small) {
                if let indicator = condition.indicator {
                    StateShapeView(
                        kind: indicator.kind,
                        size: StateShapeView.footerSize(for: indicator.kind),
                        color: indicator.color.color)
                }
                Text(condition.statusLine)
                    .font(DesignTokens.Text.rowTitle)
                    .foregroundStyle(
                        condition.indicator?.color.color ?? accessibility.secondaryInk.color)
                Spacer(minLength: DesignTokens.Space.small)
                if let action = condition.action {
                    OnboardingButton(
                        title: action.label, isProminent: action.isProminent, fill: action.fill
                    ) {
                        Task { await model.perform(action, for: provider) }
                    }
                    .disabled(model.busy.contains(provider))
                    .opacity(model.busy.contains(provider) ? 0.5 : 1)
                }
            }
            if let result = model.resultLine(for: provider) {
                Text(result.text)
                    .font(DesignTokens.Text.caption)
                    // `Nothing to change` is not a failure and must not wear a
                    // failure's colour.
                    .foregroundStyle(
                        result.isFault ? ColorToken.stateFailed.color : ColorToken.ink400.color
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            if let detail = model.status(for: provider)?.detail {
                Text(detail)
                    .font(DesignTokens.Text.caption)
                    .foregroundStyle(accessibility.secondaryInk.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DesignTokens.Space.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ColorToken.fillQuiet.color,
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        )
        .padding(.top, DesignTokens.Space.medium)
    }
}

/// Codex's two stages, drawn rather than explained.
///
/// The two-step requirement is what surprises people — a hook that is installed
/// and silent looks broken — so the step shows the progression before the user
/// meets it.
struct CodexStages: View {
    let done: Int

    @Environment(\.accessibilityPreferences) private var accessibility

    var body: some View {
        HStack(spacing: DesignTokens.Space.small) {
            stage(1, String(localized: "Install", comment: "Codex onboarding stage"))
            Rectangle()
                .fill(ColorToken.hairline.color)
                .frame(width: 14, height: accessibility.hairlineWidth)
            stage(2, String(localized: "Trust", comment: "Codex onboarding stage"))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func stage(_ number: Int, _ title: String) -> some View {
        let complete = done >= number
        return HStack(spacing: DesignTokens.Space.tiny) {
            ZStack {
                Circle()
                    .fill(
                        complete
                            ? ColorToken.connected.color : ColorToken.fillQuiet.color
                    )
                    .frame(width: 16, height: 16)
                if complete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(ColorToken.onAccent.color)
                } else {
                    Text(verbatim: "\(number)")
                        .font(DesignTokens.Text.caption.monospacedDigit())
                        .foregroundStyle(accessibility.secondaryInk.color)
                }
            }
            Text(title)
                .font(DesignTokens.Text.caption)
                .foregroundStyle(
                    complete ? ColorToken.ink900.color : accessibility.secondaryInk.color)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, DesignTokens.Space.small)
        .background(
            ColorToken.fillQuiet.color.opacity(complete ? 0 : 1),
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.compactButton))
    }
}
