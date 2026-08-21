import AgentBarCore
import AppKit
import SwiftUI

/// How big the settings window opens, and the two rules it may not break.
///
/// > **The defect this exists to close.** The window opened at 620 pt wide and
/// > the form inside it could not be drawn narrower than 710 — the matrix's
/// > three fixed-width columns plus the grouped form's own insets. SwiftUI does
/// > not refuse that: it lays the form out at 710 anyway, centred, and the
/// > 45 pt hanging off each side is **clipped with no horizontal scroller**.
/// > What the user saw was a settings window with the verb labels cut off the
/// > left edge. Measured: the scroll view's clip view was 710 pt wide inside a
/// > 620 pt window.
/// >
/// > So the width is not a taste decision. It is derived from what the matrix
/// > actually needs — see `NotificationMatrixView.minimumWidth(providers:)` —
/// > and the matrix compresses instead of clipping, so the two meet.
/// >
/// > The second rule is the screen. Nothing forced this window off the display
/// > before, but nothing stopped it either: every size here is chosen against
/// > `NSScreen.visibleFrame`, so a form that grows a section in a later step
/// > cannot repeat the first defect in the other direction.
enum SettingsWindowLayout {
    /// What a grouped `Form` puts around its content — the scroll view's own
    /// margins plus the section insets — as an **allowance**, not a constant of
    /// nature. Measured at the form's natural size: 744 pt of width around a
    /// 650 pt matrix. Squeezed to its minimum the form gives up most of that, so
    /// this errs high on purpose; `SettingsWindowSizingTests` asserts against
    /// the real number rather than this one.
    static let formChromeWidth: CGFloat = 94

    /// Wide enough for the matrix at every provider, with room in the columns
    /// rather than at their floor.
    ///
    /// `design-spec.md` said 620 × 620, and it was right when it was written:
    /// the matrix had one column. Step 09 added the second and nothing
    /// re-measured the window it had to fit in.
    static let ideal = NSSize(
        width: max(720 + DesignTokens.SettingsSidebar.width, minimum.width), height: 640)

    /// The smallest the user may drag it to: the width at which the matrix is
    /// at its floor and still whole, so no resize can clip it.
    ///
    /// Counted from `Provider.allCases` rather than from the providers the app
    /// registered. The window is sized once, before the matrix is built, and a
    /// provider added to the domain without a number changed here would clip
    /// the column it brings — the mistake this whole type exists to close, one
    /// provider later.
    ///
    /// > **The sidebar is added, not absorbed.** It is a fixed-width column
    /// > beside the form rather than above it, so every point it takes is a
    /// > point the matrix does not get. Deriving the minimum from the matrix
    /// > alone once the sidebar existed would recreate the original defect
    /// > exactly — a window narrower than the form inside it, resolved by
    /// > clipping the verb labels with no scroller and no diagnostic.
    static let minimum = NSSize(
        width: NotificationMatrixView.minimumWidth(providers: Provider.allCases.count)
            + formChromeWidth + DesignTokens.SettingsSidebar.width,
        height: 420)

    static func contentSize(fitting available: NSSize) -> NSSize {
        NSSize(
            width: fit(ideal.width, available.width),
            height: fit(ideal.height, available.height))
    }

    static func minimumContentSize(fitting available: NSSize) -> NSSize {
        NSSize(
            width: fit(minimum.width, available.width),
            height: fit(minimum.height, available.height))
    }

    /// A non-positive dimension means "nothing said" — a window with no screen,
    /// which happens under `swift test` — and is not a reason to open a window
    /// of zero size.
    private static func fit(_ wanted: CGFloat, _ available: CGFloat) -> CGFloat {
        available > 0 ? min(wanted, available) : wanted
    }

