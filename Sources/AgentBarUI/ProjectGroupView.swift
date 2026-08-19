import AgentBarCore
import SwiftUI

/// A project's header and its sessions.
///
/// Groups are ordered by project name and sessions inside them oldest first —
/// the store's own ordering, and deliberate: a list sorted by urgency would
/// reshuffle under the cursor. Urgency is the status item's job.
public struct ProjectGroupView: View {
    private let group: ProjectGroup
    private let labels: ProjectLabels
    private let focus: FocusState<SessionID?>.Binding
    private let action: (Session) -> Void
    private let move: (MoveCommandDirection) -> Void

    public init(
        group: ProjectGroup,
        labels: ProjectLabels,
        focus: FocusState<SessionID?>.Binding,
        action: @escaping (Session) -> Void,
        move: @escaping (MoveCommandDirection) -> Void
    ) {
        self.group = group
        self.labels = labels
        self.focus = focus
        self.action = action
        self.move = move
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, DesignTokens.Group.headerBottomMargin)
            ForEach(group.sessions) { session in
                SessionRowView(
                    session: session,
                    projectLabel: labels.label(for: group.project),
                    focus: focus,
                    action: action,
                    move: move)
            }
        }
        .padding(.top, DesignTokens.Group.topPadding)
        .padding(.horizontal, DesignTokens.Group.sidePadding)
        .padding(.bottom, DesignTokens.Group.bottomPadding)
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Group.glyphGap) {
            FolderGlyph()
            Text(group.project.name)
                .font(DesignTokens.Text.rowTitle)
                .foregroundStyle(ColorToken.ink900.color)
            // The disambiguating suffix is muted, and is part of the name
            // everywhere the name is used — not decoration on the header.
            if let suffix = labels.suffix(for: group.project) {
                Text(DesignTokens.separator + suffix)
                    .font(DesignTokens.Text.caption)
                    .foregroundStyle(ColorToken.ink400.color)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: DesignTokens.Space.small)
            Text(sessionCount)
                .font(DesignTokens.Text.caption.monospacedDigit())
                .foregroundStyle(ColorToken.ink400.color)
        }
        // Unconditionally, and whether or not the name is ambiguous.
        .help(group.project.root.path(percentEncoded: false))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(labels.label(for: group.project))
        .accessibilityHint(group.project.root.path(percentEncoded: false))
    }

    private var sessionCount: String {
        let count = group.sessions.count
        return count == 1
            ? String(localized: "1 session", comment: "Project group session count")
            : String(localized: "\(count) sessions", comment: "Project group session count")
    }
}
