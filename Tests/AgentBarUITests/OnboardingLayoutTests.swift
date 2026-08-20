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
