import AgentBarCore
import AppKit
import SwiftUI
import Testing

@testable import AgentBarUI

/// The panel's answer to "is anything urgent?", which it could not give before
/// without the user reading every row.
@MainActor
@Suite("Panel header")
struct PanelHeaderTests {

    /// Waiting outranks failed because a waiting agent is blocked on this person
    /// *right now* and a failed one has already stopped. That is `attentionRank`
    /// and not a decision the header makes.
    @Test("Waiting wins over failed, and both win over nothing")
    func orderedRulesFirstMatchWins() throws {
        let waitingAndFailed = UIFixture.snapshot([
            UIFixture.session("a", state: .failed(reason: "boom")),
            UIFixture.session("b", state: .waitingInput(question: nil)),
        ])
        let summary = try #require(PanelHeaderSummary.summarise(waitingAndFailed))
        #expect(summary.shape == .waiting)
        #expect(summary.color == .stateWaiting)
        #expect(summary.count == 1)
        #expect(summary.text == "1 waiting for you")

        let failedOnly = UIFixture.snapshot([
            UIFixture.session("a", state: .failed(reason: "boom"))
        ])
        let failure = try #require(PanelHeaderSummary.summarise(failedOnly))
        #expect(failure.shape == .failed)
        #expect(failure.color == .stateFailed)
        #expect(failure.text == "1 failed")
    }

    /// Absent rather than reassuring. A permanent `0 waiting` is a thing the eye
    /// learns to stop reading, which costs the pill its meaning on the day it
    /// matters.
    @Test("A quiet panel has no pill at all")
    func quietPanelHasNoSummary() {
        #expect(PanelHeaderSummary.summarise(.empty) == nil)
        let busy = UIFixture.snapshot([
            UIFixture.session("a", state: .working),
            UIFixture.session("b", state: .idle),
        ])
        #expect(PanelHeaderSummary.summarise(busy) == nil)
    }

    @Test("The count is every matching session, across every project")
    func countsAcrossProjects() throws {
        let snapshot = UIFixture.snapshot([
            UIFixture.session("a", project: "/Users/dev/one", state: .waitingInput(question: nil)),
            UIFixture.session("b", project: "/Users/dev/two", state: .waitingInput(question: "?")),
            UIFixture.session("c", project: "/Users/dev/two", state: .working),
        ])
        let summary = try #require(PanelHeaderSummary.summarise(snapshot))
        #expect(summary.count == 2)
        #expect(summary.text == "2 waiting for you")
    }

    /// The header and the footer answer different questions from different
    /// sources — how many need you, and whether the plumbing is healthy. A
    /// header derived from the integrations, or a footer derived from the
    /// snapshot, would leave the panel saying the same thing twice and the other
    /// thing not at all.
    @Test("The header and the footer never say the same thing")
    func headerAndFooterAreIndependent() {
        let quiet = StoreSnapshot.empty
        let broken = [UIFixture.status(.claudeCode, .notReceiving)]
        #expect(PanelHeaderSummary.summarise(quiet) == nil)
        #expect(FooterStatus.summarise(broken).text == "Not receiving events")

        let waiting = UIFixture.snapshot([
            UIFixture.session("a", state: .waitingInput(question: nil))
        ])
        let healthy = [UIFixture.status(.claudeCode, .connected)]
        #expect(PanelHeaderSummary.summarise(waiting)?.text == "1 waiting for you")
        #expect(FooterStatus.summarise(healthy).text == "1 of 1 connected")
    }
}

/// The v2 additions are the kind that move layout, so they are measured rather
/// than looked at. The panel's height feeding back into its own measurement is
/// what pegged a CPU core once already.
@MainActor
@Suite("Panel treatment layout")
struct PanelTreatmentLayoutTests {

    private static func host<Content: View>(_ content: Content) -> NSHostingView<Content> {
        let view = NSHostingView(rootView: content)
        view.sizingOptions = [.intrinsicContentSize]
        view.frame = NSRect(
            x: 0, y: 0, width: DesignTokens.panelWidth, height: view.fittingSize.height)
        return view
    }

    private static func model(_ sessions: [Session]) async -> PanelModel {
        let services = StubServices()
        services.storedSnapshot = UIFixture.snapshot(sessions)
        services.storedStatuses = [UIFixture.status(.claudeCode, .connected)]
        let model = PanelModel(services: services)
        await model.refreshIntegrations()
        await model.refreshSnapshot()
        return model
    }

