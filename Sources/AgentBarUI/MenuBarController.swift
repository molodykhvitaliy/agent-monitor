import AgentBarCore
import AppKit
import SwiftUI

/// Assembles the menu-bar presence: the status item, the panel, and the two
/// clocks that keep them honest.
///
/// **Liveness is driven, and mostly by push.** `StoreSnapshot` is an immutable
/// reading and the store owns no timer, so nothing re-reads it by itself. The
/// three signals, in order of how much they matter:
///
/// | Signal | Carries | Latency |
/// |---|---|---|
/// | Push, from the ingest boundary | every state move an event caused | immediate |
/// | Timer, panel open, 1 s | the durations ticking | 1 s |
/// | Timer, panel closed, 45 s | `sweep()`, then a reading | up to a minute |
///
/// Push is not an optimisation: without it a waiting agent — the one signal the
/// product exists for — would sit unannounced behind the closed-panel poll. The
/// timers cover only what time alone changes, and `unknown` is not among them
/// because it is derived on every read.
@MainActor
public final class MenuBarController {
    /// While the panel is open, so its durations tick.
    static let openInterval: TimeInterval = 1
    /// While it is closed. The watchdog's tightest allowance is fifteen
    /// *minutes*, so this is ample once push exists.
    static let closedInterval: TimeInterval = 45
    /// A burst of pushes — a busy turn moves a session several times a second —
    /// collapses into one reading.
    static let pushCoalescingInterval: Duration = .milliseconds(150)

    private let model: PanelModel
    private let settingsWindow: SettingsWindowController
    private var statusItem: StatusItemController?
    private var panel: PanelController?
    private var timer: Timer?
    private var pushPending = false
    private var screenObserver: NSObjectProtocol?

    /// Two seams rather than one: the panel and the settings window need
    /// different things from the assembly, and a single protocol carrying both
    /// would make every panel test declare a sound matrix it does not use.
    public init(services: any PanelServices, settings: any SettingsServices) {
        model = PanelModel(services: services)
        settingsWindow = SettingsWindowController(model: SettingsModel(services: settings))
    }

    public func start() {
        let statusItem = StatusItemController { [weak self] button, takingKeyFocus in
            self?.toggle(from: button, takingKeyFocus: takingKeyFocus)
        }
        self.statusItem = statusItem

        panel = PanelController(
            content: PanelView(
                model: model,
                onSettings: { [weak self] in self?.showSettings() },
                onQuit: { NSApp.terminate(nil) }
            )
            .environment(\.accessibilityPreferences, AccessibilityPreferences.shared),
            onDismiss: { [weak self] in self?.scheduleTimer(open: false) })

        // The menu bar can move to another display while the panel is open.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let button = self.statusItem?.button else { return }
                self.panel?.reposition(under: button)
            }
        }

        scheduleTimer(open: false)
        Task { await refresh(includingIntegrations: true) }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        panel?.hide()
        panel = nil
        settingsWindow.close()
        statusItem?.remove()
        statusItem = nil
    }

    /// Opens the panel as key window — the seam obligation 7 asks for.
    ///
    /// Nothing calls it yet: registering a system-wide key combination on the
    /// user's behalf is not a decision to bury in a design document, and the
    /// settings screen that should configure one is deferred. What exists is the
    /// capability, so a hotkey lands as a call site rather than as a redesign.
    public func openTakingKeyFocus() {
        guard let button = statusItem?.button, panel?.isVisible == false else { return }
        toggle(from: button, takingKeyFocus: true)
    }

    /// The push leg's landing point. Called from the ingest boundary for every
    /// state move an event caused.
    ///
    /// Reads the store rather than trusting the changes themselves: a
    /// `StateChange` describes one session and the status item is about all of
    /// them, so the only correct answer is a fresh reading.
    public func stateDidChange(_ changes: [StateChange]) {
        guard !changes.isEmpty, !pushPending else { return }
        pushPending = true
        Task {
            try? await Task.sleep(for: Self.pushCoalescingInterval)
            pushPending = false
            await refresh(includingIntegrations: false)
            // A pushed change can add or remove a row while the panel is open.
            if let button = statusItem?.button { panel?.reposition(under: button) }
        }
    }

    /// Called after the endpoint binds, which is one of the two moments at
    /// which every install report can have changed.
    public func endpointDidChange() {
        Task { await refresh(includingIntegrations: true) }
    }

    // MARK: - Opening

    private func toggle(from button: NSStatusBarButton, takingKeyFocus: Bool) {
        guard let panel else { return }
        if panel.isVisible {
            panel.hide()
            scheduleTimer(open: false)
            return
        }
        // The card is opened by pressing the footer status, never by opening the
        // panel: a user with sessions running does not need to be told to
        // install anything.
        model.showsIntegrationCard = false
        Task {
            // Read *before* showing. The panel's height comes from the list, so
            // a first frame drawn from a stale snapshot would resize under the
            // pointer — and this costs one actor hop.
            await model.refreshSnapshot()
            panel.show(from: button, takingKeyFocus: takingKeyFocus)
            scheduleTimer(open: true)
            statusItem?.update(from: model.snapshot)
            // Reports touch the disk, so they follow the panel rather than
            // delaying it. They are re-read here and never on a timer: the drift
            // they find only resurfaces if something asks.
            await model.refreshIntegrations()
            panel.reposition(under: button)
        }
    }

    // MARK: - Timers

    private func scheduleTimer(open: Bool) {
        timer?.invalidate()
        let interval = open ? Self.openInterval : Self.closedInterval
        // Constructed and added by hand rather than `scheduledTimer`, which
        // would install it in `.default` as well: the panel's own tracking loop
        // must not stop the clock while the user drags across a row, and
        // `.common` is the mode that survives it.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startTick(open: open) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func startTick(open: Bool) {
        Task { await tick(open: open) }
    }

    private func tick(open: Bool) async {
        if open {
            await model.refreshSnapshot()
            // The panel is a live list in a borderless window, which does not
            // resize itself to its content. A row appearing or leaving changes
            // the height, so the open clock re-measures as well as re-reads.
            if let button = statusItem?.button { panel?.reposition(under: button) }
        } else {
            // Nothing else retires a session whose agent died — and the power
            // assertion in step 08 depends on that happening.
            await model.sweepAndRefresh()
        }
        statusItem?.update(from: model.snapshot)
    }

    private func refresh(includingIntegrations: Bool) async {
        if includingIntegrations { await model.refreshIntegrations() }
        await model.refreshSnapshot()
        statusItem?.update(from: model.snapshot)
    }

    // MARK: - Settings

    /// Opens the settings window, which is what the footer gear was reserved
    /// for. The panel closes first: it is a transient surface and would be
    /// dismissed by the window taking focus anyway, so doing it deliberately
    /// avoids a frame of both being on screen.
    public func showSettings() {
        panel?.hide()
        scheduleTimer(open: false)
        settingsWindow.show()
    }

    /// Opens the panel because the user clicked a notification.
    ///
    /// Taking key focus, and activating: clicking a banner is an explicit
    /// request to look at AgentBar, the same kind of request as pressing the
    /// gear. Without `NSApp.activate` a `.nonactivatingPanel` opened from an
    /// inactive accessory app can fail to become key — and `windowDidResignKey`
    /// would then close it again immediately, which reads as the click having
    /// done nothing.
    public func revealPanel() {
        NSApp.activate()
        openTakingKeyFocus()
    }
}
