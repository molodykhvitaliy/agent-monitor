import AgentBarCore
import AppKit

/// The menu-bar glyph: the three-node figure from `GlyphFigure`, drawn rather
/// than shipped.
///
/// Drawing settles two things by construction. **A template image has one
/// channel of alpha**, so the canvas's coloured badge and coloured pulse ring
/// cannot survive — everything here is shape and coverage, and the ring is an
/// even-odd annulus rather than a stroke in an accent. And a path cannot be
/// withdrawn between macOS releases the way an SF Symbol name can, which is what
/// the old `"AB"` text fallback existed to survive.
///
/// > **Why the figure changed.** The previous glyph was a filled 12 pt disc with
/// > the badge punched out. It was clean and it was invisible: at 18 pt among a
/// > dozen system items a plain disc has no identity, reads as a generic
/// > indicator, and tells a first-time user nothing. Three nodes joined by
/// > hairlines are not confusable with Wi-Fi, battery, Bluetooth or Control
/// > Center, and they read as "several things, connected" — which is what the
/// > app monitors.
///
/// Colour lives in the notification attachment, the panel row and the footer
/// indicator. Never here.
public enum StatusItemGlyph {
    /// The menu-bar canvas, from the figure it draws.
    static let canvas = GlyphFigure.canvas

    /// The resting image for a state, or for "nothing running" when there is
    /// none.
    ///
    /// Always the first frame of that state's array, so the static image and the
    /// animation cannot disagree about what the state looks like — including
    /// under Reduce Motion, which shows exactly this.
    public static func image(for state: SessionStateKind?) -> NSImage {
        frames(for: state ?? .idle)[0]
    }

    /// Every frame of a state's cycle, or the single resting frame for a state
    /// that does not animate.
    ///
    /// Cached, exactly as the static images were: the arrays are built once, are
    /// small — eighteen 18 × 18 pt vector images at the largest — and the status
    /// item redraws whenever the aggregate state moves.
    public static func frames(for state: SessionStateKind) -> [NSImage] {
        if let cached = cache[state] { return cached }
        let built = build(state)
        cache[state] = built
        return built
    }

    /// How long the array covers, or `nil` when it is a single resting frame.
    public static func cycle(for state: SessionStateKind?) -> Duration? {
        guard let state else { return nil }
        return GlyphFigure.cycle(for: state)
    }

    /// The interval between frames of an animating state.
    static let frameInterval: TimeInterval = 1 / DesignTokens.Motion.glyphFrameRate

    private static var cache: [SessionStateKind: [NSImage]] = [:]

    private static func build(_ state: SessionStateKind) -> [NSImage] {
        guard let cycle = GlyphFigure.cycle(for: state) else {
            return [image(GlyphFigure.plan(for: state))]
        }
        let count = GlyphFigure.frameCount(for: cycle)
        // Phase-shifted so the first frame is the resting one — the frame every
        // static surface draws and the frame Reduce Motion leaves on screen.
        let start = state == .waiting ? GlyphFigure.waitingRestingPhase : 0
        return (0..<count).map { index in
            image(GlyphFigure.plan(for: state, phase: start + Double(index) / Double(count)))
        }
    }

    private static func image(_ plan: GlyphPlan) -> NSImage {
        let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
            GlyphRenderer.draw(plan, size: canvas)
            return true
        }
        // AppKit tints a template image for light, dark and a tinted menu bar,
        // so everything drawn is shape and coverage, never colour.
        image.isTemplate = true
        return image
    }
}

/// Draws a `GlyphPlan` with AppKit, on a canvas whose y runs up.
///
/// Everything is filled in black at the plan's own coverage. A template image
/// keeps only the alpha, and the surfaces that may use colour say so by drawing
/// this into a tinted context rather than by asking for a colour here.
enum GlyphRenderer {
    static func draw(_ plan: GlyphPlan, size: CGFloat) {
        let scale = size / GlyphFigure.canvas
        let transform = NSAffineTransform()
        transform.scale(by: scale)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        transform.concat()

        drawLinks(plan)
        for node in plan.nodes { drawNode(node) }
        if let pulse = plan.pulse { drawPulse(pulse) }
    }

    private static func drawLinks(_ plan: GlyphPlan) {
        guard plan.linkCoverage > 0 else { return }
        let path = NSBezierPath()
        for link in plan.links {
            path.move(to: link.from)
            path.line(to: link.to)
        }
        path.lineWidth = GlyphFigure.linkWidth
        path.lineCapStyle = .round
        if plan.linkIsDashed {
            let dash = GlyphFigure.linkDash
            path.setLineDash(dash, count: dash.count, phase: 0)
        }
        NSColor.black.withAlphaComponent(plan.linkCoverage).setStroke()
        path.stroke()
    }

    private static func drawNode(_ node: GlyphPlan.Node) {
        guard node.coverage > 0, node.radius > 0 else { return }
        let ink = NSColor.black.withAlphaComponent(node.coverage)
        switch node.shape {
        case .disc:
            ink.setFill()
            disc(at: node.centre, radius: node.radius).fill()
        case .ring:
            ink.setFill()
            // Filled as an annulus rather than stroked: a stroke centred on the
            // radius would put half its width outside the figure's stated
            // bounding box, and the box is what the optical weight was checked
            // against.
            ring(at: node.centre, radius: node.radius, stroke: GlyphFigure.nodeStroke).fill()
        case .dashedRing:
            ink.setStroke()
            let stroke = GlyphFigure.nodeStroke
            let path = NSBezierPath()
            path.appendArc(
                withCenter: node.centre, radius: node.radius - stroke / 2,
                startAngle: 0, endAngle: 360)
            path.lineWidth = stroke
            let dash = GlyphFigure.nodeDash
            path.setLineDash(dash, count: dash.count, phase: 0)
            path.stroke()
        case .roundedSquare:
            ink.setFill()
            NSBezierPath(
                roundedRect: CGRect(
                    x: node.centre.x - node.radius, y: node.centre.y - node.radius,
                    width: node.radius * 2, height: node.radius * 2),
                xRadius: GlyphFigure.failedCorner, yRadius: GlyphFigure.failedCorner
            ).fill()
        }
    }

    /// The pulse, as a **punched** annulus rather than a stroke.
    ///
    /// Outer circle, inner circle, even-odd — the same construction the old
    /// badge gap used, and the only one available: a template image cannot carry
    /// the coloured ring the prototype draws, so the ring has to be a shape.
    private static func drawPulse(_ pulse: GlyphPlan.Pulse) {
        guard pulse.coverage > 0, pulse.radius > pulse.stroke else { return }
        NSColor.black.withAlphaComponent(pulse.coverage).setFill()
        ring(at: pulse.centre, radius: pulse.radius, stroke: pulse.stroke).fill()
    }

    private static func disc(at centre: CGPoint, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(
            ovalIn: CGRect(
                x: centre.x - radius, y: centre.y - radius,
                width: radius * 2, height: radius * 2))
    }

    /// An annulus as a fillable path: outer circle, inner circle, even-odd.
    private static func ring(
        at centre: CGPoint, radius: CGFloat, stroke: CGFloat
    ) -> NSBezierPath {
        let path = disc(at: centre, radius: radius)
        path.append(disc(at: centre, radius: max(0, radius - stroke)))
        path.windingRule = .evenOdd
        return path
    }
}
