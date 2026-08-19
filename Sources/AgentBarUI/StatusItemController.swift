import AgentBarCore
import AppKit

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

    /// `onActivate` receives the button to anchor against and whether the click
    /// asked for keyboard focus.
    public init(onActivate: @escaping (NSStatusBarButton, Bool) -> Void) {
        self.onActivate = onActivate
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
    }

    /// The anchor a panel positions itself against.
    public var button: NSStatusBarButton? { statusItem.button }

    /// Removes the item from the menu bar. Present so teardown is explicit
    /// rather than a side effect of deallocation.
    public func remove() {
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
            button.image = StatusItemGlyph.image(for: state)
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
        button.image = StatusItemGlyph.image(for: nil)
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

    /// A click never asks for keyboard focus. That is the rule the product
    /// cannot break: a panel that took key status on a mouse click would pull
    /// the user out of the editor they were reading.
    @objc private func activate() {
        guard let button = statusItem.button else { return }
        onActivate(button, false)
    }
}
