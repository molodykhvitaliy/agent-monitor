import AgentBarCore
import AppKit
import Observation

/// Owns the menu-bar presence for the whole app lifetime.
///
/// The most important element in the product: it answers "does anything need
/// me?" before the panel is opened. One monochrome template image so AppKit
/// tints it for light, dark and a tinted menu bar, showing the single most
/// urgent state present — `StoreSnapshot.mostUrgentState`, which is
/// `attentionRank`'s order and nothing this class decides.
public final class StatusItemController {
    /// Held for the app's lifetime: `NSStatusBar` drops an item as soon as its
    /// last strong reference goes away, which silently removes it from the bar.
    private let statusItem: NSStatusItem
    private let onActivate: (NSStatusBarButton, Bool) -> Void

    /// What the item currently draws, so a redraw that would change nothing is
    /// skipped. The closed-panel poll runs once a minute and most ticks move
    /// neither of these.
    private var shownState: SessionStateKind??
    private var shownWaitingCount: Int?
    /// The sentence currently set, cached separately from the glyph.
    ///
    /// It depends on *which* session is leading, not only on the aggregate, so
    /// it can change while the glyph does not: one waiting session answered and
    /// another starting in a different project leaves the state and the count
    /// alone and makes the sentence wrong.
    private var shownDescription: String?

    /// The frames of the state currently shown. One entry for a state that does
    /// not animate, which is most of them.
    private var frames: [NSImage] = []
    private var frameIndex = 0
    /// **One timer for the whole status item**, and only while the aggregate
    /// state has something to animate. Idle, Failed and Unknown are static, and
    /// leaving a timer running with an unchanging frame is a menu-bar app
    /// costing a laptop battery for nothing.
    private var animation: Timer?
    private let accessibility: AccessibilityPreferences

    /// `onActivate` receives the button to anchor against and whether the click
    /// asked for keyboard focus.
    public init(
        accessibility: AccessibilityPreferences = .shared,
        onActivate: @escaping (NSStatusBarButton, Bool) -> Void
    ) {
        self.accessibility = accessibility
        self.onActivate = onActivate
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        observeReduceMotion()
    }

    /// The anchor a panel positions itself against.
    public var button: NSStatusBarButton? { statusItem.button }

    /// Removes the item from the menu bar. Present so teardown is explicit
    /// rather than a side effect of deallocation.
    public func remove() {
        stopAnimating()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Redraws only when the aggregate state or the waiting count actually
    /// moved. Everything else about a snapshot — durations ticking, a tool
    /// changing — is the panel's business, not the menu bar's.
    public func update(from snapshot: StoreSnapshot) {
        guard let button = statusItem.button else { return }
        let state = snapshot.mostUrgentState
        let waiting = snapshot.waitingSessionCount

        if shownState != .some(state) || shownWaitingCount != waiting {
            shownState = .some(state)
            shownWaitingCount = waiting
            showFrames(for: state)
            // Only above one. The common case is a single waiting session, and
            // a permanent "1" is noise; status items have no native badge, so
            // this is a title beside the glyph.
            button.title = waiting > 1 ? " \(waiting)" : ""
            button.imagePosition = waiting > 1 ? .imageLeading : .imageOnly
            button.font = .monospacedDigitSystemFont(
                ofSize: NSFont.smallSystemFontSize, weight: .medium)
        }

        // Checked separately: the sentence names a project, so it moves when the
        // glyph does not.
        let description = StatusItemLabel.describe(snapshot)
        guard shownDescription != description else { return }
        shownDescription = description
        button.setAccessibilityLabel(description)
        button.toolTip = description
    }

    private func configureButton() {
        guard let button = statusItem.button else {
            // Documented as optional; in practice non-nil for an item created
            // from `NSStatusBar.system`. Failing to launch over it would be
            // worse than an unlabelled item.
            return
        }
        frames = [StatusItemGlyph.image(for: nil)]
        button.image = frames[0]
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(
            String(
                localized: "AgentBar: nothing running",
                comment: "Menu-bar accessibility label before the first reading"))
        button.target = self
        button.action = #selector(activate)
        // Both buttons, so a right-click reaches the same panel rather than
        // doing nothing at all.
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
    }

    // MARK: - Animation

    /// Whether a state should be animated **right now**, which is not the same
    /// question as whether it has a cycle: Reduce Motion turns every cycle in
    /// the app off, and this is the one place the status item asks.
    ///
    /// A pure decision so it can be tested — `StatusItemController` itself needs
    /// a real status bar, and no test builds one.
    static func animates(_ state: SessionStateKind?, reduceMotion: Bool) -> Bool {
        guard let state, !reduceMotion else { return false }
        return GlyphFigure.animates(state)
    }

    /// Swaps in a state's frames and starts or stops the timer accordingly.
    private func showFrames(for state: SessionStateKind?) {
        frames =
            state.map { StatusItemGlyph.frames(for: $0) } ?? [
                StatusItemGlyph.image(for: nil)
            ]
        frameIndex = 0
        // The resting frame goes up immediately rather than on the first tick,
        // so a state change is visible at once even at 8 fps.
        statusItem.button?.image = frames[0]
        refreshAnimation()
    }

    /// Starts the timer, or invalidates it, from what is true now.
    private func refreshAnimation() {
        guard Self.animates(shownState.flatMap { $0 }, reduceMotion: accessibility.reduceMotion),
            frames.count > 1
        else {
            stopAnimating()
            // Back to the resting frame: a stopped cycle must not leave the
            // glyph frozen mid-pulse, which reads as a rendering fault.
            if let first = frames.first { statusItem.button?.image = first }
            return
        }
        guard animation == nil else { return }
        // `.common`, like the panel's clock: the menu bar's own tracking loop
        // must not stop the glyph while the user drags across another item.
        let timer = Timer(
            timeInterval: StatusItemGlyph.frameInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animation = timer
    }

    private func stopAnimating() {
        animation?.invalidate()
        animation = nil
    }

    private func advance() {
        guard frames.count > 1 else { return }
        frameIndex = (frameIndex + 1) % frames.count
        statusItem.button?.image = frames[frameIndex]
    }

    /// Re-arms itself on every change, which is how `@Observable` is read from
    /// outside a SwiftUI view.
    ///
    /// `AccessibilityPreferences` is already the app's one observer of the
    /// system's accessibility settings, and the handoff's rule is to extend it
    /// rather than add a second mechanism. Registering for the workspace
    /// notification again here would be that second mechanism.
    private func observeReduceMotion() {
        withObservationTracking {
            _ = accessibility.reduceMotion
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeReduceMotion()
                self.refreshAnimation()
            }
        }
    }

    /// A click never asks for keyboard focus. That is the rule the product
    /// cannot break: a panel that took key status on a mouse click would pull
    /// the user out of the editor they were reading.
    @objc private func activate() {
        guard let button = statusItem.button else { return }
        onActivate(button, false)
    }
}
