import AgentBarCore
import AgentBarIngest
import AgentBarNotifications
import AgentBarPower
import AgentBarUI
import AppKit
import ClaudeCodeAdapter
import CodexAdapter
import CodexAppServer
import os

// The app target is the assembly point: it is the only place that knows every
// module exists. Nothing here belongs in a library — modules stay independently
// testable precisely because wiring lives at the top.
//
// AppKit's lifecycle is used rather than SwiftUI's `App`: the status item needs
// a non-activating panel that can take key status on one path and refuse it on
// another, which `MenuBarExtra` cannot express.

@main
@MainActor
enum AgentBarMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // NSApplication holds its delegate weakly, and ARC is free to release a
        // local after its last use — which would be the assignment above.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(
        subsystem: "com.molodykhvitalii.AgentBar", category: "lifecycle")

    /// Every provider the assembly registers. One list, so the footer's
    /// denominator, the settings matrix's columns and the integrations built
    /// below cannot disagree about what exists.
    private static let providers: [Provider] = [.claudeCode, .codex]

    private let store = SessionStore()
    /// Keeps the Mac awake while an agent works. Built here rather than lazily:
    /// it holds the only power assertion in the process, and one owner is what
    /// makes "released when the process dies" a guarantee rather than a hope.
    private let caffeine = CaffeineController()
    private lazy var caffeineBridge = CaffeineBridge(controller: caffeine)
    /// Codex's limits. Built here for the same reason the caffeine controller
    /// is: it owns the only thing in the process that spawns a child, and one
    /// owner is what makes "no process outlives the app" a guarantee.
    private let quota = QuotaService(clientVersion: AppDelegate.marketingVersion)
    private var menuBar: MenuBarController?
    private var ingest: IngestService?
    private var notifications: NotificationRouter?
    /// Held strongly: `UNUserNotificationCenter` keeps its delegate **weakly**,
    /// and a released one stops receiving responses with nothing to say so.
    private var notificationDelegate: NotificationDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement in Info.plist already selects accessory activation. This
        // repeats it so a build with a mis-merged plist still comes up without a
        // Dock icon rather than as a windowless regular app the user cannot quit.
        NSApp.setActivationPolicy(.accessory)
        // Notifications first: the ingest relay needs the router to fan out to,
        // and the delegate has to be installed here rather than later because
        // the system may relaunch the app to deliver a response.
        startNotifications()
        startIngest()
        startCaffeine()
        startQuota()
    }

    /// Begins reading Codex's limits: once now, then on the interval.
    ///
    /// Once now for the same reason Caffeine takes a reading at launch — the
    /// panel may be opened a second later, and a Limits section that stays empty
    /// for half an hour after every start reads as a broken feature rather than
    /// as a slow one.
    private func startQuota() {
        Task { [quota] in await quota.start() }
    }

    /// Begins holding the Mac awake, with one reading taken immediately.
    ///
    /// Immediately because AgentBar is usually launched while agents are already
    /// running, and a session halfway through a long `Bash` call may not speak
    /// again for half an hour. Waiting for the first hook payload would mean the
    /// Mac sleeping under exactly the build this exists to protect.
    private func startCaffeine() {
        Task { [caffeine, store] in
            await caffeine.start { await store.snapshot() }
        }
    }

    /// Lets the endpoint retract itself before the process goes.
    ///
    /// Asked for rather than blocked on: the discovery file and the Unix socket
    /// outlive the process otherwise, and the next launch — or the Codex helper
    /// in step 09 — would read them and post at a port nobody is holding.
    ///
    /// A deadline replies anyway. `LSUIElement` means there is no window to
    /// close and no Dock icon to quit from, so a Quit that hangs is a Quit the
    /// user can only resolve through Force Quit — a far worse outcome than a
    /// stale discovery file the next launch cleans up.
    ///
    /// **`Deadline`, not a task group.** A group waits for every child before it
    /// returns, so a `stop()` parked inside Network.framework would outlast the
    /// timer that was supposed to bound it and the reply would never be sent.
    /// `Deadline` hands back an answer on its own and abandons the overrun,
    /// which is the difference between a slow quit and a Force Quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let ingest else { return .terminateNow }
        Task {
            _ = await Deadline.run(within: .seconds(2)) { await ingest.stop() }
            self.ingest = nil
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        notifications?.stop()
        // Releases the power assertion. The kernel would release it anyway when
        // this process goes — that is why AgentBar takes one instead of spawning
        // `caffeinate` — but doing it here means the assertion disappears when
        // the app decides to quit rather than when the last reference does.
        caffeine.stop()
        // Best-effort: this is an unstructured task and the process may exit
        // before it runs, so it is not what makes the guarantee. What does is
        // two things that need nobody's cooperation — `AppServerExchange` ends
        // its transport on every path including cancellation, and a child whose
        // stdin closes because the app died exits on its own within 2.7 s
        // (ADR-0009). Stopping the ticker just saves a pointless last reading.
        Task { [quota] in await quota.stop() }
        menuBar?.stop()
        menuBar = nil
    }

    /// The version AgentBar introduces itself by in the App Server handshake.
    ///
    /// Its own name and its own version — never a harness identity, and never
    /// anything that could read as an official client (docs/dev/tos-boundary.md).
    private static var marketingVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Brings up the notification router and installs the delegate.
    ///
    /// A failure here is survivable and deliberately not fatal: no notification
    /// centre means a menu bar that still shows every session, and Claude Code
    /// still behaves exactly as if AgentBar were not installed.
    private func startNotifications() {
        guard let centre = UserNotificationCentre.ifAvailable() else {
            Self.logger.error("notifications unavailable — the app is not running as a bundle")
            return
        }
        let router = NotificationRouter(
            presenter: centre,
            attachments: ProviderBadgeAttachments(directory: Self.badgeDirectory()),
            frontmost: WorkspaceFrontmostApplication())
        notifications = router

        // Opening a notification shows the panel. The menu bar does not exist
        // yet, hence the deferred lookup rather than a captured reference.
        //
        // The identifier is the session the banner was about. The panel has no
        // way to scroll to or select one row, so it is logged rather than acted
        // on — the panel shows every session and the user is already looking at
        // the project the banner named.
        let delegate = NotificationDelegate { [weak self] session in
            Self.logger.notice(
                "notification opened for session \(session, privacy: .public)")
            self?.menuBar?.revealPanel()
        }
        notificationDelegate = delegate
        centre.installDelegate(delegate)

        Task { await router.start() }
    }

    /// Where the pre-rendered provider badges live.
    ///
    /// Caches, because they are derived and re-creatable — which they have to
    /// be: `UNNotificationAttachment` **moves** the file it is given into the
    /// notification's own store, so every badge is consumed by its first use.
    private static func badgeDirectory() -> URL {
        let base =
            (try? FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
        return base.appending(path: "AgentBar/badges", directoryHint: .isDirectory)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Binds the loopback endpoint, registers the provider decoders, and brings
    /// up the menu bar around them.
    ///
    /// A failure here leaves AgentBar running and blind rather than taking the
    /// app down: an endpoint that cannot bind is a menu bar with an honest
    /// `Not receiving events` in its footer, and Claude Code carries on exactly
    /// as if AgentBar had never been installed.
    private func startIngest() {
        let paths: IngestPaths
        do {
            paths = try IngestPaths.applicationSupport()
        } catch {
            Self.logger.error(
                "ingest not started, application support unavailable: \(error, privacy: .public)")
            // Still register the integration: without an endpoint it reports
            // what is on disk, which is the difference between a footer that
            // says `Not receiving events` and a panel with nothing in it.
            startMenuBar(with: [ClaudeCodeIntegration(ingest: nil), CodexIntegration(ingest: nil)])
            return
        }

        // Declared before the service so the push leg can be handed in at
        // construction: an observer attached afterwards would miss every event
        // that arrived in between.
        let relay = StateChangeRelay()
        let service = IngestService(
            paths: paths,
            store: store,
            decoders: [
                ClaudeCodeEventDecoder.route: ClaudeCodeEventDecoder(),
                CodexEventDecoder.route: CodexEventDecoder(),
            ],
            stateChanges: relay)
        ingest = service

        let codex = CodexIntegration(ingest: service)
        let menuBar = startMenuBar(with: [ClaudeCodeIntegration(ingest: service), codex])
        // The push leg fans out to four observers. The menu bar re-reads the
        // store and redraws; the router decides whether anything is worth
        // interrupting the user for; the caffeine controller decides whether the
        // Mac should still be kept awake; and the Codex integration learns the
        // one thing no file on disk can tell it. None of them knows the others
        // exist.
        // Held strongly by a local rather than in the capture list, which the
        // caffeine controller has already filled: an actor is `Sendable`, and
        // the service must outlive nothing in particular — it owns the only
        // child process and has to be reachable for as long as events arrive.
        let quota = quota
        relay.destination = { [weak menuBar, weak notifications, caffeine, weak codex] changes in
            menuBar?.stateDidChange(changes)
            notifications?.record(changes)
            // Held strongly, unlike the others: the assertion must be
            // reconsidered on every move, and a caffeine controller released
            // early would leave the Mac awake with nothing left to notice.
            caffeine.stateDidChange()
            // A Codex event can only come from a hook Codex actually ran, which
            // is the proof of trust that `config.toml` can only hint at.
            if changes.contains(where: { $0.provider == .codex }) { codex?.noteDelivery() }
            // A Codex turn ending is the moment the quota has just moved, and
            // the one moment worth reading it outside the interval. Throttled
            // inside the service, so a burst of endings is one reading.
            if changes.contains(where: Self.endsACodexTurn) { quota.turnFinished() }
        }

        Task {
            do {
                let bound = try await service.start()
                Self.logger.notice(
                    """
                    ingest listening on \(bound.host, privacy: .public):\
                    \(bound.port, privacy: .public)
                    """)
                // Binding is one of the two moments at which every install
                // report can have changed — the other is a card action.
                menuBar.endpointDidChange()
            } catch IngestEndpointError.stoppedWhileStarting {
                // Quit beat the bind. Nothing to report and nothing left behind.
            } catch {
                Self.logger.error("ingest failed to start: \(error, privacy: .public)")
                menuBar.endpointDidChange()
            }
        }
    }

    /// Whether a state change is a Codex turn coming to an end.
    ///
    /// `idle` and `failed` both are: one is `Stop`, the other `TurnFailed`, and
    /// tokens were spent either way. `unknown` deliberately is not — the
    /// watchdog giving up says nothing about whether a turn finished, and
    /// letting it trigger a read would spawn a child every time a session went
    /// quiet.
    private static func endsACodexTurn(_ change: StateChange) -> Bool {
        guard change.provider == .codex, change.from != nil else { return false }
        switch change.to?.kind {
        case .idle, .failed: return true
        default: return false
        }
    }

    @discardableResult
    private func startMenuBar(with integrations: [any ProviderIntegration]) -> MenuBarController {
        let controller = MenuBarController(
            services: AppServices(
                store: store, integrations: integrations, caffeine: caffeineBridge,
                quota: quota),
            settings: NotificationSettingsBridge(
                router: notifications ?? Self.unavailableRouter(),
                providers: Self.providers,
                caffeine: caffeineBridge))
        menuBar = controller
        controller.start()
        return controller
    }

    /// A router that can be configured and will never deliver.
    ///
    /// Used only when the notification centre could not be reached at all. The
    /// settings window still opens and still writes the matrix — the alternative
    /// is a gear that does nothing, which reads as a broken app rather than as
    /// an unavailable capability. Its permission row says notifications are not
    /// authorised, which is true.
    private static func unavailableRouter() -> NotificationRouter {
        NotificationRouter(presenter: UnavailableNotificationCentre())
    }
}

/// Carries the endpoint's state changes onto the main actor.
///
/// `StateChangeSink` is called from the connection's own task and must not
/// block, so this hands the batch to a `Task` and returns. The destination is
/// settable because the menu bar is built after the service it observes.
private final class StateChangeRelay: StateChangeSink {
    /// Main-actor isolated, which is what lets this class be `Sendable` while
    /// still being mutable: it is written once during launch and read only
    /// after the hop below.
    @MainActor var destination: (@MainActor ([StateChange]) -> Void)?

    func record(_ changes: [StateChange]) {
        Task { @MainActor in destination?(changes) }
    }
}
