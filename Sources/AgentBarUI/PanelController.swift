import AppKit
import SwiftUI

/// The window the panel lives in.
///
/// **Not an `NSPopover`.** The two requirements — never steal focus, and be
/// fully keyboard-navigable — are in direct tension, and the resolution is to
/// let the input method that opened the panel decide. A popover cannot express
/// that: it has no way to take key status on one path and refuse it on another.
/// An `NSPanel` with `.nonactivatingPanel` can, which is the whole reason that
/// style mask exists.
///
/// | Opened by | Key status |
/// |---|---|
/// | Clicking the status item | not key — focus stays in the editor, which is the whole point |
/// | A keyboard shortcut | key — reaching for the keyboard *is* the request for keyboard focus |
///
/// The shortcut itself is deliberately not chosen here: nothing in the
/// repository registers a global hotkey and the settings screen that should
/// configure one is deferred. What this class owes is the *capability*, with
/// the trigger left as a seam — the `takingKeyFocus` argument.
@MainActor
public final class PanelController: NSObject, NSWindowDelegate {
    private let panel: AgentBarPanel
    /// Typed as `NSView` because the hosting view is generic over its content
    /// and this controller is not.
    private let hosting: NSView
    private var dismissMonitor: Any?
    private let onDismiss: () -> Void
    /// The status item the panel is hanging under, so a click *on it* can be
    /// told apart from a click away. Weak: the controller does not own the
    /// menu-bar presence and must not keep it alive past `stop()`.
    private weak var anchor: NSStatusBarButton?
    /// The content's fixed width.
    ///
    /// A parameter rather than the token, because the first-run flow is
    /// presented through this same controller at 420 pt — wider than the panel,
    /// because its steps carry more copy and it is transient. Everything else
    /// about the presentation is deliberately identical: the anchor, the tail,
    /// the material, the dismissal and the focus policy are the whole reason the
    /// onboarding does not get a window class of its own.
    private let width: CGFloat

