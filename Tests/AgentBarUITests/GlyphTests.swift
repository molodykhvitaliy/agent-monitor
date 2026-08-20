import AgentBarCore
import AppKit
import Testing

@testable import AgentBarUI

/// The glyph is the most important element in the product: it answers "does
/// anything need me?" before the panel is opened, at 18 pt, in greyscale,
/// beside a dozen system items.
@MainActor
@Suite("Glyph figure")
struct GlyphTests {

    /// Every renderer scales from these, so a change to one of them is a change
    /// to the menu bar, the panel header, the onboarding and the attachment art
    /// at once. Pinned so that is a decision rather than a side effect.
    @Test("The figure sits where the design says it does")
    func geometryIsNormative() {
        #expect(GlyphFigure.canvas == 18)
        #expect(GlyphFigure.apexCentre == CGPoint(x: 9, y: 13))
        #expect(GlyphFigure.baseLeftCentre == CGPoint(x: 4.5, y: 5))
        #expect(GlyphFigure.baseRightCentre == CGPoint(x: 13.5, y: 5))
        #expect(GlyphFigure.baseRadius == 1.90)
        #expect(GlyphFigure.apexRadius == 2.40)
        #expect(GlyphFigure.linkWidth == 0.80)
        // 12.8 pt across on an 18 pt canvas — 71 %, wider than the disc it
        // replaces because an outlined figure reads lighter than a solid one.
        #expect(abs(GlyphFigure.opticalWidth - 12.8) < 0.001)
    }

    /// The apex is the state node. Everything else is a fixed frame of
    /// reference, so the eye has exactly one moving part.
    @Test("Only the apex changes shape between states")
    func onlyTheApexCarriesState() {
        var apexShapes: Set<String> = []
        for kind in SessionStateKind.allCases {
            let plan = GlyphFigure.plan(for: kind)
            #expect(plan.baseLeft.centre == GlyphFigure.baseLeftCentre)
            #expect(plan.baseRight.centre == GlyphFigure.baseRightCentre)
            #expect(plan.apex.centre == GlyphFigure.apexCentre)
            apexShapes.insert("\(plan.apex.shape)")
        }
        // Disc, ring, dashed ring and rounded square. Working and Waiting share
        // the disc and are told apart by the pulse.
        #expect(apexShapes.count == 4)
    }

    /// Colour is never the only carrier, and in the menu bar there is no colour
    /// at all — a template image keeps one channel of alpha. So the states have
    /// to differ in shape, coverage or both.
    @Test("Every state's resting figure differs from every other")
    func restingFiguresAreDistinct() {
        var seen: [GlyphPlan] = []
        for kind in SessionStateKind.allCases {
            let plan = GlyphFigure.plan(for: kind)
            #expect(!seen.contains(plan), "\(kind) draws the same figure as another state")
            seen.append(plan)
        }
    }

    /// The one that would have shipped broken: at phase zero the pulse ring is
    /// still inside the filled apex, so Waiting would be a filled triangle —
    /// which is Working. Reduce Motion, a sleeping timer and a profiler run all
    /// show precisely this frame.
    @Test("Waiting's resting frame shows the ring outside the apex")
    func waitingRestsWhereItIsLegible() throws {
        let waiting = GlyphFigure.plan(for: .waiting)
        let pulse = try #require(waiting.pulse)
        #expect(pulse.coverage > 0.2, "the resting ring has faded to nothing")
        #expect(
            pulse.radius - pulse.stroke / 2 > GlyphFigure.apexFilledRadius,
            "the resting ring is still inside the apex, so Waiting reads as Working")
    }

    /// Links stop at the nodes they join. A hairline crossing the middle of a
    /// hollow node reads as a mistake at any size.
    @Test("Links stop at the edge of every node")
    func linksAreTrimmed() {
        for kind in SessionStateKind.allCases {
            let plan = GlyphFigure.plan(for: kind)
            for node in plan.nodes {
                for link in plan.links {
                    for end in [link.from, link.to] {
                        let dx = end.x - node.centre.x
                        let dy = end.y - node.centre.y
                        let distance = (dx * dx + dy * dy).squareRoot()
                        // Either this end belongs to another node entirely, or
                        // it sits on this one's edge — never inside it.
                        #expect(
                            distance > node.linkInset - 0.001,
                            "\(kind): a link runs into a node")
                    }
                }
            }
        }
    }

    /// The links are subordinate in every state rather than only in the bright
    /// ones, which is why the ratio multiplies the state's coverage instead of
    /// being an absolute.
    @Test("Links are always quieter than the nodes they join")
    func linksStaySubordinate() {
        for kind in SessionStateKind.allCases {
            let plan = GlyphFigure.plan(for: kind)
            let brightest = plan.nodes.map(\.coverage).max() ?? 0
            #expect(plan.linkCoverage < brightest, "\(kind)")
        }
    }

    @Test("Idle is the quietest state and Unknown is entirely dashed")
    func restingStatesAreQuiet() {
        let idle = GlyphFigure.plan(for: .idle)
        #expect(idle.nodes.allSatisfy { $0.coverage == GlyphFigure.idleCoverage })
        #expect(idle.nodes.allSatisfy { $0.shape == .ring })

        let unknown = GlyphFigure.plan(for: .unknown)
        #expect(unknown.linkIsDashed)
        #expect(unknown.nodes.allSatisfy { $0.shape == .dashedRing })
        #expect(unknown.nodes.allSatisfy { $0.coverage == GlyphFigure.unknownCoverage })
    }

    /// The chase only ever cycles *down* from the resting figure, so a stopped
    /// chase is the Working glyph rather than a dimmed accident.
    @Test("The Working chase never brightens past its resting figure")
    func chaseStaysBelowRest() {
        let resting = GlyphFigure.plan(for: .working)
        for step in 0..<12 {
            let plan = GlyphFigure.plan(for: .working, phase: Double(step) / 12)
            for (moving, still) in zip(plan.nodes, resting.nodes) {
                #expect(moving.coverage <= still.coverage + 0.001)
                #expect(moving.radius <= still.radius + 0.001)
                #expect(moving.coverage >= GlyphFigure.chaseCoverage.lowerBound - 0.001)
            }
        }
    }

    /// Three nodes peaking in turn, not three nodes doing the same thing.
    @Test("The chase peaks on one node at a time")
    func chaseRunsRoundTheFigure() {
        let peaks = GlyphFigure.chaseOffsets.map { offset -> Int in
            let plan = GlyphFigure.plan(for: .working, phase: offset)
            let coverages = plan.nodes.map(\.coverage)
            return coverages.firstIndex(of: coverages.max() ?? 0) ?? -1
        }
        #expect(Set(peaks).count == 3, "the three offsets peak on the same node")
    }

    @Test("A phase outside 0–1 wraps rather than clamping")
    func phaseWraps() {
        func plan(_ phase: Double) -> GlyphPlan { GlyphFigure.plan(for: .waiting, phase: phase) }
        #expect(plan(1.25) == plan(0.25))
        #expect(plan(-0.25) == plan(0.75))
    }
}

