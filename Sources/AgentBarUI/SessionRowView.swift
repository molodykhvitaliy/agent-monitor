import AgentBarCore
import AppKit
import SwiftUI

/// One session. One row design, at every list length — the panel scrolls
/// instead of densifying.
///
/// The whole row is the click target and it has exactly one action: open the
/// project. Copy and tooltip both say *the default application* rather than
/// *your editor*, because `ProjectRef.root` is a directory and AgentBar does not
/// know which editor the user is in. When the settings screen can name one, the
/// copy becomes true rather than being made vaguer.
public struct SessionRowView: View {
    private let session: Session
    private let projectLabel: String
    private let focus: FocusState<SessionID?>.Binding
    private let action: (Session) -> Void
    private let move: (MoveCommandDirection) -> Void

    @Environment(\.accessibilityPreferences) private var accessibility
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    /// Every decision the row makes, worked out before anything is drawn — see
    /// `SessionRowContent`.
    private let content: SessionRowContent

    public init(
        session: Session,
        projectLabel: String,
        focus: FocusState<SessionID?>.Binding,
        action: @escaping (Session) -> Void,
        move: @escaping (MoveCommandDirection) -> Void
    ) {
        self.session = session
        self.projectLabel = projectLabel
        self.focus = focus
        self.action = action
        self.move = move
        content = SessionRowContent(session: session, projectLabel: projectLabel)
    }

    public var body: some View {
        Button {
            action(session)
        } label: {
            HStack(alignment: .top, spacing: DesignTokens.Row.badgeGap) {
                ProviderBadge(provider: session.provider)
                VStack(alignment: .leading, spacing: DesignTokens.Row.detailGap) {
                    topLine
                    detailLine
                    // The one place in the app that says "a process is alive",
                    // and only on the one row where that is true.
                    if session.state.kind == .working { WorkingHairline() }
                }
            }
            .padding(.vertical, DesignTokens.Row.verticalPadding)
            .padding(.horizontal, DesignTokens.Row.horizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.row))
        }
        .buttonStyle(SessionRowButtonStyle(kind: session.state.kind, isHovered: isHovered))
        // Explicit rather than inherited: on macOS a button is only in the tab
        // loop when Full Keyboard Access is on, and the panel's arrow-key
        // navigation must not depend on a system setting.
        .focusable()
        .focused(focus, equals: session.id)
        // Both here rather than on the list: only a focusable view receives key
        // events, and the rows are what is focusable. A `ScrollView` is not, so
        // an `onMoveCommand` on the container would never fire.
        .onMoveCommand(perform: move)
        .onKeyPress(.return) {
            action(session)
            return .handled
        }
        .onHover { isHovered = $0 }
        .help(content.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel)
        .accessibilityHint(content.openHint)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Top line

    private var topLine: some View {
        HStack(spacing: 0) {
            StateShapeView(
                kind: session.state.kind,
                size: StateShapeView.rowSize(for: session.state.kind),
                color: (session.state.kind.accent ?? .ink400).color)
            Spacer().frame(width: DesignTokens.Row.shapeGap)
            Text(content.stateLabel)
                .font(DesignTokens.Text.rowTitle)
                .foregroundStyle(ColorToken.ink900.color)
            if let pill = content.subagentPill {
                Spacer().frame(width: 2)
                subagentPill(pill)
            }
            Spacer(minLength: DesignTokens.Space.small)
            Text(content.duration)
                .font(DesignTokens.Text.caption.monospacedDigit())
                .foregroundStyle(ColorToken.ink400.color)
        }
    }

    /// `+2`, and only ever when there is something to count.
    ///
    /// The store keeps subagents as a `Set<AgentID>`, so their types are
    /// discarded before a view could see them: `+2 (Explore, Plan)` is a domain
    /// change, not a layout one.
    private func subagentPill(_ text: String) -> some View {
        Text(verbatim: text)
            .font(DesignTokens.Text.caption.monospacedDigit())
            .foregroundStyle(ColorToken.ink400.color)
            .padding(.vertical, 1)
            .padding(.horizontal, 6)
            .background(ColorToken.fillQuiet.color, in: Capsule())
    }

    // MARK: - Detail line

    /// `nil` renders nothing at all — the row is one line tall. A `Detail` with
    /// no text still occupies its line's height, which is what stops a working
    /// row jumping every time a tool call ends.
    @ViewBuilder private var detailLine: some View {
        if let detail = content.detail {
            Text(detail.text ?? " ")
                .font(detail.isMonospaced ? DesignTokens.Text.mono : DesignTokens.Text.caption)
                .foregroundStyle(ColorToken.ink400.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The row's whole appearance: tint, hover and focus, in that order.
///
/// Hover and focus composite *over* the state tint; neither replaces it. A
/// focused Waiting row must still read as waiting, which is exactly the row a
/// keyboard user is most likely to be reaching for.
struct SessionRowButtonStyle: ButtonStyle {
    let kind: SessionStateKind
    let isHovered: Bool

    @Environment(\.accessibilityPreferences) private var accessibility
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(tint, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row))
            .background(
                // Translucent by construction. Not `fillQuiet`, which is opaque
                // in light and would erase a failed row's 7 % wash and punch
                // through the glass with it.
                isHovered || configuration.isPressed ? ColorToken.hoverOverlay.color : .clear,
                in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.row)
                    // The macOS system accent, not one of ours: `stateWorking`
                    // is the same blue as the Working dot, so using it would put
                    // a Working-coloured ring around a focused Waiting row.
                    .strokeBorder(
                        isFocused ? Color(nsColor: .controlAccentColor) : .clear,
                        lineWidth: DesignTokens.Row.focusRingWidth)
            }
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.row))
    }

    private var tint: Color {
        guard let accent = kind.accent,
            let opacity = kind.tintOpacity(
                dark: colorScheme == .dark, increasedContrast: accessibility.increaseContrast)
        else { return .clear }
        return accent.color.opacity(opacity)
    }
}
