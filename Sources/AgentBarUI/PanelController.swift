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

    public init<Content: View>(content: Content, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        hosting = FirstMouseHostingView(rootView: content)
        panel = AgentBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: DesignTokens.panelWidth, height: 120),
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

    /// Returns whether the panel is now open, so the caller can retime its
    /// polling without asking a second question.
    @discardableResult
    public func toggle(from anchor: NSStatusBarButton, takingKeyFocus: Bool) -> Bool {
        if panel.isVisible {
            hide()
            onDismiss()
            return false
        }
        show(from: anchor, takingKeyFocus: takingKeyFocus)
        return true
    }

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
        position(under: anchor)
    }

    /// Centred under the status item, clamped to the screen so an item near a
    /// corner does not push the panel off the edge.
    private func position(under anchor: NSStatusBarButton) {
        guard let anchorWindow = anchor.window else { return }
        let anchorFrame = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        hosting.layoutSubtreeIfNeeded()
        let size = NSSize(
            width: DesignTokens.panelWidth,
            height: max(hosting.fittingSize.height, 1))
        let visible = (anchorWindow.screen ?? NSScreen.main)?.visibleFrame ?? anchorFrame

        var origin = NSPoint(
            x: anchorFrame.midX - size.width / 2,
            y: anchorFrame.minY - size.height - 6)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = max(origin.y, visible.minY + 8)

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
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
    private func startWatchingForDismissal() {
        guard dismissMonitor == nil else { return }
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                self.hide()
                self.onDismiss()
            }
        }
    }

    private func stopWatchingForDismissal() {
        guard let dismissMonitor else { return }
        NSEvent.removeMonitor(dismissMonitor)
        self.dismissMonitor = nil
    }

    /// Losing key status closes the panel — the keyboard path's equivalent of
    /// clicking away. It cannot fire on the mouse path, which never takes key.
    public func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
        hide()
        onDismiss()
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