    public init<Content: View>(
        content: Content,
        width: CGFloat = DesignTokens.panelWidth,
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        self.width = width
        hosting = FirstMouseHostingView(rootView: content)
        panel = AgentBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
            // `.nonactivatingPanel` is what lets the panel take keyboard input
            // without activating AgentBar and pulling the user out of their
            // editor. `.borderless` because the panel draws its own 18 pt
            // rounded container and wants no title bar above it.
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        // Clicking a row must not make the panel key. Only a control that
        // genuinely needs typing may pull focus.
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        // `NSApp.hide` must not take this panel away. AgentBar hides itself when
        // the settings window closes — that is what returns an accessory app to
        // its accessory life — and a menu-bar panel disappearing as a side
        // effect of an unrelated window closing is not something the user asked
        // for. The open clock no longer trusts this either; see
        // `MenuBarController.tick(isVisible:openFor:)`.
        panel.canHide = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The panel draws its own shadow token only if the window has none —
        // two stacked shadows is the mistake the design system warns about.
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        // Visible over full-screen apps and on every Space: a menu-bar panel
        // that vanishes when the user switches Space is one that does not work.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.onCancel = { [weak self] in
            guard let self else { return }
            self.hide()
            self.onDismiss()
        }
        panel.contentView = hosting
    }

    public var isVisible: Bool { panel.isVisible }

    /// Shows the panel under `anchor`'s screen rectangle.
    ///
    /// `takingKeyFocus` is the whole of the focus decision. `false` — a mouse
    /// click — orders the panel front without ever calling `NSApp.activate`, so
    /// the editor keeps its keyboard focus and its window keeps its title-bar
    /// highlight.
    public func show(from anchor: NSStatusBarButton, takingKeyFocus: Bool) {
        self.anchor = anchor
        position(under: anchor)
        if takingKeyFocus {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        startWatchingForDismissal()
    }

    public func hide() {
        stopWatchingForDismissal()
        panel.orderOut(nil)
    }

    /// > **The monitor is removed in `hide()` and nowhere else, deliberately.**
    /// > A dropped controller that was still visible would leave a global
    /// > monitor installed for the life of the process, and the structural
    /// > answer to that is a `deinit` — which this type cannot have. `deinit` is
    /// > nonisolated, the monitor token is not `Sendable`, and a nonisolated
    /// > `deinit` may not touch main-actor state. `SettingsWindowController`
    /// > answers the identical problem the identical way, in `windowWillClose`.
    /// > `MenuBarController.stop()` therefore hides before it releases, and that
    /// > call order is the invariant.

    /// Re-measures and re-anchors, and does nothing when the panel is closed.
    ///
    /// Two reasons to call it. The menu bar can move to another screen while the
    /// panel is open, and a panel left at the old coordinates is a panel on the
    /// wrong monitor. And the panel is a **live list**: rows appear and leave
    /// while it is open, so its height is not fixed at the moment it was shown.
    /// A borderless window does not resize itself to its content, so whoever
    /// owns the open-panel clock calls this.
    public func reposition(under anchor: NSStatusBarButton) {
        guard panel.isVisible else { return }
        // Re-recorded, not only re-measured: the dismissal guard tests against
        // this rectangle, and an anchor that moved without being remembered
        // would exempt the place the status item used to be.
        self.anchor = anchor
        position(under: anchor)
    }

    /// Centred under the status item, clamped to the screen so an item near a
    /// corner does not push the panel off the edge.
    private func position(under anchor: NSStatusBarButton) {
        guard let anchorWindow = anchor.window else { return }
        let anchorFrame = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        hosting.layoutSubtreeIfNeeded()
        let size = NSSize(
            width: width,
            height: max(hosting.fittingSize.height, 1))
        let visible = (anchorWindow.screen ?? NSScreen.main)?.visibleFrame ?? anchorFrame

        var origin = NSPoint(
            x: anchorFrame.midX - size.width / 2,
            y: anchorFrame.minY - size.height - 6)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = max(origin.y, visible.minY + 8)

        // Nothing moved, so nothing is set. The open panel's clock calls this
        // once a second and the push leg calls it again on every batch of state
        // moves, and the overwhelming majority of those find the panel exactly
        // where it already is. `setFrame(display: true)` is not free — it drives
        // a display cycle — and `invalidateShadow` makes the window server
        // recompute the shadow of a transparent borderless window. Paying for
        // both once a second for a frame that did not change is a menu-bar app
        // costing the user a measurable slice of a core while it sits there.
        let target = NSRect(origin: origin, size: size)
        guard panel.frame != target else { return }
        panel.setFrame(target, display: true)
        // A borderless transparent window keeps the shadow it was drawn with,
        // so a panel that grew a row would wear the outline of the shorter one.
        panel.invalidateShadow()
    }

    // MARK: - Transient dismissal

    /// A click anywhere outside closes the panel, which is what makes it behave
    /// like a menu without being one.
    ///
    /// A *global* monitor, which needs no Accessibility permission for mouse
    /// events — unlike a key-event monitor, which does. That asymmetry is why
    /// the keyboard path is left to the panel's own responder chain instead.
    ///
    /// > **Except a click on the status item itself.** The menu bar is not this
    /// > app's window in the sense the monitor cares about, so a click on the
    /// > status item arrives here as well as at the button's own action — and
    /// > it arrives *first*, on mouse-down. Without this guard the sequence for
    /// > a second click is: the monitor closes the panel, the action then finds
    /// > it closed and opens it again. The panel never closes, which is exactly
    /// > what the second click was for. The button's action owns that decision;
    /// > this monitor's job is clicks that land somewhere else entirely.
    private func startWatchingForDismissal() {
        guard dismissMonitor == nil else { return }
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                // The event's own location, not `NSEvent.mouseLocation`. A
                // global monitor's event has no window, and AppKit documents
                // that as meaning `locationInWindow` is already in screen
                // coordinates. Asking where the pointer is *now* would answer a
                // different question under delivery latency, and answering it
                // wrongly in one direction reproduces the defect this guard
                // exists to close.
                guard
                    PanelDismissal.dismisses(
                        event.type, at: event.locationInWindow,
                        statusItem: self.anchorScreenFrame)
                else { return }
                self.hide()
                self.onDismiss()
            }
        }
    }

    /// Where the status item is on screen right now, or `nil` when there is
    /// nothing to ask — a menu bar that has gone away is not a reason to stop
    /// dismissing.
    private var anchorScreenFrame: NSRect? {
        guard let anchor, let window = anchor.window else { return nil }
        return window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    }

    private func stopWatchingForDismissal() {
        guard let dismissMonitor else { return }
        NSEvent.removeMonitor(dismissMonitor)
        self.dismissMonitor = nil
    }

    /// Losing key status closes the panel — the keyboard path's equivalent of
    /// clicking away. It cannot fire on the mouse path, which never takes key.
    ///
    /// > **Except when the pointer is on the status item.** A panel opened from
    /// > a notification *is* key, and clicking the status item to close it can
    /// > take key status away first — which would hide the panel here and let
    /// > the button's action find it closed and open it again, the mouse path's
    /// > defect reached by the other road. The same rule applies: a click on the
    /// > status item belongs to the status item.
    /// >
    /// > The trade is deliberate. This reads where the pointer *is*, because a
    /// > resignation carries no event, so a `⌘-Tab` performed with the pointer
    /// > parked over the status item leaves the panel open. That costs one extra
    /// > click to close and cannot strand it — every other dismissal path still
    /// > applies — while the alternative costs the close button its meaning.
    public func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
        // Not `dismisses(_:at:statusItem:)`: a resignation carries no event and
        // so no button, and feeding it a fabricated one would tie this decision
        // to which buttons the status item happens to handle. The shared half is
        // the only half that applies.
        guard
            !PanelDismissal.exemptsStatusItem(
                at: NSEvent.mouseLocation, statusItem: anchorScreenFrame)
        else { return }
        hide()
        onDismiss()
    }
}

