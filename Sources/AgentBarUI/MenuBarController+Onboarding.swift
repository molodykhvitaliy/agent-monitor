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
                onOpenSettings: { [weak self] in self?.showSettings() }
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
            guard let self, let button = self.statusItem?.button else { return }
            self.onboardingPanel?.reposition(under: button)
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

    /// Re-reads the install reports while an install step is showing.
    ///
    /// Bounded twice over: it only runs while the flow's panel is up, and it
    /// only asks on the two steps whose answer can change from outside the app.
    func startOnboardingWatch() {
        onboardingWatch?.cancel()
        onboardingWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.onboardingWatchInterval)
                guard let self, !Task.isCancelled else { return }
                guard self.onboardingPanel?.isVisible == true else { return }
                guard self.onboarding.step.provider != nil else { continue }
                await self.onboarding.refresh()
            }
        }
    }

    /// Tears the flow down, whichever way it ended, and hands the user the panel
    /// the flow spent five steps pointing at.
    func endOnboarding() {
        onboardingWatch?.cancel()
        onboardingWatch = nil
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
