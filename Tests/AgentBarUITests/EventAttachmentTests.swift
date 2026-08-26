import AgentBarCore
import AppKit
import Testing

@testable import AgentBarUI

/// The attachment square is one of exactly four things about a notification
/// banner that AgentBar decides. The other three are text; this is the only
/// graphic, so it has to carry something the text cannot.
@MainActor
@Suite("Event attachment art")
struct EventAttachmentTests {

    @Test("Every verb renders")
    func everyVerbRenders() throws {
        for verb in NotificationVerb.allCases {
            let png = try #require(
                EventAttachmentImage.png(for: verb), "\(verb) produced no image")
            #expect(!png.isEmpty)
        }
    }

    /// Five gradients are very easy to tell apart and prove nothing: the banner
    /// is greyscale to a colour-blind user and to a screenshot in a bug report.
    /// So the squares are compared **desaturated**, which is the check that
    /// actually holds the "silhouette first, colour second" rule.
    @Test("All five stay distinguishable with the colour taken out")
    func distinguishableInGreyscale() throws {
        var seen: [(NotificationVerb, [Double])] = []
        for verb in NotificationVerb.allCases {
            let grid = try luminance(of: verb)
            for (other, previous) in seen {
                let difference =
                    zip(grid, previous)
                    .map { abs($0 - $1) }
                    .reduce(0, +) / Double(grid.count)
                #expect(
                    difference > 0.02,
                    "\(verb) and \(other) are the same square once desaturated")
            }
            seen.append((verb, grid))
        }
    }

    /// The two events that mean "the agent is not working right now" draw the
    /// same nodes; the ring is the whole of what tells them apart, and losing it
    /// would leave two squares differing only in hue.
    @Test("Finished has a ring and Approval has a shield")
    func onlyFinishedIsEnclosed() {
        #expect(NotificationVerb.finished.attachmentEnclosure == .circle)
        #expect(NotificationVerb.approval.attachmentEnclosure == .shield)
        #expect(
            NotificationVerb.allCases.filter { $0.attachmentEnclosure == .none }
                == [.question, .waiting, .failed])
        #expect(NotificationVerb.waiting.attachmentFigure == .working)
        #expect(NotificationVerb.approval.attachmentFigure == .working)
        #expect(NotificationVerb.finished.attachmentFigure == .working)
        #expect(NotificationVerb.question.attachmentFigure == .waiting)
        #expect(NotificationVerb.failed.attachmentFigure == .failed)
    }

    /// The square is generated large and clipped by the system to about 38 pt.
    @Test("The canvas is square and generous")
    func canvasSize() throws {
        let png = try #require(EventAttachmentImage.png(for: .question))
        let rep = try #require(NSBitmapImageRep(data: png))
        // Rendered at 2×, so the pixel dimensions are twice the canvas.
        #expect(rep.pixelsWide == Int(EventAttachmentImage.pixelSize) * 2)
        #expect(rep.pixelsHigh == rep.pixelsWide)
    }

    /// Every stop is a derivation of a semantic token, so an event square and
    /// the settings indicator are visibly the same colour.
    @Test("Every ramp derives from an existing token, and its stops differ")
    func rampsDeriveFromTokens() {
        var bases: Set<ColorToken> = []
        for verb in NotificationVerb.allCases {
            let ramp = AttachmentRamp.ramp(for: verb)
            #expect(ColorToken.values[ramp.base] != nil, "\(verb) names no real token")
            #expect(ramp.start != ramp.end, "\(verb) has no gradient at all")
            // ±12 % of lightness in one direction and the other: the first stop
            // is the lighter one, and a pair the wrong way round would light the
            // square from below.
            #expect(
                brightness(ramp.start) > brightness(ramp.end),
                "\(verb)'s gradient runs dark to light")
            #expect(bases.insert(ramp.base).inserted, "\(verb) shares a base with another event")
        }
    }

    /// An 8 × 8 grid of luminance, which is enough to compare silhouettes and
    /// small enough not to be a screenshot test in disguise.
    private func luminance(of verb: NotificationVerb) throws -> [Double] {
        let png = try #require(EventAttachmentImage.png(for: verb, size: 64))
        let rep = try #require(NSBitmapImageRep(data: png))
        let step = rep.pixelsWide / 8
        var grid: [Double] = []
        for row in 0..<8 {
            for column in 0..<8 {
                let colour = rep.colorAt(x: column * step + step / 2, y: row * step + step / 2)
                grid.append(Double(brightness(colour ?? .black)))
            }
        }
        return grid
    }

    private func brightness(_ colour: NSColor) -> CGFloat {
        (colour.usingColorSpace(.sRGB) ?? colour).brightnessComponent
    }
}
