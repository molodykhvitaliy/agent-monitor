import SwiftUI

/// Install status on the left, two icon buttons on the right.
///
/// The status line is the **whole** diagnostics surface, deliberately: the
/// brief's restraint requirement rules out a diagnostics panel, and pressing the
/// status opens the integration card, whose per-provider list explains why in
/// prose the adapter already wrote.
public struct FooterView: View {
    private let status: FooterStatus
    private let showsCard: Bool
    private let onStatus: () -> Void
    private let onSettings: () -> Void
    private let onQuit: () -> Void

    @Environment(\.accessibilityPreferences) private var accessibility

    public init(
        status: FooterStatus,
        showsCard: Bool,
        onStatus: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.status = status
        self.showsCard = showsCard
        self.onStatus = onStatus
        self.onSettings = onSettings
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(ColorToken.divider.color)
                .frame(height: accessibility.hairlineWidth)
            HStack(spacing: DesignTokens.Footer.buttonSpacing) {
                statusButton
                Spacer(minLength: DesignTokens.Space.small)
                iconButton(
                    systemName: "gearshape",
                    label: String(localized: "Settings", comment: "Footer button"),
                    action: onSettings)
                iconButton(
                    systemName: "power",
                    label: String(localized: "Quit AgentBar", comment: "Footer button"),
                    action: onQuit)
            }
            .padding(.vertical, DesignTokens.Footer.verticalPadding)
            .padding(.horizontal, DesignTokens.Footer.horizontalPadding)
        }
    }

    /// Pressing it opens the integration card in place — the answer to "why is
    /// nothing appearing?" one click from the thing that says something is
    /// wrong.
    private var statusButton: some View {
        Button(action: onStatus) {
            HStack(spacing: DesignTokens.Footer.indicatorGap) {
                // The indicator carries the state *shape*, not only the colour.
                StateShapeView(
                    kind: status.shape,
                    size: StateShapeView.footerSize(for: status.shape),
                    color: status.color.color
                )
                .frame(
                    width: DesignTokens.Footer.indicatorSize,
                    height: DesignTokens.Footer.indicatorSize)
                Text(status.text)
                    .font(DesignTokens.Text.caption)
                    .foregroundStyle(accessibility.secondaryInk.color)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(status.text)
        .accessibilityHint(
            showsCard
                ? String(localized: "Close the integration status", comment: "Footer button hint")
                : String(localized: "Show the integration status", comment: "Footer button hint"))
    }

    /// 22 × 22, radius 6. Neither has a visible label, so both need a tooltip
    /// and an accessibility label.
    private func iconButton(
        systemName: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(accessibility.secondaryInk.color)
                .frame(
                    width: DesignTokens.Footer.buttonSize,
                    height: DesignTokens.Footer.buttonSize
                )
                .contentShape(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.iconButton))
        }
        .buttonStyle(QuietIconButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

struct QuietIconButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                isHovered || configuration.isPressed ? ColorToken.fillQuiet.color : .clear,
                in: RoundedRectangle(cornerRadius: DesignTokens.Radius.iconButton)
            )
            .onHover { isHovered = $0 }
    }
}