    private static func panel(_ model: PanelModel) -> some View {
        PanelView(model: model, onSettings: {}, onQuit: {})
            .environment(\.accessibilityPreferences, AccessibilityPreferences.shared)
    }

    /// The header's height is stated, not derived. A header that grew when the
    /// pill appeared would push every row down at the exact moment something
    /// started waiting — the worst moment for the list to move under a pointer
    /// that is reaching for it.
    @Test("The pill appearing does not change the header's height")
    func headerHeightIsFixed() {
        let quiet = Self.host(
            PanelHeaderView(summary: nil, state: .idle)
                .frame(width: DesignTokens.panelWidth)
                .environment(\.accessibilityPreferences, AccessibilityPreferences.shared))
        let urgent = Self.host(
            PanelHeaderView(
                summary: PanelHeaderSummary(
                    shape: .waiting, color: .stateWaiting, text: "3 waiting for you", count: 3),
                state: .waiting
            )
            .frame(width: DesignTokens.panelWidth)
            .environment(\.accessibilityPreferences, AccessibilityPreferences.shared))

        #expect(quiet.fittingSize.height == urgent.fittingSize.height)
        // 41 pt, plus the hairline beneath it.
        #expect(quiet.fittingSize.height >= DesignTokens.Header.height)
        #expect(quiet.fittingSize.height < DesignTokens.Header.height + 2)
    }

    /// Everything v2 adds to the panel is either a fixed height or a background,
    /// so the panel must still settle in one pass.
    @Test("A waiting panel with a working row is still a fixed point")
    func treatedPanelSettles() async {
        let view = Self.host(
            Self.panel(
                await Self.model([
                    UIFixture.session("a", state: .waitingInput(question: "Which one?")),
                    UIFixture.session("b", state: .working),
                    UIFixture.session("c", state: .failed(reason: "boom")),
                ])))

        view.layoutSubtreeIfNeeded()
        let first = view.fittingSize
        for _ in 0..<5 { view.layoutSubtreeIfNeeded() }

        #expect(view.fittingSize == first, "\(view.fittingSize) against \(first)")
        #expect(!view.needsLayout, "a settled panel must not be asking for another pass")
    }

    /// The wash is a background and the header is a fixed height, so turning the
    /// wash on must cost the panel exactly nothing in layout — otherwise a
    /// session starting to wait resizes the window.
    @Test("The waiting wash costs no height")
    func washIsFree() async {
        let waiting = await Self.model([UIFixture.session("a", state: .waitingInput(question: nil))]
        )
        let idle = await Self.model([UIFixture.session("a", state: .idle)])
        #expect(waiting.isAnyoneWaiting)
        #expect(!idle.isAnyoneWaiting)
        // Both rows are one line with no detail, so any difference in height is
        // the wash — which must not have one.
        #expect(
            Self.host(Self.panel(waiting)).fittingSize.height
                == Self.host(Self.panel(idle)).fittingSize.height)
    }

    /// The two repeating indicators in the panel read this, so a panel that
    /// starts life believing it is on screen would run both behind a window
    /// nobody has opened yet.
    @Test("A fresh panel does not believe it is on screen")
    func visibilityStartsFalse() {
        #expect(!PanelModel(services: StubServices()).isOnScreen)
    }

    /// The default is the other way round on purpose: a host that has not wired
    /// the flag — a preview, a render proof, a test — should see the designed
    /// appearance rather than a silently frozen one.
    @Test("A view with nobody driving it animates")
    func environmentDefaultRuns() {
        #expect(EnvironmentValues().surfaceIsOnScreen)
    }

    /// The hairline is the one addition that is *meant* to change a row's
    /// height, and only for the state that earns it.
    @Test("Only a working row carries the progress hairline")
    func onlyWorkingRowsGrow() async {
        let working = await Self.model([UIFixture.session("a", state: .working)])
        let idle = await Self.model([UIFixture.session("a", state: .idle)])
        let taller = Self.host(Self.panel(working)).fittingSize.height
        let plain = Self.host(Self.panel(idle)).fittingSize.height
        #expect(
            taller > plain,
            "a working row measures \(taller) and an idle one \(plain): the hairline is missing")
    }
}
