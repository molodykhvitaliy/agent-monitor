import SwiftUI

/// Install status on the left, three icon buttons on the right.
///
/// The status line is the **whole** diagnostics surface, deliberately: the
/// brief's restraint requirement rules out a diagnostics panel, and pressing the
/// status opens the integration card, whose per-provider list explains why in
/// prose the adapter already wrote.
///
/// > **Deviation from `docs/dev/design-spec.md` § Footer, step 08.** That
/// > section closed with "Nothing more", meaning no further *entry points*.
/// > Caffeine is not an entry point: it is a control whose state has to be
/// > readable at a glance, and the panel is the only surface a user looks at
/// > without going looking. It sits leftmost of the three so `Quit` stays last,
/// > and it carries a silhouette per state rather than a colour, like every
/// > other indicator here. Its settings — the third mode, and the honest
/// > limitation — live in the settings window's `Caffeine` section.
public struct FooterView: View {
    private let status: FooterStatus
    private let caffeine: CaffeineIndicator
    private let showsCard: Bool
    private let onStatus: () -> Void
    private let onCaffeine: () -> Void
    private let onSettings: () -> Void
    private let onQuit: () -> Void

    @Environment(\.accessibilityPreferences) private var accessibility

    public init(
        status: FooterStatus,
        caffeine: CaffeineIndicator,
        showsCard: Bool,
        onStatus: @escaping () -> Void,
        onCaffeine: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.status = status
        self.caffeine = caffeine
        self.showsCard = showsCard
        self.onStatus = onStatus
        self.onCaffeine = onCaffeine
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
                caffeineButton
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

    /// The Caffeine indicator, and the switch that turns it off and on.
    ///
    /// Two sentences rather than one: the tooltip says what is happening now,
    /// the accessibility hint says what pressing it will do. A control that only
    /// describes its state leaves a user guessing whether it is a button.
    private var caffeineButton: some View {
        Button(action: onCaffeine) {
            Image(systemName: caffeine.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(
                    caffeine.tint?.color ?? accessibility.secondaryInk.color
                )
                .frame(
                    width: DesignTokens.Footer.buttonSize,
                    height: DesignTokens.Footer.buttonSize
                )
                .contentShape(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.iconButton))
        }
        .buttonStyle(QuietIconButtonStyle())
        .help(caffeine.summary)
        .accessibilityLabel(
            String(
                localized: "Caffeine: \(caffeine.summary)",
                comment: "Footer button, spoken state")
        )
        .accessibilityHint(caffeine.toggleLabel)
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
