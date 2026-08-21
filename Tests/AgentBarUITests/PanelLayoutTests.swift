import AgentBarCore
import AppKit
import SwiftUI
import Testing

@testable import AgentBarUI

/// Whether measuring the panel changes what it measures.
///
/// This suite exists because of a failure no assertion about *appearance* could
/// have caught. The system's own record for 2026-08-20 has AgentBar burning
/// **90 seconds of CPU over 92 — 98 % of a core** — with every sample inside
/// `NSHostingView.layout()`, walking the panel from `PanelView` down through the
/// rows to the footer, and `ScrollViewHelper.updateGraphState` queueing the next
/// update from inside the current one. The pixels were correct the whole time.
///
/// > **What this suite does and does not prove.** A hosting view's size being a
/// > fixed point is necessary for the display cycle to settle and is not
/// > sufficient: reproducing the runaway needed the real app, its floating
/// > panel and its clocks, and a harness that pumped the run loop here was
/// > removed rather than kept — it never reproduced the defect, and blocking the
/// > main thread in a parallel suite is what starved the power module's timing
/// > tests once already. The measurement that *can* see the runaway lives in
/// > `scripts/perf-probe.py`, which drives a running AgentBar and samples it.
@MainActor
@Suite("Panel layout")
struct PanelLayoutTests {

    /// The hosting view the panel really uses.
    ///
    /// `sizingOptions = [.intrinsicContentSize]` is not decoration: it is what
    /// `PanelController` sets, and it is the edge that carries a SwiftUI size
    /// change out into the window's layout and back. A proof that left it off
    /// would be a proof about a different view.
    private static func host<Content: View>(_ content: Content) -> NSHostingView<Content> {
        let view = NSHostingView(rootView: content)
        view.sizingOptions = [.intrinsicContentSize]
        view.frame = NSRect(
            x: 0, y: 0, width: DesignTokens.panelWidth, height: view.fittingSize.height)
        return view
    }

    private static func panel(_ model: PanelModel) -> some View {
        PanelView(model: model, onSettings: {}, onQuit: {})
            .environment(\.accessibilityPreferences, AccessibilityPreferences.shared)
    }

    private static func loaded(_ count: Int) async -> PanelModel {
        let services = StubServices()
        services.storedSnapshot = UIFixture.snapshot(sessions(count))
        services.storedStatuses = [UIFixture.status(.claudeCode, .connected)]
        let model = PanelModel(services: services)
        await model.refreshIntegrations()
        await model.refreshSnapshot()
        return model
    }

    /// Twelve rather than a day's worth: the list is past its 340 pt cap by
    /// six, and every extra row is SwiftUI layout done on the main actor while
    /// the rest of the suite is measuring real intervals against the same pool.
    private static func sessions(_ count: Int) -> [Session] {
        (0..<count).map { index in
            UIFixture.session(
                "session-\(index)",
                project: "/Users/dev/code/project-\(index % 4)",
                state: index.isMultiple(of: 3) ? .idle : .working,
                timeInState: .seconds(index * 7))
        }
    }

    /// A list past its cap, which is the side of the overflow decision the
    /// feedback edge lived on: the fade is applied, and applying it must not
    /// change the height that decided to apply it.
    @Test("Measuring a long panel does not change its size")
    func longListIsAFixedPoint() async {
        let view = Self.host(Self.panel(await Self.loaded(12)))

        view.layoutSubtreeIfNeeded()
        let first = view.fittingSize
        for _ in 0..<5 { view.layoutSubtreeIfNeeded() }

        #expect(
            view.fittingSize == first,
            "\(view.fittingSize) after five passes against \(first) after one")
        #expect(first.height > 0)
        #expect(!view.needsLayout, "a settled panel must not be asking for another pass")
    }

    /// The other branch of the same decision. Both have to settle, or the panel
    /// spins in whichever state the user's day happens to put it in.
    @Test("Measuring a short panel does not change its size")
    func shortListIsAFixedPoint() async {
        let view = Self.host(Self.panel(await Self.loaded(1)))

        view.layoutSubtreeIfNeeded()
        let first = view.fittingSize
        for _ in 0..<5 { view.layoutSubtreeIfNeeded() }

        #expect(view.fittingSize == first)
        #expect(!view.needsLayout)
    }

    /// The panel is content-sized, so a list that grows is a window that grows —
    /// which is what `PanelController.reposition` is for, and what makes its
    /// "nothing moved, nothing is set" guard worth having rather than a guard
    /// that never fires. Up to the cap, and then not: past it the list scrolls.
    ///
    /// The capped half is asserted as an **equality between two lengths**, not as
    /// slack against a number. A tolerance wide enough to hold twelve rows is
    /// wide enough to hold twelve uncapped ones too, so it would pass with the
    /// cap removed; two lists that differ by fifty rows and not by a pixel
    /// cannot.
    @Test("A longer list is a taller panel, up to the list's cap")
    func heightFollowsContentToTheCap() async {
        let short = Self.host(Self.panel(await Self.loaded(1))).fittingSize.height
        let capped = Self.host(Self.panel(await Self.loaded(12))).fittingSize.height
        let farPastTheCap = Self.host(Self.panel(await Self.loaded(60))).fittingSize.height

        #expect(capped > short, "\(capped) is not taller than \(short)")
        #expect(
            capped == farPastTheCap,
            "twelve rows measure \(capped) and sixty measure \(farPastTheCap): the cap is gone")
    }
}