    /// The window's content size **as `setContentSize` would set it**.
    ///
    /// A named function rather than an expression at the one call site, because
    /// the obvious alternative is wrong in a way nothing else would catch.
    /// `contentLayoutRect` is the part of the content *not obscured by the title
    /// bar*; since v2 the title bar is transparent and the content runs
    /// underneath it, so that is 32 pt less than what `setContentSize` sets.
    /// Comparing one against the other reports the window as shorter than it is
    /// and shrinks it by a title bar on **every showing** — a window that loses
    /// an inch a visit and no failing test anywhere. This is the exact inverse
    /// of `setContentSize`, so the two cannot disagree, and
    /// `SettingsWindowChromeTests` holds it.
    @MainActor
    static func currentContentSize(of window: NSWindow) -> NSSize {
        window.contentRect(forFrameRect: window.frame).size
    }

    /// How much room a window has for *content* on a given screen: the visible
    /// frame less the chrome the window itself adds around it.
    ///
    /// Separated from `fitToScreen` so the arithmetic can be tested against
    /// screens this machine has not got — the undocked laptop, the vertical
    /// display, the screen with no room at all.
    static func available(visibleFrame: NSSize, chrome: NSSize) -> NSSize {
        NSSize(
            width: max(0, visibleFrame.width - chrome.width),
            height: max(0, visibleFrame.height - chrome.height))
    }

    /// The size an already-open window should be resized to, or `nil` to leave
    /// it exactly as the user left it.
    ///
    /// The ceiling here is **the screen, not `ideal`**. A user who dragged the
    /// window wider than it opens at wants it wider than it opens at, and
    /// clamping to `ideal` on every showing would undo that silently, once per
    /// visit, for ever. The only size worth overruling is one the display
    /// cannot hold.
    static func shrink(_ current: NSSize, toFit available: NSSize) -> NSSize? {
        let fitted = NSSize(
            width: fit(current.width, available.width),
            height: fit(current.height, available.height))
        return fitted == current ? nil : fitted
    }

    /// The hosting controller the settings window is built around.
    ///
    /// A factory so that `sizingOptions` has exactly one home. Inline, the line
    /// below sits four lines from `contentMinSize` being set in `fitToScreen`
    /// and the two would drift; here they are visibly two halves of one
    /// decision about who owns the window's size limits.
    @MainActor
    static func hostingController(model: SettingsModel) -> NSHostingController<some View> {
        let hosting = NSHostingController(
            rootView: SettingsView(model: model)
                .environment(\.accessibilityPreferences, AccessibilityPreferences.shared))
        // The window's size limits are this file's to set, not SwiftUI's.
        // `NSHostingController` defaults to publishing the view's minimum,
        // intrinsic and maximum sizes onto the window, and the minimum it
        // publishes has never heard of the screen — on a display narrower than
        // the form's own minimum that is a window the user cannot make fit.
        // `contentMinSize` is set in `fitToScreen` instead, from the same
        // number the view's own `minWidth` comes from.
        hosting.sizingOptions = []
        return hosting
    }
}

