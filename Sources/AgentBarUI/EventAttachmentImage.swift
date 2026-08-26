import AgentBarCore
import AppKit
import SwiftUI

/// The square a notification carries, rendered to a bitmap.
///
/// `UNNotificationAttachment` takes a **file**, so the art has to leave SwiftUI
/// and land on disk before a banner can show it — which is also why this returns
/// data rather than writing it: where the file goes is the app assembly's
/// business, not the design system's.
///
/// > **Why the square says the event and not the provider.** macOS draws the
/// > banner and we do not. There are exactly four decisions in it that are ours
/// > — this image, the three text slots, the actions, and the grouping — and the
/// > leading icon slot is always the app's own bundle icon, which cannot be
/// > replaced. So an attachment naming the provider was repeating something the
/// > `subtitle` can say in words for free, three centimetres from an icon that
/// > already says which app it is. The square carries the one thing no other
/// > slot can carry at a glance: *what happened*.
///
/// Silhouette first, colour second. All five remain distinguishable desaturated
/// — pinned by a test, because a gradient makes it very easy to build five
/// squares that differ only in hue.
public enum EventAttachmentImage {
    /// The generated canvas. The system clips and scales it to roughly 38 pt, so
    /// this is generous on purpose: an attachment is rendered once and reused at
    /// whatever size the banner style asks for.
    public static let pixelSize: CGFloat = 256

    /// The figure's share of the canvas.
    static let figureRatio: CGFloat = 0.56

    /// A rendered square, or `nil` if the renderer produced nothing — in which
    /// case the notification names the provider in its title instead.
    ///
    /// Rendered at 2× and **in the light appearance deliberately**: an
    /// attachment is not re-rendered when the system theme changes, so a
    /// dark-appearance square would be wrong half the time.
    @MainActor
    public static func png(for verb: NotificationVerb, size: CGFloat = pixelSize) -> Data? {
        let renderer = ImageRenderer(
            content:
                EventAttachmentArt(verb: verb, size: size)
                .environment(\.colorScheme, .light)
                .frame(width: size, height: size)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// The art itself: a 155° gradient, a sheen, and the three-node figure in white.
///
/// A SwiftUI view rather than Core Graphics so it can be looked at in a render
/// proof and reused in the settings preview's banner mock, where the point is
/// that the preview shows the *real* art rather than an imitation of it.
struct EventAttachmentArt: View {
    let verb: NotificationVerb
    let size: CGFloat

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(nsColor: ramp.start), Color(nsColor: ramp.end)],
                // 155° measured from the top, which puts the light stop in the
                // upper-left and the dark one in the lower-right — the direction
                // every other lit surface on the screen is lit from.
                startPoint: UnitPoint(x: 0.19, y: 0),
                endPoint: UnitPoint(x: 0.81, y: 1))
            // The sheen. A single soft highlight, off-centre, so the square reads
            // as a physical tile rather than as a flat swatch — the one gradient
            // in the app that is decoration, and it is inside an image the system
            // scales to 38 pt.
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: .white.opacity(0.45), location: 0),
                    .init(color: .white.opacity(0), location: 1),
                ]),
                center: UnitPoint(x: 0.22, y: 0.08),
                startRadius: 0,
                endRadius: size * 0.6)
            figure
        }
        .frame(width: size, height: size)
        // The system clips the attachment to its own rounded rectangle. Squaring
        // it here would put a second, differently-sized corner inside that one.
        .clipped()
    }

    /// The same `GlyphFigure` the menu bar draws, in `onAccent` white — plus, for
    /// `finished`, a closed ring around the whole thing; for `approval`, a
    /// shield around it.
    ///
    /// The ring is the one element the glyph vocabulary does not already have,
    /// and it is what makes `finished` and `waiting` different silhouettes rather
    /// than the same figure in two colours: both draw all three nodes filled,
    /// because a turn that ended and a turn that is blocked are both "the agent
    /// is not working right now".
    @ViewBuilder private var figure: some View {
        let side = size * EventAttachmentImage.figureRatio
        ZStack {
            switch verb.attachmentEnclosure {
            case .none:
                EmptyView()
            case .circle:
                Circle()
                    .strokeBorder(
                        ColorToken.onAccent.color,
                        lineWidth: side * GlyphFigure.linkWidth / GlyphFigure.canvas
                    )
                    .frame(width: side, height: side)
                    .opacity(GlyphFigure.linkCoverageRatio + 0.25)
            case .shield:
                ApprovalShield()
                    .stroke(
                        ColorToken.onAccent.color,
                        style: StrokeStyle(
                            lineWidth: side * GlyphFigure.linkWidth / GlyphFigure.canvas,
                            lineCap: .round,
                            lineJoin: .round)
                    )
                    .frame(width: side, height: side)
                    .opacity(GlyphFigure.linkCoverageRatio + 0.25)
            }
            AgentGlyphView(
                state: verb.attachmentFigure,
                size: verb.attachmentIsEnclosed ? side * 0.72 : side,
                tint: ColorToken.onAccent.color)
        }
        .frame(width: side, height: side)
    }

    private var ramp: AttachmentRamp { AttachmentRamp.ramp(for: verb) }
}

/// A deliberately simple shield that survives the system scaling the 256 px
/// attachment down to roughly 38 pt.
struct ApprovalShield: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.04))
        path.addLine(
            to: CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.minY + rect.height * 0.18))
        path.addLine(
            to: CGPoint(x: rect.maxX - rect.width * 0.16, y: rect.minY + rect.height * 0.58))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.04),
            control: CGPoint(x: rect.maxX - rect.width * 0.24, y: rect.maxY - rect.height * 0.16))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.16, y: rect.minY + rect.height * 0.58),
            control: CGPoint(x: rect.minX + rect.width * 0.24, y: rect.maxY - rect.height * 0.16))
        path.addLine(
            to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.18))
        path.closeSubpath()
        return path
    }
}

nonisolated enum EventAttachmentEnclosure: Sendable, Hashable {
    case none
    case circle
    case shield
}

nonisolated extension NotificationVerb {
    /// The glyph state the attachment square draws.
    ///
    /// Not `shape`, which is what the settings matrix and the row use. The two
    /// answer different questions: `shape` names the *session state* a verb
    /// announces, so `finished` maps to the hollow idle ring, and at 7 pt beside
    /// a label that is exactly right. At 38 pt on a gradient a hollow ring is a
    /// weak silhouette and `finished` deserves a whole figure, so the square
    /// draws the full set of nodes and encloses them instead.
    var attachmentFigure: SessionStateKind {
        switch self {
        // Apex filled with a ring leaving it — an agent asking is the same
        // gesture the menu bar makes.
        case .question: .waiting
        // All three nodes filled and nothing moving.
        case .waiting, .approval, .finished: .working
        case .failed: .failed
        }
    }

    var attachmentEnclosure: EventAttachmentEnclosure {
        switch self {
        case .finished: .circle
        case .approval: .shield
        case .question, .waiting, .failed: .none
        }
    }

    var attachmentIsEnclosed: Bool { attachmentEnclosure != .none }
}
