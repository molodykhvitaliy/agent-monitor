import AppKit
import Observation
import SwiftUI

/// The three system accessibility settings the panel has to honour, observed
/// live rather than read once at launch.
///
/// A user who turns Reduce Transparency on with the panel open must see it take
/// effect. The notification that says so is posted on
/// **`NSWorkspace.shared.notificationCenter`**, not the default centre;
/// registering on the wrong one fails silently, which is the worst way for an
/// accessibility setting to fail.
@Observable
public final class AccessibilityPreferences {
    /// One instance for the app.
    ///
    /// These are system-wide settings, so a second observer would watch the
    /// same three booleans to reach the same answer — and an observer
    /// registered per panel would need unregistering from a `deinit` that,
    /// being nonisolated, cannot touch a non-`Sendable` token. One long-lived
    /// instance removes the question rather than answering it.
    public static let shared = AccessibilityPreferences()

    /// Replace the material with a flat `surface` fill. Never lose the panel or
    /// its contrast.
    public private(set) var reduceTransparency: Bool
    /// Thicken the hairline, promote `ink600` to `ink900`, and raise the row
    /// tints. No heavier shadows.
    public private(set) var increaseContrast: Bool
    /// No row insert or remove animation; cross-fade instead of slide.
    public private(set) var reduceMotion: Bool

    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        let workspace = NSWorkspace.shared
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion

        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reread() }
        }
    }

    /// Re-reads all three. Exposed so a test can drive the same path the
    /// notification does without posting a system notification.
    public func reread() {
        let workspace = NSWorkspace.shared
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
    }

    /// Secondary text is promoted to primary under Increase Contrast. The
    /// design system's rule, in one place so no view has to remember it.
    public var secondaryInk: ColorToken { increaseContrast ? .ink900 : .ink600 }

    /// 1 pt normally; thicker when contrast is asked for.
    public var hairlineWidth: CGFloat { increaseContrast ? 1.5 : 1 }

    /// The row-appearance animation, or none at all.
    public var rowAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.15)
    }

    /// How a surface arrives: its own entrance, or a cross-fade of the same
    /// 150 ms `rowAnimation` already uses.
    ///
    /// Here rather than in each view, so no view reads `reduceMotion` to pick
    /// an animation — the rule is one place, and a surface that forgets it is a
    /// surface that slides for a user who asked for no sliding.
    public func entranceAnimation(_ duration: Duration = DesignTokens.Motion.drop) -> Animation {
        reduceMotion
            ? DesignTokens.Motion.animation(DesignTokens.Motion.crossFade, .linear)
            : DesignTokens.Motion.animation(duration, DesignTokens.Motion.entrance)
    }

    /// A step or content change inside a surface that is already on screen.
    public var stepAnimation: Animation {
        reduceMotion
            ? DesignTokens.Motion.animation(DesignTokens.Motion.crossFade, .linear)
            : DesignTokens.Motion.animation(DesignTokens.Motion.rise, .easeOut)
    }

    /// The delay before the nth item of a staggered entrance, in seconds.
    ///
    /// Zero under Reduce Motion, which turns a stagger into a single
    /// cross-fade — the rule lives here so a view never multiplies an index by
    /// a duration and forgets the exception.
    public func stagger(_ index: Int, by step: Duration = .milliseconds(70)) -> Double {
        reduceMotion ? 0 : Double(index) * step.seconds
    }

    /// Whether a repeating indicator should run **at all**.
    ///
    /// Not "should it be slower": a cyclical animation under Reduce Motion is
    /// stopped, not softened, and every indicator that reads this owes a static
    /// appearance that is still visibly different from its resting state. A
    /// working row must not look idle merely because nothing is moving.
    public var runsCyclicalMotion: Bool { !reduceMotion }
}

extension EnvironmentValues {
    /// Passed down rather than read per view, so one observer serves the panel.
    @Entry public var accessibilityPreferences = AccessibilityPreferences.shared
}
