import AgentBarCore
import CoreGraphics
import SwiftUI

/// The three-node figure, as geometry rather than as drawing.
///
/// Two nodes at the base, one at the apex, joined by hairline links. The apex is
/// the **state node**: it is the only element whose shape changes, so the eye has
/// a fixed frame of reference and exactly one moving part. The same figure is the
/// app's logo mark, which is why the menu bar, the banner and the app icon finally
/// agree about what AgentBar looks like.
///
/// > **Why this is a plan and not a draw call.** The figure is rendered three
/// > ways — an AppKit template image for the status item, a SwiftUI canvas for
/// > the panel header and the onboarding, and a gradient square for the
/// > notification attachment. Three renderers reading one set of numbers cannot
/// > drift; three renderers each holding their own copy of the numbers would,
/// > and the drift would be invisible until somebody put the surfaces side by
/// > side. So the geometry is computed once, here, and the renderers only fill
/// > and stroke what they are handed.
///
/// Everything is expressed on the **18 × 18 point menu-bar canvas with y up**,
/// which is AppKit's convention and the one `NSBezierPath` wants. A renderer
/// working in a different space scales by `size / canvas` and flips if it must.
nonisolated public enum GlyphFigure {

    // MARK: - Geometry

    /// The canvas everything below is measured on.
    public static let canvas: CGFloat = 18

    public static let apexCentre = CGPoint(x: 9.0, y: 13.0)
    public static let baseLeftCentre = CGPoint(x: 4.5, y: 5.0)
    public static let baseRightCentre = CGPoint(x: 13.5, y: 5.0)

    public static let baseRadius: CGFloat = 1.90
    public static let apexRadius: CGFloat = 2.40
    /// Waiting's apex is a hair larger than the others', because a filled disc
    /// with a ring leaving it reads smaller than a plain one.
    public static let apexFilledRadius: CGFloat = 2.50

    /// The stroke a hollow node is drawn with.
    public static let nodeStroke: CGFloat = 0.90
    public static let linkWidth: CGFloat = 0.80
    /// Links are drawn at this fraction of whatever coverage the state has, so
    /// they stay subordinate to the nodes in every state rather than only in the
    /// bright ones.
    public static let linkCoverageRatio: CGFloat = 0.45

    public static let failedSide: CGFloat = 4.60
    public static let failedCorner: CGFloat = 1.20

    public static let pulseStroke: CGFloat = 1.20

    /// The whole figure's coverage at rest. Nearly invisible on purpose: the
    /// resting state must not draw the eye, and this is the `idleOpacity` the
    /// previous glyph already had.
    public static let idleCoverage: CGFloat = 0.40
    /// Brighter than idle and dimmer than the rest: `unknown` is drawn entirely
    /// in dashes, and a dashed figure loses coverage to its own gaps.
    public static let unknownCoverage: CGFloat = 0.60

    public static let nodeDash: [CGFloat] = [1.2, 1.3]
    public static let linkDash: [CGFloat] = [1.3, 1.7]

    /// Derived, and worth checking against: the optical bounding box is
    /// 12.8 × 12.8 pt, 71 % of the canvas. Deliberately wider than the old
    /// disc's 67 % — an outlined, mostly empty figure reads lighter than a solid
    /// one of the same diameter and needs the width to hold equal weight beside
    /// a battery glyph.
    public static let opticalWidth: CGFloat =
        (baseRightCentre.x + baseRadius) - (baseLeftCentre.x - baseRadius)

    // MARK: - Animation

    /// The Waiting ring's travel, as a multiple of the apex radius.
    public static let pulseScale: ClosedRange<CGFloat> = 0.70...2.10
    /// It fades as it goes: a ring that stayed opaque would read as a second
    /// permanent element rather than as an emission.
    public static let pulsePeakCoverage: CGFloat = 0.75
    /// How the fade is shaped against the expansion.
    ///
    /// > **A deliberate softening of the handoff's linear fade.** The ring is
    /// > born at 0.70 of the apex radius — *inside* the filled apex — and the
    /// > expansion curve is fast out, so a fade running linearly against it
    /// > spends most of the ring's coverage in the frames where the ring is
    /// > still hidden. It emerges already faint, which is the opposite of an
    /// > emission. An exponent below one holds the coverage while the ring
    /// > clears the apex and takes the rest of the cycle to disappear; the
    /// > endpoints are unchanged, so the ring still reaches nothing at the loop
    /// > point and still never jolts.
    public static let pulseFade: Double = 0.6
    /// The gap the ring must show between itself and the apex before the figure
    /// is allowed to rest on it. Below this the two merge into one slightly
    /// larger, slightly softer node — which is Working with extra steps.
    public static let pulseClearance: CGFloat = 0.35

    /// The Working chase's floor and its node scaling.
    public static let chaseCoverage: ClosedRange<CGFloat> = 0.28...1.00
    public static let chaseScale: ClosedRange<CGFloat> = 0.86...1.00

    /// Where in its own cycle the Waiting glyph rests.
    ///
    /// > **This is a deliberate refinement of the handoff's "show frame 0".**
    /// > At phase zero the ring is still inside the filled apex, so the figure
    /// > is a filled triangle — which is *Working*. A resting frame that cannot
    /// > be told from another state fails the one acceptance criterion that
    /// > matters, and Reduce Motion, a sleeping timer and a profiler run all
    /// > produce exactly that frame. So the cycle is phase-shifted to start at
    /// > the **earliest** phase where the ring has cleared the apex: frame 0 is
    /// > still literally the first frame of the array, it is legible, and it is
    /// > as bright as a separated ring can be, because the fade only ever costs
    /// > coverage from here on.
    ///
    /// Searched rather than written down, so that moving the curve, the travel
    /// or the apex radius moves this with them instead of leaving a constant
    /// that used to be right.
    public static let waitingRestingPhase: Double = {
        let cleared = apexFilledRadius + pulseClearance + pulseStroke / 2
        let steps = 400
        for step in 0...steps where pulseRadius(atPhase: Double(step) / Double(steps)) >= cleared {
            return Double(step) / Double(steps)
        }
        return 0
    }()

    /// The ring's radius at a point in the cycle.
    public static func pulseRadius(atPhase phase: Double) -> CGFloat {
        let travelled = CGFloat(DesignTokens.Motion.pulse.value(at: wrapped(phase)))
        return apexRadius
            * (pulseScale.lowerBound + (pulseScale.upperBound - pulseScale.lowerBound) * travelled)
    }

    /// The ring's coverage at a point in the cycle.
    public static func pulseCoverage(atPhase phase: Double) -> CGFloat {
        let travelled = Double(DesignTokens.Motion.pulse.value(at: wrapped(phase)))
        return pulsePeakCoverage * CGFloat(pow(max(0, 1 - travelled), pulseFade))
    }

    /// The phase offsets of the three nodes in the Working chase — 0, 500 and
    /// 1000 ms of a 1500 ms cycle, base to apex.
    public static let chaseOffsets: [Double] = [0, 1.0 / 3.0, 2.0 / 3.0]

    /// How many frames a state's cycle is sampled into, at
    /// `DesignTokens.Motion.glyphFrameRate`.
    public static func frameCount(for duration: Duration) -> Int {
        max(1, Int((duration.seconds * DesignTokens.Motion.glyphFrameRate).rounded()))
    }

    // MARK: - The plan

    /// The figure for a state, at a point in its cycle.
    ///
    /// `phase` is a fraction of that state's own cycle. `nil` asks for the
    /// resting figure, which is what every static surface draws and what Reduce
    /// Motion leaves on screen.
    public static func plan(for state: SessionStateKind, phase: Double? = nil) -> GlyphPlan {
        switch state {
        case .idle: idlePlan()
        case .working: workingPlan(phase: phase)
        case .waiting: waitingPlan(phase: phase ?? waitingRestingPhase)
        case .failed: failedPlan()
        case .unknown: unknownPlan()
        }
    }

    /// Whether this state has anything to animate at all.
    ///
    /// The timer that drives the status item asks this and nothing else, which
    /// is what makes "invalidated at rest" a property of the figure rather than
    /// a rule the controller has to remember.
    public static func animates(_ state: SessionStateKind) -> Bool {
        switch state {
        case .waiting: true
        case .working: animatesWorking
        case .idle, .failed, .unknown: false
        }
    }

    /// Whether the Working chase runs in the menu bar.
    ///
    /// **Off.** The pulse recruits attention across a room and earns a timer;
    /// the chase says "an agent is busy", which the panel, the row hairline and
    /// the fact that the user just started the agent all say already — and it
    /// would run for most of a working day, as a permanently moving thing in
    /// peripheral vision. The chase is computed either way, so turning it on is
    /// this constant and nothing else.
    public static let animatesWorking = false

    /// The cycle a state animates over, or `nil` when it does not animate.
    public static func cycle(for state: SessionStateKind) -> Duration? {
        switch state {
        case .waiting: DesignTokens.Motion.waitingPulse
        case .working: animatesWorking ? DesignTokens.Motion.workingChase : nil
        case .idle, .failed, .unknown: nil
        }
    }

    // MARK: - Per state

    private static func idlePlan() -> GlyphPlan {
        GlyphPlan(
            apex: node(apexCentre, apexRadius, .ring, idleCoverage),
            baseLeft: node(baseLeftCentre, baseRadius, .ring, idleCoverage),
            baseRight: node(baseRightCentre, baseRadius, .ring, idleCoverage),
            linkCoverage: idleCoverage * linkCoverageRatio,
            linkIsDashed: false,
            pulse: nil)
    }

    private static func workingPlan(phase: Double?) -> GlyphPlan {
        // The resting figure is all three nodes filled at full coverage. The
        // chase only ever cycles *down* from it, so a stopped chase is the
        // Working glyph rather than a dimmed accident.
        guard let phase else {
            return GlyphPlan(
                apex: node(apexCentre, apexRadius, .disc, 1),
                baseLeft: node(baseLeftCentre, baseRadius, .disc, 1),
                baseRight: node(baseRightCentre, baseRadius, .disc, 1),
                linkCoverage: linkCoverageRatio,
                linkIsDashed: false,
                pulse: nil)
        }
        let centres = [baseLeftCentre, baseRightCentre, apexCentre]
        let radii = [baseRadius, baseRadius, apexRadius]
        let chased = (0..<3).map { index -> GlyphPlan.Node in
            let wave = raisedCosine(phase - chaseOffsets[index])
            let coverage =
                chaseCoverage.lowerBound
                + (chaseCoverage.upperBound - chaseCoverage.lowerBound) * wave
            let scale =
                chaseScale.lowerBound + (chaseScale.upperBound - chaseScale.lowerBound) * wave
            return node(centres[index], radii[index] * scale, .disc, coverage)
        }
        return GlyphPlan(
            apex: chased[2],
            baseLeft: chased[0],
            baseRight: chased[1],
            linkCoverage: linkCoverageRatio,
            linkIsDashed: false,
            pulse: nil)
    }

    private static func waitingPlan(phase: Double) -> GlyphPlan {
        GlyphPlan(
            apex: node(apexCentre, apexFilledRadius, .disc, 1),
            baseLeft: node(baseLeftCentre, baseRadius, .disc, 1),
            baseRight: node(baseRightCentre, baseRadius, .disc, 1),
            linkCoverage: linkCoverageRatio,
            linkIsDashed: false,
            pulse: GlyphPlan.Pulse(
                centre: apexCentre,
                radius: pulseRadius(atPhase: phase),
                stroke: pulseStroke,
                coverage: pulseCoverage(atPhase: phase)))
    }

    private static func failedPlan() -> GlyphPlan {
        var apex = node(apexCentre, failedSide / 2, .roundedSquare, 1)
        // A square's corner sits further out than its edge, so a link trimmed at
        // half the side would tuck under it. Trimming a shade short is what
        // keeps the hairline from poking out of the corner.
        apex.linkInset = failedSide / 2 * 0.86
        return GlyphPlan(
            apex: apex,
            baseLeft: node(baseLeftCentre, baseRadius, .disc, 1),
            baseRight: node(baseRightCentre, baseRadius, .disc, 1),
            linkCoverage: linkCoverageRatio,
            linkIsDashed: false,
            pulse: nil)
    }

    private static func unknownPlan() -> GlyphPlan {
        GlyphPlan(
            apex: node(apexCentre, apexRadius, .dashedRing, unknownCoverage),
            baseLeft: node(baseLeftCentre, baseRadius, .dashedRing, unknownCoverage),
            baseRight: node(baseRightCentre, baseRadius, .dashedRing, unknownCoverage),
            linkCoverage: unknownCoverage * linkCoverageRatio,
            linkIsDashed: true,
            pulse: nil)
    }

    private static func node(
        _ centre: CGPoint, _ radius: CGFloat, _ shape: GlyphPlan.NodeShape, _ coverage: CGFloat
    ) -> GlyphPlan.Node {
        GlyphPlan.Node(
            centre: centre, radius: radius, shape: shape, coverage: coverage, linkInset: radius)
    }

    /// A symmetric wave peaking at zero. Symmetric matters: the chase loops, and
    /// a curve with different slopes either side of its peak jolts at the seam.
    private static func raisedCosine(_ phase: Double) -> CGFloat {
        CGFloat((cos(2 * .pi * wrapped(phase)) + 1) / 2)
    }

    /// Any phase brought back into `[0, 1)`, negatives included.
    static func wrapped(_ phase: Double) -> Double {
        let fraction = phase.truncatingRemainder(dividingBy: 1)
        return fraction < 0 ? fraction + 1 : fraction
    }
}

