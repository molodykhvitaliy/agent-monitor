import AgentBarCore
import SwiftUI

/// The state-shape language: a distinct silhouette per state, so colour is
/// never the only carrier.
///
/// The same five shapes appear in the session row, the footer indicator and the
/// menu-bar glyph. Their sizes differ per surface and their meaning does not.
public struct StateShapeView: View {
    private let kind: SessionStateKind
    private let size: CGSize
    private let color: Color

    /// Sizes in the session row, from `docs/dev/design-system.md`: circle 6 pt,
    /// triangle 8 × 6, rounded square 7 pt with 2 pt corners, rings 7 pt across
    /// on a 1.4 pt stroke.
    public static func rowSize(for kind: SessionStateKind) -> CGSize {
        switch kind {
        case .working: CGSize(width: 6, height: 6)
        case .waiting: CGSize(width: 8, height: 6)
        case .failed: CGSize(width: 7, height: 7)
        case .unknown, .idle: CGSize(width: 7, height: 7)
        }
    }

    /// The footer's 6 pt box. The shapes are scaled down to fit it rather than
    /// dropped, because the footer indicator carries state too.
    public static func footerSize(for kind: SessionStateKind) -> CGSize {
        switch kind {
        case .waiting: CGSize(width: 6, height: 5)
        case .failed: CGSize(width: 5, height: 5)
        default: CGSize(width: 6, height: 6)
        }
    }

    public init(kind: SessionStateKind, size: CGSize, color: Color) {
        self.kind = kind
        self.size = size
        self.color = color
    }

    public var body: some View {
        shape
            .frame(width: size.width, height: size.height)
            // The label beside it is what a screen reader reads; the silhouette
            // says the same thing again for a sighted user and nothing twice
            // for a listening one.
            .accessibilityHidden(true)
    }

    @ViewBuilder private var shape: some View {
        switch kind {
        case .working:
            Circle().fill(color)
        case .waiting:
            UpTriangle().fill(color)
        case .failed:
            RoundedRectangle(cornerRadius: size.width * 2 / 7, style: .continuous).fill(color)
        case .unknown:
            Circle().strokeBorder(
                color,
                style: StrokeStyle(lineWidth: 1.4, dash: [2, 2]))
        case .idle:
            Circle().strokeBorder(color, lineWidth: 1.4)
        }
    }
}

/// An upward triangle on its bounding box. Waiting's silhouette, and the one
/// shape SwiftUI has no primitive for.
struct UpTriangle: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A folder suggested rather than drawn: the project group header's mark,
/// 11 × 9 at a 1.3 pt stroke, corner radii 1 / 3 / 2 / 2 clockwise from
/// top-left.
struct FolderGlyph: View {
    var body: some View {
        FolderShape()
            .stroke(ColorToken.ink400.color, lineWidth: 1.3)
            .frame(width: 11, height: 9)
            .accessibilityHidden(true)
    }
}

struct FolderShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        // Inset by half the stroke so the drawn edge stays inside the frame.
        let box = rect.insetBy(dx: 0.65, dy: 0.65)
        let tabWidth = box.width * 0.45
        var path = Path()
        path.move(to: CGPoint(x: box.minX + 1, y: box.minY + 1.6))
        path.addQuadCurve(
            to: CGPoint(x: box.minX + 1.8, y: box.minY + 0.8),
            control: CGPoint(x: box.minX + 1, y: box.minY + 0.8))
        path.addLine(to: CGPoint(x: box.minX + tabWidth, y: box.minY + 0.8))
        path.addLine(to: CGPoint(x: box.minX + tabWidth + 1.4, y: box.minY + 2.4))
        path.addLine(to: CGPoint(x: box.maxX - 2, y: box.minY + 2.4))
        path.addQuadCurve(
            to: CGPoint(x: box.maxX, y: box.minY + 4.4),
            control: CGPoint(x: box.maxX, y: box.minY + 2.4))
        path.addLine(to: CGPoint(x: box.maxX, y: box.maxY - 2))
        path.addQuadCurve(
            to: CGPoint(x: box.maxX - 2, y: box.maxY),
            control: CGPoint(x: box.maxX, y: box.maxY))
        path.addLine(to: CGPoint(x: box.minX + 2, y: box.maxY))
        path.addQuadCurve(
            to: CGPoint(x: box.minX, y: box.maxY - 2),
            control: CGPoint(x: box.minX, y: box.maxY))
        path.closeSubpath()
        return path
    }
}
