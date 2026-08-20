import AgentBarCore
import SwiftUI

/// The three-node figure as a SwiftUI view, for the surfaces that are not the
/// status item.
///
/// The panel header, the onboarding and the settings preview all draw the same
/// `GlyphFigure` the menu bar does — and, unlike the menu bar, they *may* carry
/// colour, because none of them is a template image. That is the whole
/// difference between this and `StatusItemGlyph`: same geometry, one extra
/// degree of freedom.
///
/// A single `Canvas` rather than a stack of shapes. The figure is eight fills
/// and three strokes; expressing it as eleven views would put eleven nodes in
/// the panel's view graph for something that never changes, and the panel's
/// layout cost is already a thing this project has paid for once.
public struct AgentGlyphView: View {
    private let state: SessionStateKind
    private let size: CGFloat
    private let tint: Color
    private let isAnimated: Bool

    @Environment(\.accessibilityPreferences) private var accessibility

    /// `tint` of `nil` takes the state's own accent, falling back to `ink600`
    /// for a state that has none — idle deliberately has no accent. `animated`
    /// asks the figure to run its cycle, and is ignored for a state that has
    /// none and under Reduce Motion.
    public init(
        state: SessionStateKind,
        size: CGFloat,
        tint: Color? = nil,
        animated: Bool = false
    ) {
        self.state = state
        self.size = size
        self.tint = tint ?? (state.accent?.color ?? ColorToken.ink600.color)
        isAnimated = animated
    }

    public var body: some View {
        Group {
            if runsCycle, let cycle = GlyphFigure.cycle(for: state) {
                TimelineView(.periodic(from: .now, by: StatusItemGlyph.frameInterval)) { context in
                    figure(phase: phase(at: context.date, over: cycle))
                }
            } else {
                figure(phase: nil)
            }
        }
        .frame(width: size, height: size)
        // The silhouette says what a label beside it already says. A screen
        // reader gets the label; repeating it here would say everything twice.
        .accessibilityHidden(true)
    }

    private var runsCycle: Bool {
        isAnimated && accessibility.runsCyclicalMotion && GlyphFigure.animates(state)
    }

    /// Where in the cycle a wall-clock instant falls.
    ///
    /// A wall clock is the right instrument here and the wrong one everywhere
    /// else in this project: nothing is being *measured*: a jump would move the
    /// animation's phase and nothing more.
    private func phase(at date: Date, over cycle: Duration) -> Double {
        let seconds = date.timeIntervalSinceReferenceDate
        return GlyphFigure.wrapped(seconds / cycle.seconds)
    }

    private func figure(phase: Double?) -> some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            GlyphCanvas.draw(
                GlyphFigure.plan(for: state, phase: phase),
                size: size,
                tint: tint,
                into: &context)
        }
        .frame(width: size, height: size)
    }
}

/// Draws a `GlyphPlan` into a SwiftUI `GraphicsContext`.
///
/// The mirror of `GlyphRenderer`, and the reason both exist: the figure is one
/// set of numbers with two renderers, rather than two sets of numbers that will
/// eventually disagree. The only real difference is the coordinate system —
/// `GlyphFigure` measures y **up**, AppKit's convention, and a SwiftUI canvas
/// measures it down.
enum GlyphCanvas {
    static func draw(
        _ plan: GlyphPlan, size: CGFloat, tint: Color, into context: inout GraphicsContext
    ) {
        let scale = size / GlyphFigure.canvas
        drawLinks(plan, scale: scale, size: size, tint: tint, into: &context)
        for node in plan.nodes {
            draw(node, scale: scale, size: size, tint: tint, into: &context)
        }
        if let pulse = plan.pulse {
            draw(pulse, scale: scale, size: size, tint: tint, into: &context)
        }
    }

    private static func drawLinks(
        _ plan: GlyphPlan, scale: CGFloat, size: CGFloat, tint: Color,
        into context: inout GraphicsContext
    ) {
        guard plan.linkCoverage > 0 else { return }
        var links = Path()
        for link in plan.links {
            links.move(to: flip(link.from, scale: scale, size: size))
            links.addLine(to: flip(link.to, scale: scale, size: size))
        }
        context.stroke(
            links,
            with: .color(tint.opacity(plan.linkCoverage)),
            style: StrokeStyle(
                lineWidth: GlyphFigure.linkWidth * scale,
                lineCap: .round,
                dash: plan.linkIsDashed ? GlyphFigure.linkDash.map { $0 * scale } : []))
    }

    private static func draw(
        _ node: GlyphPlan.Node, scale: CGFloat, size: CGFloat, tint: Color,
        into context: inout GraphicsContext
    ) {
        guard node.coverage > 0, node.radius > 0 else { return }
        let ink = GraphicsContext.Shading.color(tint.opacity(node.coverage))
        let box = square(node.centre, node.radius, scale: scale, size: size)
        let stroke = GlyphFigure.nodeStroke * scale
        switch node.shape {
        case .disc:
            context.fill(Path(ellipseIn: box), with: ink)
        case .ring:
            context.stroke(
                Path(ellipseIn: box.insetBy(dx: stroke / 2, dy: stroke / 2)),
                with: ink, lineWidth: stroke)
        case .dashedRing:
            context.stroke(
                Path(ellipseIn: box.insetBy(dx: stroke / 2, dy: stroke / 2)),
                with: ink,
                style: StrokeStyle(
                    lineWidth: stroke, dash: GlyphFigure.nodeDash.map { $0 * scale }))
        case .roundedSquare:
            context.fill(
                Path(
                    roundedRect: box, cornerRadius: GlyphFigure.failedCorner * scale,
                    style: .continuous),
                with: ink)
        }
    }

    private static func draw(
        _ pulse: GlyphPlan.Pulse, scale: CGFloat, size: CGFloat, tint: Color,
        into context: inout GraphicsContext
    ) {
        guard pulse.coverage > 0, pulse.radius > pulse.stroke else { return }
        let width = pulse.stroke * scale
        let box = square(pulse.centre, pulse.radius, scale: scale, size: size)
        context.stroke(
            Path(ellipseIn: box.insetBy(dx: width / 2, dy: width / 2)),
            with: .color(tint.opacity(pulse.coverage)),
            lineWidth: width)
    }

    /// `GlyphFigure` measures y up; a SwiftUI canvas measures it down.
    private static func flip(_ value: CGPoint, scale: CGFloat, size: CGFloat) -> CGPoint {
        CGPoint(x: value.x * scale, y: size - value.y * scale)
    }

    private static func square(
        _ centre: CGPoint, _ radius: CGFloat, scale: CGFloat, size: CGFloat
    ) -> CGRect {
        CGRect(
            x: (centre.x - radius) * scale,
            y: size - (centre.y + radius) * scale,
            width: radius * 2 * scale,
            height: radius * 2 * scale)
    }
}
