import AppKit
import SwiftUI

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
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            Task { await model.refresh() }
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView(model: model)
                .environment(\.accessibilityPreferences, AccessibilityPreferences.shared))
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "AgentBar Settings", comment: "Settings window title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 620, height: 620))
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        startWatchingForActivation()
    }

    public func close() {
        window?.close()
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
