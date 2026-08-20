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

    /// How long an open panel goes on asking for fresh subscription limits.
    ///
    /// > **The panel does not close by itself, and this is what stands in for
    /// > that.** `hidesOnDeactivate` is false and the panel is never key on the
    /// > mouse path, so switching apps, changing Space or walking away all leave
    /// > it on screen — verified against the running app. Only a click closes
    /// > it. Without a bound, "ask while the user is watching" would be a child
    /// > process a minute for as long as a forgotten panel stays up, which is a
    /// > poll wearing a justification it no longer has
    /// > ([tos-boundary.md](tos-boundary.md)).
    /// >
    /// > Five minutes is generous for watching a bar move and short enough that
    /// > a panel nobody is looking at costs nothing beyond it. Past the window
    /// > the panel keeps *showing* whatever the background interval brings in;
    /// > it only stops asking.
    static let watchingWindow: Duration = .seconds(5 * 60)

    /// What the open-panel clock should do on this tick.
    enum Tick: Sendable, Hashable {
        /// The panel is not on screen. Whatever the timer believes, the open
        /// clock has no business running.
        case retire
        /// Open and inside the watching window: show the last reading, ask for
        /// the next.
        case watch
        /// Open and past it: show, ask for nothing.
        case show
    }

    /// The whole of the open clock's decision, as a function of what is true
    /// rather than of what the controller remembers.
    ///
    /// > **`isVisible` is asked, not assumed.** The timer's mode and `openedAt`
    /// > are controller state, and every *deliberate* dismissal clears them —
    /// > but AppKit can take a panel off screen without going through any of
    /// > them, `NSApp.hide` being the one this project reaches for when the
    /// > settings window closes. State that only tracks the paths we wrote is
    /// > state that silently stops being true, and here it would keep the
    /// > watching leg spawning a child a minute with nothing on screen: exactly
    /// > the pattern the five-minute window exists to prevent, reached around it.
    ///
    /// A pure decision on the type so it can be tested — `MenuBarController`
    /// itself needs a real status bar, and no test builds one.
    static func tick(isVisible: Bool, openFor elapsed: Duration?) -> Tick {
        guard isVisible, let elapsed else { return .retire }
        // A negative elapsed cannot come from `ContinuousClock`, but the guard
        // is free and a clock that ran backwards would otherwise watch for ever.
        guard elapsed >= .zero, elapsed < watchingWindow else { return .show }
        return .watch
    }

    private let model: PanelModel
    private let settingsWindow: SettingsWindowController
    private var statusItem: StatusItemController?
    private var panel: PanelController?
    private var timer: Timer?
    private var pushPending = false
    private var screenObserver: NSObjectProtocol?
    /// The open in flight, between deciding to open and the panel appearing.
    ///
    /// `toggle` reads `panel.isVisible` synchronously and shows one actor hop
    /// later, so without this a second click inside that window sees a panel
    /// that is not visible *yet*, starts its own open, and the click that was
    /// meant to close leaves it open — the defect this file just fixed, reached
    /// by a different road.
    ///
    /// Held as the `Task` rather than as a flag, because a flag has no way out.
    /// This app is `LSUIElement` and **Quit lives only in the panel's footer**,
    /// so a click silently dropped for ever is an app that cannot be opened *or*
    /// closed except through Activity Monitor. A second click cancels the open
    /// instead of being swallowed, and a third starts a fresh one.
    private var openTask: Task<Void, Never>?
    /// When the panel went on screen, on a monotonic clock.
    ///
    /// `ContinuousClock`, never `Date`: `TimeSource` states the rule this
    /// project follows — a wall clock moves when NTP corrects it or the user
    /// changes the date, and an interval measured across that correction is
    /// wrong in the direction that matters here, leaving the watching window
    /// open indefinitely.
    private var openedAt: ContinuousClock.Instant?

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
            onDismiss: { [weak self] in
                self?.openedAt = nil
                self?.scheduleTimer(open: false)
            })

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
        // Before anything else: an open in flight would otherwise resume after
        // teardown, show a panel this method has already released, and re-arm
        // the timer it just invalidated.
        openTask?.cancel()
        openTask = nil
        openedAt = nil
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
    /// No **hotkey** calls it: registering a system-wide key combination on the
    /// user's behalf is not a decision to bury in a design document, and the
    /// settings screen that should configure one is deferred. What exists is the
    /// capability, so a hotkey lands as a call site rather than as a redesign.
    /// `revealPanel()` below already uses it for a clicked notification.
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
        if let openTask {
            // An open is already in flight. Abandon it rather than queue a
            // second one, and rather than drop the click on the floor.
            openTask.cancel()
            self.openTask = nil
            return
        }
        if panel.isVisible {
            panel.hide()
            openedAt = nil
            scheduleTimer(open: false)
            return
        }
        // The card is opened by pressing the footer status, never by opening the
        // panel: a user with sessions running does not need to be told to
        // install anything.
        model.showsIntegrationCard = false
        openTask = Task {
            // Read *before* showing. The panel's height comes from the list, so
            // a first frame drawn from a stale snapshot would resize under the
            // pointer — and this costs one actor hop. Only this one: the limits
            // request that used to sit here waits on `QuotaService`, whose actor
            // does synchronous filesystem work looking for `codex`, and nothing
            // that can stall belongs between a click and the panel appearing.
            await model.refreshSnapshot()
            guard !Task.isCancelled else {
                self.openTask = nil
                return
            }
            panel.show(from: button, takingKeyFocus: takingKeyFocus)
            openedAt = ContinuousClock().now
            openTask = nil
            scheduleTimer(open: true)
            statusItem?.update(from: model.snapshot)
            // Now that the panel is up: the reading takes a second or two to
            // land, and asking at the moment of opening is what makes it arrive
            // while the panel is still on screen rather than after it closes.
            await model.watchUsage()
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
            switch Self.tick(
                isVisible: panel?.isVisible == true,
                openFor: openedAt.map { ContinuousClock().now - $0 })
            {
            case .retire:
                // The panel went away without telling us. Put the clock back
                // where it belongs and stop asking for anything.
                openedAt = nil
                scheduleTimer(open: false)
                await model.sweepAndRefresh()
                statusItem?.update(from: model.snapshot)
                return
            case .watch, .show:
                break
            }
            await model.refreshSnapshot()
            // Cheap enough for this clock — an actor hop, no disk — and the only
            // thing that shows a limits refresh landing while the panel is open.
            // Inside the watching window it also *asks* for the next reading;
            // past it the panel goes back to only showing what arrives, because
            // a panel left open is not the same thing as somebody watching it.
            if Self.tick(
                isVisible: true, openFor: openedAt.map { ContinuousClock().now - $0 }) == .watch
            {
                await model.watchUsage()
            } else {
                await model.refreshUsage()
            }
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
        openedAt = nil
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
