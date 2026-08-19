import AgentBarCore
import SwiftUI

/// The card that answers "why is nothing appearing?".
///
/// One row per registered provider, built from that provider's install report —
/// mapped into `IntegrationStatus` by the app target, so the card can render a
/// provider whose adapter does not exist yet without being restructured.
public struct IntegrationCardView: View {
    private let integrations: [IntegrationStatus]
    private let busy: Set<Provider>
    private let resultLine: (Provider) -> (text: String, isFault: Bool)?
    private let action: (IntegrationAction, Provider) -> Void

    @Environment(\.accessibilityPreferences) private var accessibility

    public init(
        integrations: [IntegrationStatus],
        busy: Set<Provider>,
        resultLine: @escaping (Provider) -> (text: String, isFault: Bool)?,
        action: @escaping (IntegrationAction, Provider) -> Void
    ) {
        self.integrations = integrations
        self.busy = busy
        self.resultLine = resultLine
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "Get Started", comment: "Onboarding card title"))
                .font(DesignTokens.Text.rowTitle)
                .foregroundStyle(ColorToken.ink900.color)
            // "both" would be wrong the moment the number of integrations is not
            // two — and it is one today.
            Text(
                String(
                    localized: "Sessions and notifications appear once every step below is done",
                    comment: "Onboarding card subtitle")
            )
            .font(DesignTokens.Text.caption)
            .foregroundStyle(accessibility.secondaryInk.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, DesignTokens.Space.small)

            ForEach(Array(integrations.enumerated()), id: \.element.id) { index, integration in
                if index > 0 {
                    Rectangle()
                        .fill(ColorToken.divider.color)
                        .frame(height: accessibility.hairlineWidth)
                }
                row(for: integration)
            }

            Text(
                String(
                    localized: """
                        Codex only runs hooks you've explicitly trusted — until then it \
                        stays silent.
                        """,
                    comment: "Footnote below the onboarding card")
            )
            .font(DesignTokens.Text.caption)
            // 1.5 line height at 11 pt, which is what the footnote is set at.
            .lineSpacing(3.5)
            .foregroundStyle(ColorToken.ink400.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, DesignTokens.Space.medium)
        }
        .padding(.top, DesignTokens.Card.topPadding)
        .padding(.horizontal, DesignTokens.Card.sidePadding)
        .padding(.bottom, DesignTokens.Card.bottomPadding)
    }

    private func row(for integration: IntegrationStatus) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.tiny) {
            HStack(alignment: .top, spacing: DesignTokens.Row.badgeGap) {
                ProviderBadge(provider: integration.provider)
                VStack(alignment: .leading, spacing: 2) {
                    Text(integration.provider.displayName)
                        .font(DesignTokens.Text.rowTitle)
                        .foregroundStyle(ColorToken.ink900.color)
                    statusLine(for: integration)
                    // A drift's, or an error's, own finished English sentence.
                    // The card renders it and formats nothing itself.
                    if let detail = integration.detail {
                        Text(detail)
                            .font(DesignTokens.Text.caption)
                            .foregroundStyle(accessibility.secondaryInk.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let result = resultLine(integration.provider) {
                        Text(result.text)
                            .font(DesignTokens.Text.caption)
                            .foregroundStyle(
                                result.isFault
                                    ? ColorToken.stateFailed.color : ColorToken.ink400.color
                            )
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: DesignTokens.Space.small)
                if let action = integration.condition.action {
                    actionButton(action, for: integration)
                }
            }
            // Warnings are not faults and must not take a fault's colour.
            ForEach(integration.notes, id: \.self) { note in
                HStack(alignment: .top, spacing: DesignTokens.Space.tiny) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                    Text(note).fixedSize(horizontal: false, vertical: true)
                }
                .font(DesignTokens.Text.caption)
                .foregroundStyle(ColorToken.ink400.color)
            }
            if !integration.coexistence.isEmpty {
                CoexistenceLine(summary: integration.coexistence)
            }
        }
        .padding(.vertical, DesignTokens.Card.rowVerticalPadding)
    }

    @ViewBuilder private func statusLine(for integration: IntegrationStatus) -> some View {
        HStack(spacing: DesignTokens.Row.shapeGap) {
            if let indicator = integration.condition.indicator {
                StateShapeView(
                    kind: indicator.kind,
                    size: StateShapeView.footerSize(for: indicator.kind),
                    color: indicator.color.color)
            }
            Text(integration.condition.statusLine)
                .font(DesignTokens.Text.caption)
                .foregroundStyle(
                    integration.condition.indicator?.color.color
                        ?? accessibility.secondaryInk.color)
        }
    }

    private func actionButton(
        _ action: IntegrationAction, for integration: IntegrationStatus
    ) -> some View {
        Button {
            self.action(action, integration.provider)
        } label: {
            Text(action.label)
                .font(DesignTokens.Text.buttonLabel)
                .lineLimit(1)
                .foregroundStyle(
                    action.isProminent ? ColorToken.onAccent.color : ColorToken.ink900.color
                )
                .padding(.vertical, DesignTokens.Card.buttonVerticalPadding)
                .padding(.horizontal, DesignTokens.Card.buttonHorizontalPadding)
                .background(
                    action.isProminent ? action.fill.color : ColorToken.fillQuiet.color,
                    in: RoundedRectangle(cornerRadius: DesignTokens.Radius.compactButton))
        }
        .buttonStyle(.plain)
        .disabled(busy.contains(integration.provider))
        .opacity(busy.contains(integration.provider) ? 0.5 : 1)
    }
}

/// "Detect and report, change nothing", made visible.
///
/// Informational, and offered no action: AgentBar does not touch a foreign
/// entry, and the UI must not imply that it might. Its value is explaining a
/// doubled notification or a competing power assertion before the user files it
/// as a bug.
struct CoexistenceLine: View {
    let summary: CoexistenceSummary
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                expanded.toggle()
            } label: {
                Text(
                    String(
                        localized: "Other hooks are installed here: \(summary.summary)",
                        comment: "Foreign hooks sharing the same events")
                )
                .font(DesignTokens.Text.caption)
                .foregroundStyle(ColorToken.ink400.color)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(summary.entries, id: \.self) { entry in
                    Text(entry)
                        .font(DesignTokens.Text.mono)
                        .foregroundStyle(ColorToken.ink400.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}