/// One rendering of the figure: three nodes, three links, and possibly a ring
/// leaving the apex.
///
/// Coverage rather than colour, because the status item's version is a template
/// image and a template image has one channel of alpha — no colour survives
/// tinting. The surfaces that *may* use colour multiply their own into it.
nonisolated public struct GlyphPlan: Sendable, Equatable {

    public enum NodeShape: Sendable, Equatable {
        case disc
        case ring
        case dashedRing
        case roundedSquare
    }

    public struct Node: Sendable, Equatable {
        public var centre: CGPoint
        /// Half the drawn extent — the circle's radius, or half the square's
        /// side.
        public var radius: CGFloat
        public var shape: NodeShape
        public var coverage: CGFloat
        /// Where a link entering this node stops.
        ///
        /// Links stop at the node's edge rather than running to its centre,
        /// because a hollow node with a hairline crossing its middle reads as a
        /// mistake at any size.
        public var linkInset: CGFloat
    }

    public struct Pulse: Sendable, Equatable {
        public var centre: CGPoint
        public var radius: CGFloat
        public var stroke: CGFloat
        public var coverage: CGFloat
    }

    public struct Link: Sendable, Equatable {
        public var from: CGPoint
        public var to: CGPoint
    }

    public var apex: Node
    public var baseLeft: Node
    public var baseRight: Node
    public var linkCoverage: CGFloat
    public var linkIsDashed: Bool
    public var pulse: Pulse?

    /// Base first, apex last, which is also the paint order: the state node is
    /// the one that may overlap and it belongs on top.
    public var nodes: [Node] { [baseLeft, baseRight, apex] }

    /// The three links, already trimmed to the nodes they join.
    public var links: [Link] {
        [
            link(baseLeft, baseRight),
            link(baseLeft, apex),
            link(baseRight, apex),
        ]
    }

    private func link(_ start: Node, _ end: Node) -> Link {
        let dx = end.centre.x - start.centre.x
        let dy = end.centre.y - start.centre.y
        let length = (dx * dx + dy * dy).squareRoot()
        // Two nodes on top of each other cannot happen with the fixed centres
        // above, but a zero length would divide by zero rather than draw
        // nothing, which is a crash rather than an invisible link.
        guard length > 0 else { return Link(from: start.centre, to: end.centre) }
        let unit = CGPoint(x: dx / length, y: dy / length)
        return Link(
            from: CGPoint(
                x: start.centre.x + unit.x * start.linkInset,
                y: start.centre.y + unit.y * start.linkInset),
            to: CGPoint(
                x: end.centre.x - unit.x * end.linkInset,
                y: end.centre.y - unit.y * end.linkInset))
    }
}