/// The status item's own half: caching, frame counts, and the one rule that
/// keeps an idle laptop idle.
@MainActor
@Suite("Status item glyph")
struct StatusItemGlyphTests {

    @Test("Every state draws a distinct template image")
    func imagesAreDistinct() throws {
        var seen: [Data] = []
        for kind in SessionStateKind.allCases {
            let image = StatusItemGlyph.image(for: kind)
            #expect(image.isTemplate, "\(kind) is not a template image")
            #expect(image.size == NSSize(width: 18, height: 18))
            let data = try #require(bitmapData(of: image))
            #expect(!seen.contains(data), "\(kind) draws the same glyph as another state")
            seen.append(data)
        }
    }

    /// 2200 ms at 8 fps. Eight is enough for a 2.2 s ease and halves the
    /// wake-ups against twelve.
    @Test("The Waiting pulse is sampled at 8 fps")
    func waitingFrameCount() {
        #expect(DesignTokens.Motion.glyphFrameRate == 8)
        #expect(StatusItemGlyph.frames(for: .waiting).count == 18)
        #expect(StatusItemGlyph.frameInterval == 0.125)
    }

    /// The resting image is frame zero, so the static surface and the animation
    /// cannot disagree about what a state looks like.
    @Test("The resting image is the first frame")
    func restingImageIsFrameZero() throws {
        for kind in SessionStateKind.allCases {
            let resting = try #require(bitmapData(of: StatusItemGlyph.image(for: kind)))
            let first = try #require(bitmapData(of: StatusItemGlyph.frames(for: kind)[0]))
            #expect(resting == first, "\(kind)")
        }
    }

    /// Three of the five are static. A timer running on an unchanging frame is a
    /// menu-bar app costing a laptop battery for nothing.
    @Test("Only Waiting has more than one frame")
    func onlyWaitingAnimates() {
        for kind in SessionStateKind.allCases {
            let expected = kind == .waiting
            #expect(GlyphFigure.animates(kind) == expected, "\(kind)")
            #expect((StatusItemGlyph.frames(for: kind).count > 1) == expected, "\(kind)")
        }
        // The chase is computed and left off; turning it on is this constant.
        #expect(GlyphFigure.animatesWorking == false)
    }

    /// The whole of the timer's decision, as a function of what is true rather
    /// than of what the controller remembers.
    @Test("The timer runs only for an animating state, and never under Reduce Motion")
    func timerPolicy() {
        #expect(StatusItemController.animates(.waiting, reduceMotion: false))
        #expect(!StatusItemController.animates(.waiting, reduceMotion: true))
        #expect(!StatusItemController.animates(nil, reduceMotion: false))
        for kind in [SessionStateKind.idle, .failed, .unknown, .working] {
            #expect(!StatusItemController.animates(kind, reduceMotion: false), "\(kind)")
        }
    }

    /// Nothing running takes the resting glyph rather than no glyph: a status
    /// item with no image is an invisible, unclickable one.
    @Test("No sessions still draws something")
    func emptyStateDrawsIdle() {
        #expect(StatusItemGlyph.image(for: nil).size.width == 18)
    }

    /// Built once. The arrays are small, and the status item redraws whenever
    /// the aggregate state moves.
    @Test("Frames are cached rather than rebuilt")
    func framesAreCached() {
        let first = StatusItemGlyph.frames(for: .waiting)
        let second = StatusItemGlyph.frames(for: .waiting)
        #expect(zip(first, second).allSatisfy { $0 === $1 })
    }

    private func bitmapData(of image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
