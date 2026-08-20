import AgentBarCore
import SwiftUI

/// The panel's first line: the mark, the name, and the one thing a glance is
/// asking.
///
/// The panel used to start at the first project group, which left it with no
/// identity — a floating list of rows that could have belonged to anything — and
/// no answer to "is anything urgent?" short of reading every row. The mark
/// settles the first, the pill settles the second.
///
/// The glyph here is the SwiftUI figure rather than the template image, so it
/// *may* carry the state accent. That is the whole difference: a menu-bar
/// template image has one channel of alpha, and inside the panel there is no
/// such constraint.
struct PanelHeaderView: View {
    let summary: PanelHeaderSummary?
    /// What the mark draws. The panel's own aggregate, so the header and the
    /// menu bar are never showing different states at the same moment.
    let state: SessionStateKind?

    @Environment(\.accessibilityPreferences) private var accessibility

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.Header.glyphGap) {
                AgentGlyphView(state: state ?? .idle, size: DesignTokens.Header.glyphSize)
                Text(verbatim: "AgentBar")
                    .font(DesignTokens.Text.rowTitle)
                    .foregroundStyle(ColorToken.ink900.color)
                Spacer(minLength: DesignTokens.Space.small)
                if let summary { pill(summary) }
            }
            // Stated, not derived. A header that grew when the pill appeared
            // would push every row down at the exact moment something started
            // waiting — the worst moment for the list to move under the pointer.
            .frame(height: DesignTokens.Header.contentHeight)
            .padding(.top, DesignTokens.Header.topPadding)
            .padding(.bottom, DesignTokens.Header.bottomPadding)
            .padding(.horizontal, DesignTokens.Header.sidePadding)

            Rectangle()
                .fill(ColorToken.hairline.color)
                .frame(height: accessibility.hairlineWidth)
        }
        .accessibilityElement(children: .combine)
    }

    private func pill(_ summary: PanelHeaderSummary) -> some View {
        HStack(spacing: DesignTokens.Header.pillShapeGap) {
            StateShapeView(
                kind: summary.shape,
                size: StateShapeView.footerSize(for: summary.shape),
                color: summary.color.color)
            Text(summary.text)
                .font(DesignTokens.Text.caption.weight(.semibold))
                .foregroundStyle(summary.color.color)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.vertical, DesignTokens.Header.pillVerticalPadding)
        .padding(.horizontal, DesignTokens.Header.pillHorizontalPadding)
        .background(
            summary.color.color.opacity(fillOpacity),
            in: RoundedRectangle(
                cornerRadius: DesignTokens.Radius.compactButton, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.compactButton, style: .continuous)
                .strokeBorder(
                    summary.color.color.opacity(DesignTokens.Header.pillStroke),
                    lineWidth: accessibility.hairlineWidth)
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    /// Heavier in dark, like every other tint in the panel: the same opacity
    /// over a dark material reads as less colour, not as more.
    private var fillOpacity: Double {
        colorScheme == .dark
            ? DesignTokens.Header.pillFillDark : DesignTokens.Header.pillFillLight
    }
}

/// The warm gradient across the panel's top edge while anything is waiting.
///
/// It sits above the material and below the content, so the header text and the
/// first rows read *through* it. It is state rather than decoration — it appears
/// for `waiting`, never for `failed`, and it leaves on its own when nothing is
/// waiting any more.
///
/// Under Reduce Transparency the panel is already a flat `surface` fill, and the
/// wash stays: it is an opacity over a fill, not a material effect, so nothing
/// about it depends on the blur it happens to be sitting on today.
struct WaitingWash: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: ColorToken.stateWaiting.color.opacity(opacity), location: 0),
                .init(color: ColorToken.stateWaiting.color.opacity(0), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: DesignTokens.Wash.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var opacity: Double {
        colorScheme == .dark ? DesignTokens.Wash.darkOpacity : DesignTokens.Wash.lightOpacity
    }
}

/// The 2 pt hairline under a working row's command line.
///
/// The app's only progress indicator, and deliberately not a spinner. A spinner
/// claims a duration; a sweep claims only that something is happening, which is
/// the whole of what a hook payload tells us. There is no percentage available
/// and none is implied.
///
/// > **Under Reduce Motion it is a static fill at the left, not a hidden
/// > element and not a stopped sweep.** The row still has to look different from
/// > an idle one — the rule for every cyclical indicator in the app is that its
/// > static appearance carries the same fact its motion does.
struct WorkingHairline: View {
    @Environment(\.accessibilityPreferences) private var accessibility
    @Environment(\.surfaceIsOnScreen) private var isOnScreen
    @State private var isSweeping = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let sweep = width * DesignTokens.Progress.sweepWidth
            let moving = accessibility.runsCyclicalMotion && isOnScreen
            // **One value drives both the position and the animation**, and it
            // has to include the motion setting. Keying the animation on
            // `isSweeping` alone means a user who turns Reduce Motion *off* with
            // the panel open moves the sweep without animating it — `isSweeping`
            // is already `true`, so nothing fires — and the row is left with an
            // empty track for as long as it lives.
            let sweeping = moving && isSweeping
            track
                .overlay(alignment: .leading) {
                    gradient
                        .frame(width: sweep)
                        // At rest it sits at the left, which is exactly the
                        // static 40 % fill the design asks for under Reduce
                        // Motion. Moving, it travels from there off the right.
                        .offset(x: sweeping ? width : 0)
                        .animation(
                            moving
                                ? DesignTokens.Motion.repeating(
                                    DesignTokens.Motion.hairlineSweep,
                                    DesignTokens.Motion.cycle)
                                : nil,
                            value: sweeping)
                }
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: DesignTokens.Progress.radius, style: .continuous))
        }
        .frame(height: DesignTokens.Progress.height)
        .padding(.top, DesignTokens.Progress.topMargin)
        // Started here rather than in an initialiser: a `repeatForever`
        // animation needs a value change to drive it, and the change has to
        // happen after the view is on screen or the first cycle is spent
        // off-screen.
        //
        // > **The resting position is the left edge, not off it.** An earlier
        // > version parked the sweep at `-sweep` and only rendered it inside the
        // > animated branch, so a user who turned Reduce Motion *off* with the
        // > panel open got a permanently empty track: the branch flipped, the
        // > gradient appeared parked off-screen, and `isSweeping` was already
        // > `true` so nothing could drive it back. A working row must never look
        // > like an idle one, whatever the setting was when the row appeared.
        .onAppear { isSweeping = true }
        .accessibilityHidden(true)
    }

    private var track: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Progress.radius, style: .continuous)
            .fill(ColorToken.meterTrack.color)
    }

    /// Transparent at both ends, so the sweep has no edge to catch the eye — an
    /// edge would read as a boundary between "done" and "not done", which is a
    /// claim about progress this cannot make.
    private var gradient: some View {
        LinearGradient(
            colors: [
                ColorToken.stateWorking.color.opacity(0),
                ColorToken.stateWorking.color,
                ColorToken.stateWorking.color.opacity(0),
            ],
            startPoint: .leading,
            endPoint: .trailing)
    }
}