/// Whether a click outside the panel should close it.
///
/// A free function over a point, a rectangle and a mouse button, so the one rule
/// that was wrong can be tested without a menu bar, a window server or a click.
enum PanelDismissal {
    /// The buttons the status item sends its action on, and therefore the only
    /// ones whose meaning it owns. `StatusItemController` asks AppKit for
    /// exactly these two.
    static let buttonsTheStatusItemOwns: NSEvent.EventTypeMask = [
        .leftMouseDown, .rightMouseDown,
    ]

    /// `false` only for a click the status item is going to act on itself.
    ///
    /// Two conditions, and both are needed. The click has to land on the status
    /// item — anywhere else is a click away and closes the panel. And it has to
    /// be a button the status item actually handles: a middle-click on it is
    /// nobody's, and exempting one would leave a panel that neither handler
    /// closes.
    static func dismisses(
        _ type: NSEvent.EventType, at point: NSPoint, statusItem: NSRect?
    )
        -> Bool
    {
        guard buttonsTheStatusItemOwns.contains(NSEvent.EventTypeMask(type: type)) else {
            return true
        }
        return !exemptsStatusItem(at: point, statusItem: statusItem)
    }

    /// Whether a point is somewhere the status item will answer for.
    ///
    /// The half of the rule both callers share. No anchor is no reason to stop
    /// dismissing: a panel that cannot be closed by clicking away is worse than
    /// one closed a click too eagerly, so an absent rectangle exempts nothing.
    static func exemptsStatusItem(at point: NSPoint, statusItem: NSRect?) -> Bool {
        guard let statusItem else { return false }
        return statusItem.contains(point)
    }
}

/// Accepts the first click.
///
/// The panel is deliberately not key on the mouse path, and AgentBar is an
/// accessory app that never activates — so by default the first click into the
/// panel is spent making the window key and the control under the pointer never
/// fires. A user would have to click everything twice, which reads as "the app
/// is broken" rather than as a focus policy.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
    }

    /// The panel is built in code and never loaded from a nib. `NSView` demands
    /// the initialiser exist; marking it unavailable is how a class says it
    /// genuinely cannot be constructed that way, rather than trapping at
    /// runtime.
    @available(*, unavailable)
    @MainActor dynamic required init?(coder: NSCoder) {
        fatalError("PanelController's hosting view is not loadable from a coder")
    }
}

/// The panel window itself.
///
/// Two overrides, both load-bearing. A `.borderless` window returns `false` from
/// `canBecomeKey`, which would make the keyboard path impossible however it was
/// opened. And Escape has to close the panel and hand focus back wherever it
/// came from, which is `cancelOperation`.
final class AgentBarPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    /// Never. Taking main window status is what would pull the user out of
    /// their editor even without activating the app.
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
