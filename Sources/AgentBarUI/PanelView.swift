import AgentBarCore
import AppKit
import SwiftUI

/// The panel: project groups, then Limits, then the footer.
///
/// The onboarding card **replaces** the project groups; it does not sit above
/// them. The Limits section and the footer are always present, because the
/// Claude Code caveat row is permanent and the footer is how a degraded install
/// is reported at all.
public struct PanelView: View {
    @Bindable private var model: PanelModel
    private let onQuit: () -> Void
    private let onSettings: () -> Void

    @Environment(\.accessibilityPreferences) private var accessibility
    @FocusState private var focused: SessionID?
    /// Whether the rows are taller than the list's cap — the **decision**, not
    /// the measurement it came from.
    ///
    /// > This used to hold the measured height, and holding the height is what
    /// > pegged a CPU core. `onGeometryChange` writes into SwiftUI state from
    /// > inside layout; the hosting view carries `.intrinsicContentSize` and so
    /// > propagates its size into the window's layout; and the window's layout
    /// > re-measures the list. A height that settles at a sub-pixel wobble —
    /// > 341.0 one pass, 340.99998 the next — closes that circle and the display
    /// > cycle never reaches a fixed point. Verified from the system's own
    /// > report: 98 % of one core for 92 seconds, every sample inside
    /// > `NSHostingView.layout()`.
    /// >
    /// > A `Bool` cannot wobble. `onGeometryChange` publishes only when the
    /// > value it computes changes, so the feedback edge exists for the one
    /// > frame the list actually crosses the cap and never again.
    @State private var listOverflows = false

    public init(
        model: PanelModel,
        onSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.model = model
        self.onSettings = onSettings
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 0) {
            PanelHeaderView(summary: model.headerSummary, state: model.snapshot.mostUrgentState)
            content
            Rectangle()
                .fill(ColorToken.divider.color)
                .frame(height: accessibility.hairlineWidth)
                .padding(.top, DesignTokens.Group.dividerMargin)
            LimitsSectionView(windows: model.usage)
                .padding(.top, DesignTokens.Limits.labelMargin)
            FooterView(
                status: model.footer,
                caffeine: model.caffeine,
                showsCard: model.showsIntegrationCard,
                onStatus: { model.showsIntegrationCard.toggle() },
                onCaffeine: model.toggleCaffeine,
                onSettings: onSettings,
                onQuit: onQuit)
        }
        .frame(width: DesignTokens.panelWidth)
        // Above the material and below the content, so the header and the first
        // rows read *through* it. Applied before the material because a
        // `.background` stacks behind whatever it is applied to.
        .background(alignment: .top) {
            if model.isAnyoneWaiting { WaitingWash() }
        }
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                .strokeBorder(ColorToken.hairline.color, lineWidth: accessibility.hairlineWidth)
        }
        // Keyed on which sessions exist, not on the whole snapshot: the
        // snapshot changes every second because the durations do, and animating
        // a ticking number is noise. Rows appearing and leaving is the only
        // change worth a transition.
        .animation(accessibility.rowAnimation, value: model.snapshot.sessions.map(\.id))
        // The wash arrives and leaves with the state rather than snapping. Keyed
        // on the decision, never on a measurement — this panel has already paid
        // once for publishing a wobbling `CGFloat` out of layout.
        .animation(accessibility.rowAnimation, value: model.isAnyoneWaiting)
    }

    /// Reduce Transparency replaces the material with a flat `surface` fill at
    /// the same radius. Never lose the panel or its contrast.
    @ViewBuilder private var background: some View {
        if accessibility.reduceTransparency {
            ColorToken.surface.color
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.content {
        case .sessions:
            sessionList
        case .onboarding:
            IntegrationCardView(
                integrations: model.integrations,
                busy: model.busy,
                resultLine: model.resultLine(for:),
                action: { action, provider in
                    Task { await model.perform(action, for: provider) }
                })
        case .allQuiet:
            EmptyStateView()
        }
    }

    /// Rows scroll; the footer never does. The fade at the bottom edge has to be
    /// a real **mask** rather than an overlay: an overlay would need a colour to
    /// fade *to*, and on glass there is none.
    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.snapshot.projects.enumerated()), id: \.element.id) { entry in
                    let (index, group) = entry
                    if index > 0 {
                        Rectangle()
                            .fill(ColorToken.divider.color)
                            .frame(height: accessibility.hairlineWidth)
                            .padding(.horizontal, DesignTokens.Group.dividerInset)
                            .padding(.vertical, DesignTokens.Group.dividerMargin)
                    }
                    ProjectGroupView(
                        group: group, labels: model.labels, focus: $focused, action: open,
                        move: moveFocus)
                }
            }
            .onGeometryChange(for: Bool.self) {
                $0.size.height > DesignTokens.listMaximumHeight
            } action: {
                listOverflows = $0
            }
        }
        .frame(maxHeight: DesignTokens.listMaximumHeight)
        .fixedSize(horizontal: false, vertical: true)
        // Only when there is something below the cut. A gradient's stops are
        // fractions of the frame it masks, not of the 340 pt cap, so a fade
        // applied to a list that fits would eat a fixed *percentage* of it —
        // saying "there is more below" when there is not.
        .mask {
            // A plain rectangle is a no-op mask. Passing `nil` would not be:
            // `Optional` renders as `EmptyView`, and masking with nothing hides
            // everything.
            if listOverflows { listFade } else { Rectangle() }
        }
    }

    /// A real mask, never an overlay: an overlay would need a colour to fade
    /// *to*, and on glass there is none — fading to an opaque neutral would band
    /// against the material.
    ///
    /// Reached only when the list is at its cap, so the frame really is
    /// `listMaximumHeight` and the stop below really is 36 pt from the bottom.
    private var listFade: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(
                    color: .black,
                    location: 1 - DesignTokens.listFadeHeight / DesignTokens.listMaximumHeight),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    /// Arrow keys move between rows. They only arrive at all when the panel was
    /// opened as key window — see `PanelController`.
    private func moveFocus(_ direction: MoveCommandDirection) {
        let ordered = model.snapshot.sessions.map(\.id)
        guard !ordered.isEmpty else { return }
        guard let current = focused, let index = ordered.firstIndex(of: current) else {
            focused = direction == .up ? ordered.last : ordered.first
            return
        }
        switch direction {
        case .up: focused = ordered[max(0, index - 1)]
        case .down: focused = ordered[min(ordered.count - 1, index + 1)]
        default: break
        }
    }

    /// `NSWorkspace.open` on a directory opens whatever application is
    /// registered for it — Finder, unless the user has changed that. The copy
    /// says exactly this rather than promising an editor AgentBar cannot
    /// identify without a setting that does not exist yet.
    private func open(_ session: Session) {
        NSWorkspace.shared.open(session.project.root)
    }
}

