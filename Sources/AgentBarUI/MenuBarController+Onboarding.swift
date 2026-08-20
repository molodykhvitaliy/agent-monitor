import AgentBarCore
import AppKit
import SwiftUI

/// Presenting the first-run flow.
///
/// A file of its own because it is a **surface**, not a clock: the rest of
/// `MenuBarController` is the status item, the panel and the two timers that
/// keep them honest, and this is a thing that happens once in the life of an
/// installation and then never again.
extension MenuBarController {

    /// Shows the five-step flow, anchored under a lit status item.
    ///
    /// > **Not a `PanelContent` case.** The flow sits *before* that decision
    /// > rather than inside it: `PanelContent.decide` chooses between the list,
    /// > the `Get Started` card and *All quiet* for a panel the user has opened,
    /// > and this is the surface they meet before they know the panel exists.
    /// > Folding it in would have made a tested pure function depend on a
    /// > persisted flag.
    func showOnboarding() {
        guard let button = statusItem?.button, onboardingPanel == nil else { return }

        let controller = PanelController(
            content: OnboardingView(
                model: onboarding,
                // Ends the flow **without** opening the panel: the user asked
                // for the settings window, and a panel flashing open behind it
                // on the way there is the app answering a question nobody asked.
                onOpenSettings: { [weak self] in
                    guard let self else { return }
                    self.endOnboarding()
                    self.showSettings()
                }
            )
            .environment(\.accessibilityPreferences, AccessibilityPreferences.shared),
            width: OnboardingView.width,
            // Clicking away dismisses it like any other panel. A first-run flow
            // that could not be dismissed would be a modal dialogue wearing a
            // panel's clothes, and the flag is written either way — the flow is
            // shown once, not until it is completed.
            onDismiss: { [weak self] in self?.endOnboarding() })
        onboardingPanel = controller

        // Re-measured on every discrete change rather than on a clock: the
        // window is borderless and does not resize itself to its content, and a
        // height fed back from layout is what pegged a core in the panel once.
        onboarding.onContentChange = { [weak self] in
            self?.repositionOnboarding()
        }
        // The flow ending on its own hands the user the panel it spent five
        // steps pointing at. Dismissing it by clicking away does not — that is
        // the user saying they are done looking, and opening something else
        // would be the app arguing.
        onboarding.onFinished = { [weak self] in
            guard let self else { return }
            self.endOnboarding()
            if let button = self.statusItem?.button {
                self.toggle(from: button, takingKeyFocus: false)
            }
        }

        statusItem?.setHighlighted(true)
        controller.show(from: button, takingKeyFocus: false)
        startOnboardingWatch()
    }

    /// Re-reads what is true while a step that can change from outside the app
    /// is showing.
    ///
    /// Bounded twice over: it only runs while the flow's panel is up, and only
    /// on the steps whose answer somebody can change elsewhere.
    ///
    /// > **The notification step is one of them, and leaving it out was a
    /// > defect.** Its `.denied` branch offers **Open System Settings**, which
    /// > is the documented recovery from a refusal — and the flow's panel does
    /// > not close while the user is away, because `hidesOnDeactivate` is false
    /// > and it never became key. Without a tick here they come back to a step
    /// > still saying *Denied in System Settings*, with Back-then-Next as the
    /// > only way to refresh and nothing to say so. `SettingsModel.refresh`
    /// > guards the identical case at length; this is where a first-time user
    /// > actually meets it.
    func startOnboardingWatch() {
        onboardingWatch?.cancel()
        onboardingWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.onboardingWatchInterval)
                guard let self, !Task.isCancelled else { return }
                guard self.onboardingPanel?.isVisible == true else { return }
                guard Self.watches(self.onboarding.step) else { continue }
                await self.onboarding.refresh()
            }
        }
    }

    /// Whether a step's answer can move without the user touching this surface.
    ///
    /// A pure decision so it can be tested — the controller itself needs a real
    /// status bar, and no test builds one.
    static func watches(_ step: OnboardingStep) -> Bool {
        switch step {
        // An installer run in a terminal, or Codex's own trust prompt.
        case .claudeCode, .codex: true
        // System Settings › Notifications, which this step sends people to.
        case .notifications: true
        // Nothing outside the app changes what these two say.
        case .welcome: false
        // The summary is re-read on entry and the flow ends here.
        case .done: false
        }
    }

    /// Tears the flow down, whichever way it ended, and hands the user the panel
    /// the flow spent five steps pointing at.
    /// How long after a step change the window is measured a second time.
    ///
    /// The step's own transition plus a frame, so the sample lands after it has
    /// settled rather than during it.
    static let onboardingRemeasureDelay: Duration =
        DesignTokens.Motion.rise + .milliseconds(60)

    /// Re-measures the flow's window, twice.
    ///
    /// > **Once is not enough, and the reason is the transition.** The window is
    /// > borderless, so nothing resizes it to its content but this; the only
    /// > caller is a discrete change — a step, an action, a refresh — which is
    /// > deliberate, because a height fed back out of layout is what pegged a
    /// > core in the sibling panel. But a step change also starts a cross-fade
    /// > during which both steps are present, and a `fittingSize` sampled then
    /// > is the taller of the two. Without a second look that figure sticks for
    /// > the whole step. The session panel is immune only because its
    /// > one-second clock re-measures; the flow has no clock, so it takes the
    /// > second measurement deliberately.
    ///
    /// `PanelController.position` skips a frame that has not moved, so the
    /// second call costs nothing whenever the first was already right.
    func repositionOnboarding() {
        guard let button = statusItem?.button else { return }
        onboardingPanel?.reposition(under: button)
        // Replaced rather than stacked: a burst of changes — a step, then the
        // refresh that follows it — must leave exactly one pending measurement.
        onboardingRemeasure?.cancel()
        onboardingRemeasure = Task { [weak self] in
            try? await Task.sleep(for: Self.onboardingRemeasureDelay)
            guard let self, !Task.isCancelled, let button = self.statusItem?.button,
                self.onboardingPanel?.isVisible == true
            else { return }
            self.onboardingPanel?.reposition(under: button)
            self.onboardingRemeasure = nil
        }
    }

    func endOnboarding() {
        onboardingWatch?.cancel()
        onboardingWatch = nil
        onboardingRemeasure?.cancel()
        onboardingRemeasure = nil
        onboarding.onContentChange = nil
        // Cleared before `finish()` below, which would otherwise call straight
        // back into here.
        onboarding.onFinished = nil
        onboardingPanel?.hide()
        onboardingPanel = nil
        statusItem?.setHighlighted(false)
        // Whichever way it ended. A flow the user dismissed is a flow they have
        // seen, and re-showing it on the next launch would be the app arguing.
        onboarding.finish()
        Task { await refresh(includingIntegrations: true) }
    }
}
