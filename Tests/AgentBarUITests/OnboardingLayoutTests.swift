import AgentBarCore
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentBarUI

/// The flow is hosted in the same `.intrinsicContentSize` hosting view that
/// produced this project's one CPU runaway, and unlike the session panel it has
/// no clock re-measuring behind it. So it is measured here.
@MainActor
@Suite("Onboarding layout")
struct OnboardingLayoutTests {

    private static func host<Content: View>(_ content: Content) -> NSHostingView<Content> {
        let view = NSHostingView(rootView: content)
        view.sizingOptions = [.intrinsicContentSize]
        view.frame = NSRect(
            x: 0, y: 0, width: OnboardingView.width, height: view.fittingSize.height)
        return view
    }

    private static func model(at step: OnboardingStep) async -> OnboardingModel {
        let panel = StubServices()
        panel.storedStatuses = [
            UIFixture.status(.claudeCode, .connected),
            UIFixture.status(.codex, .notTrusted),
        ]
        let suite = "com.molodykhvitalii.AgentBar.tests.layout"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let model = OnboardingModel(
            panel: panel, settings: StubSettingsServices(),
            state: OnboardingState(defaults: defaults))
        await model.refresh()
        while model.step != step, model.step != .done { await model.next() }
        return model
    }

    private static func view(_ model: OnboardingModel) -> some View {
        OnboardingView(model: model, onOpenSettings: {})
            .environment(\.accessibilityPreferences, AccessibilityPreferences.shared)
    }

    /// Every step has to settle in one pass. A step that does not is a window
    /// whose height feeds back into its own measurement, which is the shape of
    /// the defect that cost 98 % of a core in the sibling panel.
    @Test("Every step is a fixed point", arguments: OnboardingStep.allCases)
    func everyStepSettles(step: OnboardingStep) async {
        let view = Self.host(Self.view(await Self.model(at: step)))

        view.layoutSubtreeIfNeeded()
        let first = view.fittingSize
        for _ in 0..<5 { view.layoutSubtreeIfNeeded() }

        #expect(view.fittingSize == first, "\(step): \(view.fittingSize) against \(first)")
        #expect(first.height > 0)
        #expect(!view.needsLayout, "\(step) is still asking for another pass")
    }

    /// Wider than the panel's 380, and fixed. The controller positions against
    /// this number, so a step that widened it would put the flow off-centre from
    /// the item it is teaching.
    @Test("Every step is exactly the flow's width")
    func widthIsFixed() async {
        for step in OnboardingStep.allCases {
            let view = Self.host(Self.view(await Self.model(at: step)))
            #expect(view.fittingSize.width == OnboardingView.width, "\(step)")
        }
    }

    /// The steps differ in height, which is why the window is re-measured at
    /// all — and why it is re-measured twice, once the transition has settled.
    @Test("The steps are not all the same height")
    func heightsDiffer() async {
        var heights: Set<CGFloat> = []
        for step in OnboardingStep.allCases {
            heights.insert(Self.host(Self.view(await Self.model(at: step))).fittingSize.height)
        }
        #expect(heights.count > 1, "every step measures the same; the re-measure is untested")
    }

    /// The window is borderless and does not resize itself, so **every** change
    /// that can move a step's height has to announce itself. This is the model's
    /// half of that contract; the controller's half is compile-enforced, because
    /// `onContentChange` names `repositionOnboarding` directly.
    ///
    /// > Worth pinning because it already failed silently once: the property and
    /// > the doc comment for the second measurement existed while the function
    /// > they described did not, and nothing — not the compiler, not the suite,
    /// > not lint — had anything to say about it.
    @Test("Every content change announces itself")
    func everyChangeAnnouncesItself() async {
        let panel = StubServices()
        panel.storedStatuses = [UIFixture.status(.claudeCode, .notConnected)]
        let suite = "com.molodykhvitalii.AgentBar.tests.announce"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let settings = StubSettingsServices()
        // Unasked, so the permission step has something to do. An already-granted
        // permission makes `requestPermission` a correct no-op, which announces
        // nothing — rightly, since it changed nothing.
        settings.permissionState = .notAsked
        let model = OnboardingModel(
            panel: panel, settings: settings,
            state: OnboardingState(defaults: defaults))

        var announcements = 0
        model.onContentChange = { announcements += 1 }

        await model.refresh()
        #expect(announcements == 1, "a refresh did not announce")

        await model.next()
        #expect(announcements == 2, "a step change did not announce")

        await model.perform(.connect, for: .claudeCode)
        #expect(announcements == 3, "an action did not announce")

        await model.back()
        #expect(announcements == 4, "going back did not announce")

        await model.skip()
        #expect(announcements == 5, "a skip did not announce")

        await model.requestPermission()
        #expect(announcements == 6, "asking for permission did not announce")
    }

    /// The second measurement has to land *after* the step's own transition, or
    /// it samples the same in-flight height the first one did.
    @Test("The re-measure waits out the step transition")
    func remeasureOutlastsTheTransition() {
        #expect(
            MenuBarController.onboardingRemeasureDelay > DesignTokens.Motion.rise,
            "the second measurement lands inside the cross-fade it exists to outlast")
    }

    /// The watch exists so a change made outside the app appears without a
    /// keystroke. Leaving the notification step out of it was a defect: its
    /// `.denied` branch sends the user to System Settings and the flow's panel
    /// does not close while they are away.
    @Test("The watch ticks on every step whose answer can change elsewhere")
    func watchedSteps() {
        #expect(MenuBarController.watches(.claudeCode))
        #expect(MenuBarController.watches(.codex))
        #expect(MenuBarController.watches(.notifications))
        #expect(!MenuBarController.watches(.welcome))
        #expect(!MenuBarController.watches(.done))
    }
}
