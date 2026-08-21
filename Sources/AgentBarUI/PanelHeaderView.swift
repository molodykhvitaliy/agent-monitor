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
///
/// > **It stuttered once, and the cause was the shape of the loop rather than
/// > its speed.** The sweep used to travel from the track's left edge to its
/// > right on `Motion.cycle`, repeating without autoreverse. Both halves of that
/// > are wrong for a loop that wraps. The travel began *inside* the track, so
/// > every cycle ended with a 40 %-wide bar appearing out of nothing at the left
/// > edge; and an ease-in-out spends its slowest moments at both ends of the
/// > travel, which puts a near-stop on each side of that seam. What the eye saw
/// > was: pop, crawl, race, crawl, pop. It now starts fully off the left, ends
/// > fully off the right, and moves at one speed the whole way — see
/// > `Motion.traverse`.
struct WorkingHairline: View {
    @Environment(\.accessibilityPreferences) private var accessibility
    @Environment(\.surfaceIsOnScreen) private var isOnScreen

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let sweep = width * DesignTokens.Progress.sweepWidth
            let moving = accessibility.runsCyclicalMotion && isOnScreen
            track
                .overlay(alignment: .leading) {
                    // **Two branches, not one offset with a conditional
                    // animation**, and the reason is a defect this view has
                    // already had twice. A `repeatForever` animation is driven
                    // by a value *change*; when the moving state is entered
                    // again — a user turning Reduce Motion off with the panel
                    // open, or the panel coming back on screen — a single shared
                    // `@State` is already at its end value, so nothing fires and
                    // the row is left with an empty track for as long as it
                    // lives. Entering this branch gives `SweepingBar` a fresh
                    // identity and therefore a fresh `@State` and a fresh
                    // `onAppear`, so the loop cannot fail to re-arm.
                    if moving, width > 0 {
                        SweepingBar(width: width, sweep: sweep) { gradient }
                            // **The travel is geometry, so a change in geometry
                            // has to re-arm the loop.** `onAppear` fires once;
                            // a `width` that arrives later — a lazily
                            // materialised row whose first `GeometryReader`
                            // pass reports zero, or a scroller appearing and
                            // taking 15 pt — would otherwise retarget the
                            // offset outside any animated transaction and park
                            // the bar off an edge for the life of the row. A
                            // new identity is a new `@State` and a new
                            // `onAppear`, which is the same mechanism the
                            // branch above relies on.
                            //
                            // Safe as an identity because this width is
                            // discrete: the panel is a fixed
                            // `DesignTokens.panelWidth` and the row takes a
                            // small number of values inside it. A width that
                            // could wobble sub-pixel must never be an `id` —
                            // that is the shape of the 98 % core this app has
                            // already paid for once.
                            .id(width)
                    } else {
                        // Reduce Motion, a panel that is not on screen, or a
                        // width that has not arrived yet: a fill at the left,
                        // never a hidden element. A working row must still look
                        // different from an idle one when nothing is allowed to
                        // move.
                        gradient.frame(width: width * DesignTokens.Progress.staticFill)
                    }
                }
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: DesignTokens.Progress.radius, style: .continuous))
        }
        .frame(height: DesignTokens.Progress.height)
        .padding(.top, DesignTokens.Progress.topMargin)
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

/// The sweep while it is allowed to move: off the left edge, across, off the
/// right, for ever and at one speed.
///
/// Its own type rather than a branch inside `WorkingHairline`, because its
/// `@State` **is** the mechanism. A `repeatForever` animation needs a value to
/// change in order to start, so the loop has to begin from a value that is
/// genuinely fresh every time the view appears. Entering the enclosing `if`
/// gives this a new identity and therefore a new `false`; a shared flag on the
/// parent would already be `true` and the loop would silently never run.
private struct SweepingBar<Content: View>: View {
    let width: CGFloat
    let sweep: CGFloat
    @ViewBuilder let content: () -> Content

    /// Whether the travel has been asked for. The animation interpolates from
    /// the resting `-sweep` to `width`, which is the full traverse: the bar is
    /// wholly outside the track at both ends, so the wrap has nothing visible to
    /// pop.
    @State private var hasLeft = false

    var body: some View {
        content()
            .frame(width: sweep)
            .offset(x: hasLeft ? width : -sweep)
            .animation(
                DesignTokens.Motion.repeating(
                    DesignTokens.Motion.hairlineSweep, DesignTokens.Motion.traverse),
                value: hasLeft
            )
            // After the view is on screen, not in an initialiser: a first cycle
            // spent off screen is a cycle the user never sees.
            .onAppear { hasLeft = true }
    }
}