/// The window the settings screen lives in.
///
/// An ordinary titled `NSWindow`, unlike the panel next door — and the contrast
/// is the point. The panel must never steal focus, because it appears beside
/// whatever the user was doing. A settings window is asked for, by name, with a
/// click; refusing it focus would leave a window the user cannot type in.
///
/// It does mean an accessory app briefly becomes an ordinary one:
/// `NSApp.activate` is what puts the window in front of the editor the user
/// pressed the gear from. That is a deliberate exception to *never activate*,
/// scoped to the one surface where activation is the request.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: SettingsModel
    /// Removed in `windowWillClose` rather than in a `deinit`: the token is not
    /// `Sendable` and a nonisolated `deinit` cannot touch it.
    private var activationObserver: NSObjectProtocol?

    public init(model: SettingsModel) {
        self.model = model
        super.init()
    }

    /// Shows the window, building it on first use.
    ///
    /// A second press focuses the window that already exists rather than opening
    /// another: `LSUIElement` means there is no Window menu to find a lost one
    /// in.
    public func show() {
        if let window {
            // Re-measured on every showing, not only on the first: the window
            // outlives the display it was sized against, and a Mac undocked
            // from an external monitor would otherwise reopen a window larger
            // than the screen it is now on.
            fitToScreen(window, resetToIdeal: false)
            // Re-armed, not assumed: `windowWillClose` tears the observer down,
            // so every showing after the first would otherwise run without it —
            // and the recovery flow the observer exists for (leave for System
            // Settings, grant, come back) is one a user reaches by opening this
            // window a second time. Idempotent, so the first showing is
            // unaffected.
            startWatchingForActivation()
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            Task { await model.refresh() }
            return
        }

        let window = NSWindow(
            contentViewController: SettingsWindowLayout.hostingController(model: model))
        // Kept even though it is not drawn: the title is what VoiceOver and the
        // window list announce, and hiding a window's name from the system is a
        // different decision from hiding its title bar.
        window.title = String(localized: "AgentBar Settings", comment: "Settings window title")
        // The traffic lights sit directly on the sidebar's glass, the way every
        // native macOS window with a sidebar has since Big Sur. That needs three
        // things together — the content view runs the full height of the frame,
        // the title bar draws nothing of its own, and the title itself is not
        // painted over the sidebar. `SettingsSidebar` reserves the room at its
        // top; nothing else in the window may be placed under the buttons.
        window.styleMask = [
            .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
        ]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self
        fitToScreen(window, resetToIdeal: true)
        self.window = window

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        startWatchingForActivation()
    }

    public func close() {
        window?.close()
    }

    /// The window, for the render proof and nothing else.
    ///
    /// This window owns its own chrome now — a transparent title bar with the
    /// buttons sitting on the sidebar's glass — and that is a fact no snapshot
    /// of the SwiftUI view can show. Getting at it needs the `NSWindow` itself.
    var renderedWindow: NSWindow? { window }

    /// Sizes the window against the screen it will appear on.
    ///
    /// `resetToIdeal` separates the two callers: opening for the first time
    /// takes the ideal size, while re-showing an existing window keeps whatever
    /// the user resized it to and only shrinks it when it no longer fits.
    private func fitToScreen(_ window: NSWindow, resetToIdeal: Bool) {
        let screen = window.screen ?? NSScreen.main
        // What the window adds around its content. Measured rather than
        // assumed, because it is a system metric — and since v2 the honest
        // answer is **nothing**: a `fullSizeContentView` window's frame *is* its
        // content rect, so this is zero and the title bar is deliberately not
        // subtracted. It is still asked rather than hardcoded, so a style-mask
        // change is accounted for instead of silently ignored.
        let available = SettingsWindowLayout.available(
            visibleFrame: screen?.visibleFrame.size ?? .zero,
            chrome: window.frameRect(forContentRect: .zero).size)

        window.contentMinSize = SettingsWindowLayout.minimumContentSize(fitting: available)
        if resetToIdeal {
            window.setContentSize(SettingsWindowLayout.contentSize(fitting: available))
            window.center()
            return
        }
        guard
            let smaller = SettingsWindowLayout.shrink(
                SettingsWindowLayout.currentContentSize(of: window), toFit: available)
        else { return }
        window.setContentSize(smaller)
        window.center()
    }

    /// Re-reads the settings whenever AgentBar becomes active again.
    ///
    /// The load-bearing case is the documented recovery from a refusal: the
    /// window says notifications are turned off, the user presses **Open System
    /// Settings**, turns AgentBar on, and comes back. Without this the window
    /// would still show the problem it just fixed, the Test button would still
    /// be disabled, and every real notification would still be suppressed until
    /// the app was relaunched — because nothing else re-reads the authorisation
    /// while the process lives. Login items can be revoked the same way.
    private func startWatchingForActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                Task { await self.model.refresh() }
            }
        }
    }

    /// Returns the app to its accessory life once the window is gone.
    ///
    /// Without this, closing the settings window would leave AgentBar as the
    /// active application with nothing on screen — a menu bar with no windows
    /// and every keystroke going nowhere.
    public func windowWillClose(_ notification: Notification) {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        NSApp.hide(nil)
    }
}
