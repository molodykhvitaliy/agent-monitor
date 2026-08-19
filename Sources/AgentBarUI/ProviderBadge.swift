import AgentBarCore
import SwiftUI

/// The provider tile: a rounded square in the provider's colour with its glyph
/// in `onAccent`.
///
/// Both glyphs are drawn rather than shipped, and sized as a fraction of the
/// badge, so one implementation serves the 22 pt dense badge, the 26 pt row
/// badge and the 38 pt notification badge alike. The radius scales with the
/// tile at about 27 %, because a single fixed radius looks wrong at both ends
/// of that range.
///
/// > These are original generic marks. Neither is Anthropic's or OpenAI's
/// > actual logo — those are registered brand assets AgentBar has no licence to.
public struct ProviderBadge: View {
    private let provider: Provider
    private let size: CGFloat

    public init(provider: Provider, size: CGFloat = DesignTokens.Row.badgeSize) {
        self.provider = provider
        self.size = size
    }

    /// 6 at 22 pt, 7 at 26 pt, 8 at 28 pt, 10 at 38 pt.
    static func radius(for size: CGFloat) -> CGFloat { (size * 0.27).rounded() }

    public var body: some View {
        RoundedRectangle(cornerRadius: Self.radius(for: size), style: .continuous)
            .fill(provider.badgeColor.color)
            .frame(width: size, height: size)
            .overlay { glyph }
            // The row's own label already names the provider; the tile repeats
            // it for the eye and would repeat it for VoiceOver.
            .accessibilityHidden(true)
    }

    @ViewBuilder private var glyph: some View {
        switch provider {
        case .claudeCode:
            SparkleGlyph()
                .fill(ColorToken.onAccent.color)
                .frame(width: size * 0.54, height: size * 0.54)
        case .codex:
            Text(verbatim: "</>")
                .font(.system(size: size * 0.46, weight: .bold, design: .monospaced))
                .tracking(-1)
                .foregroundStyle(ColorToken.onAccent.color)
        }
    }
}

/// Claude Code's mark: a four-point sparkle inscribed in 54 % of the badge.
///
/// > **Deviation.** The design system describes this as "two rounded bars
/// > crossed at 45°", and two rectangular bars at 45° draw an **✕** — which on a
/// > filled terracotta tile reads as *error* or *close*, the opposite of what a
/// > provider badge means. Rendered and checked at 26 pt before changing it.
/// > The concave four-point star is what "sparkle" denotes, and it keeps the
/// > stated envelope: the same 54 % box, the same four points.
struct SparkleGlyph: Shape {
    /// How far the waist between two arms is pulled toward the centre. Lower is
    /// sharper; 0.28 keeps the arms readable at 22 pt without turning the mark
    /// into a thin cross.
    private static let waist: CGFloat = 0.28

    nonisolated func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let tips = [
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.midY),
        ]
        var path = Path()
        path.move(to: tips[0])
        for index in tips.indices {
            let next = tips[(index + 1) % tips.count]
            let corner = CGPoint(
                x: (tips[index].x + next.x) / 2, y: (tips[index].y + next.y) / 2)
            path.addQuadCurve(
                to: next,
                control: CGPoint(
                    x: centre.x + (corner.x - centre.x) * Self.waist,
                    y: centre.y + (corner.y - centre.y) * Self.waist))
        }
        path.closeSubpath()
        return path
    }
}