/// The resting state, and it must feel calm rather than broken.
public struct EmptyStateView: View {
    @Environment(\.accessibilityPreferences) private var accessibility
    /// Static at mid-coverage under Reduce Motion, which is why this starts
    /// `false` and is only raised on appearance if motion is allowed.
    @State private var breathing = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .strokeBorder(
                        ColorToken.ringQuiet.color, lineWidth: DesignTokens.Empty.ringStroke
                    )
                    .frame(
                        width: DesignTokens.Empty.outerRing, height: DesignTokens.Empty.outerRing)
                Circle()
                    .strokeBorder(
                        ColorToken.ringQuiet.color, lineWidth: DesignTokens.Empty.ringStroke
                    )
                    .frame(
                        width: DesignTokens.Empty.innerRing, height: DesignTokens.Empty.innerRing)
            }
            // A slow breathe, and only that. The resting state has to feel calm
            // rather than broken, and the one thing that separates "nothing is
            // running" from "the app has stopped" is a sign that something is
            // still watching.
            .opacity(breathing ? 1 : 0.55)
            .animation(
                accessibility.runsCyclicalMotion
                    ? DesignTokens.Motion.animation(
                        DesignTokens.Motion.breathe, DesignTokens.Motion.cycle
                    ).repeatForever(autoreverses: true)
                    : nil,
                value: breathing
            )
            .onAppear { breathing = accessibility.runsCyclicalMotion }
            .accessibilityHidden(true)
            .padding(.bottom, DesignTokens.Empty.ringsToText)

            Text(String(localized: "All quiet", comment: "Empty state title"))
                .font(DesignTokens.Text.rowTitle)
                .foregroundStyle(ColorToken.ink900.color)
            Text(String(localized: "No sessions are running", comment: "Empty state subtitle"))
                .font(DesignTokens.Text.caption)
                .foregroundStyle(accessibility.secondaryInk.color)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DesignTokens.Empty.topPadding)
        .padding(.horizontal, DesignTokens.Empty.sidePadding)
        .padding(.bottom, DesignTokens.Empty.bottomPadding)
        .accessibilityElement(children: .combine)
    }
}
