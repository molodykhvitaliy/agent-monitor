import AgentBarCore
import AppKit

/// The five menu-bar glyphs, drawn rather than shipped.
///
/// Drawing settles two things by construction. A template image has one channel
/// of alpha, so the canvas's coloured badge and background-coloured ring cannot
/// survive — the badge is *punched out* of the glyph instead, and the shape
/// alone is what the state-shape language relies on anyway. And a path cannot be
/// withdrawn between macOS releases the way an SF Symbol name can, which is what
/// the old `"AB"` text fallback existed to survive.
///
/// Geometry is `docs/dev/design-spec.md` § Status item: an 18 pt canvas with the
/// glyph occupying the central 67 %.
public enum StatusItemGlyph {
    /// The menu-bar canvas.
    static let canvas: CGFloat = 18
    /// The glyph's outer diameter — 67 % of the canvas.
    static let diameter: CGFloat = 12
    /// Badge centres sit on the glyph's circumference at 45° upper-right. The
    /// canvas draws them bottom-right in one strip and top-right in its zoomed
    /// specimens; top-right is what its prose states and where macOS puts
    /// badges.
    static let badgeAngle = CGFloat.pi / 4
    /// Cleared space around a badge, punched out of the glyph rather than
    /// stroked.
    static let badgeGap: CGFloat = 1
    /// 40 % of the glyph.
    static let waitingBadgeDiameter: CGFloat = 4.8
    /// 33 % of the glyph.
    static let failedBadgeSide: CGFloat = 4.0
    static let failedBadgeCorner: CGFloat = 0.8
    /// Nearly invisible on purpose: the resting state must not draw the eye.
    static let idleOpacity: CGFloat = 0.4

    /// A template image for the given state, or for "nothing running" when
    /// there is none.
    ///
    /// Cached, because the status item is redrawn whenever the aggregate state
    /// moves and five images that never vary are not worth reallocating.
    public static func image(for state: SessionStateKind?) -> NSImage {
        let key = state ?? .idle
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
            draw(key)
            return true
        }
        // AppKit tints a template image for light, dark and a tinted menu bar,
        // so everything drawn below is shape and coverage, never colour.
        image.isTemplate = true
        cache[key] = image
        return image
    }

    private static var cache: [SessionStateKind: NSImage] = [:]

    static func draw(_ state: SessionStateKind) {
        let centre = CGPoint(x: canvas / 2, y: canvas / 2)
        let radius = diameter / 2
        NSColor.black.setFill()
        NSColor.black.setStroke()

        switch state {
        case .working:
            disc(at: centre, radius: radius).fill()

        case .idle:
            NSColor.black.withAlphaComponent(idleOpacity).setFill()
            ring(at: centre, radius: radius, stroke: 1.3).fill()

        case .unknown:
            // Stroked rather than filled: a dashed outline is the one glyph
            // that must never read as a solid disc.
            let stroke: CGFloat = 1.4
            let circle = NSBezierPath()
            circle.appendArc(
                withCenter: centre, radius: radius - stroke / 2, startAngle: 0, endAngle: 360)
            circle.lineWidth = stroke
            circle.setLineDash([2, 2], count: 2, phase: 0)
            circle.stroke()

        case .waiting:
            let badgeRadius = waitingBadgeDiameter / 2
            let origin = badgeCentre(centre, radius)
            let glyph = disc(at: centre, radius: radius)
            glyph.append(disc(at: origin, radius: badgeRadius + badgeGap))
            glyph.windingRule = .evenOdd
            glyph.fill()
            disc(at: origin, radius: badgeRadius).fill()

        case .failed:
            let origin = badgeCentre(centre, radius)
            let glyph = disc(at: centre, radius: radius)
            glyph.append(
                roundedSquare(
                    at: origin,
                    side: failedBadgeSide + badgeGap * 2,
                    corner: failedBadgeCorner + badgeGap))
            glyph.windingRule = .evenOdd
            glyph.fill()
            roundedSquare(at: origin, side: failedBadgeSide, corner: failedBadgeCorner).fill()
        }
    }

    static func badgeCentre(_ centre: CGPoint, _ radius: CGFloat) -> CGPoint {
        CGPoint(
            x: centre.x + radius * cos(badgeAngle),
            y: centre.y + radius * sin(badgeAngle))
    }

    private static func disc(at centre: CGPoint, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(
            ovalIn: CGRect(
                x: centre.x - radius, y: centre.y - radius,
                width: radius * 2, height: radius * 2))
    }

    private static func roundedSquare(
        at centre: CGPoint, side: CGFloat, corner: CGFloat
    ) -> NSBezierPath {
        NSBezierPath(
            roundedRect: CGRect(
                x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side),
            xRadius: corner, yRadius: corner)
    }

    /// An annulus as a fillable path: outer circle, inner circle, even-odd.
    private static func ring(
        at centre: CGPoint, radius: CGFloat, stroke: CGFloat
    ) -> NSBezierPath {
        let path = disc(at: centre, radius: radius)
        path.append(disc(at: centre, radius: radius - stroke))
        path.windingRule = .evenOdd
        return path
    }
}
