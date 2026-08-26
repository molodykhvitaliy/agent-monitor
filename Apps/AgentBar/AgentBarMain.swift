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
    static let logger = Logger(
        subsystem: "com.molodykhvitalii.AgentBar", category: "lifecycle")

    /// Every provider the assembly registers. One list, so the footer's
    /// denominator, the settings matrix's columns and the integrations built
    /// below cannot disagree about what exists.
    static let providers: [Provider] = [.claudeCode, .codex]

    let store = SessionStore()
    /// Keeps the Mac awake while an agent works. Built here rather than lazily:
    /// it holds the only power assertion in the process, and one owner is what
    /// makes "released when the process dies" a guarantee rather than a hope.
    let caffeine = CaffeineController()
    lazy var caffeineBridge = CaffeineBridge(controller: caffeine)
    /// Codex's limits. Built here for the same reason the caffeine controller
    /// is: it owns the only thing in the process that spawns a child, and one
    /// owner is what makes "no process outlives the app" a guarantee.
    let quota = QuotaService(clientVersion: AppDelegate.marketingVersion)
    /// Whether macOS starts AgentBar at login. Built here rather than inside the
    /// settings bridge because the uninstaller unregisters the very same
    /// registration the toggle shows, and two instances would disagree about it
    /// for as long as the window stayed open.
    let launchAtLogin = LaunchAtLogin()
    var menuBar: MenuBarController?
    var ingest: IngestService?
    var notifications: NotificationRouter?
    /// Held strongly: `UNUserNotificationCenter` keeps its delegate **weakly**,
    /// and a released one stops receiving responses with nothing to say so.
    private var notificationDelegate: NotificationDelegate?
    /// Counts what the endpoint reports and keeps the last hundred lines, on the
    /// way to the unified log it was already going to. The diagnostics section
    /// reads it; nothing else does.
    let ingestDiagnostics = IngestDiagnosticsRecorder()
    /// Set when the system wakes, so a night's sleep does not leave the panel
    /// showing rows the watchdog has already given up on.
    private var wakeObserver: NSObjectProtocol?

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
        observeWake()
    }

    /// Sweeps and re-reads when the Mac comes back.
    ///
    /// > **`ContinuousClock` keeps counting across system sleep, so the watchdog
    /// > is already right — what is missing is the nudge.** Nothing re-reads the
    /// > store by itself: push carries state moves, and a machine that was
    /// > asleep received none. Without this, a lid opened after a night shows
    /// > yesterday's rows for up to the forty-five seconds of the closed-panel
    /// > clock, and the power assertion is reconsidered no sooner. One
    /// > notification closes both.
    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Self.logger.info("system woke — sweeping")
                self.menuBar?.systemDidWake()
                // The lease may well have expired while the Mac was asleep, and
                // an agent that was working before it slept is working now.
                self.caffeine.stateDidChange()
            }
        }
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
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
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
            attachments: EventAttachments(directory: Self.attachmentDirectory()),
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

    /// Where the pre-rendered attachment squares live.
    ///
    /// Caches, because they are derived and re-creatable — which they have to
    /// be: `UNNotificationAttachment` **moves** the file it is given into the
    /// notification's own store, so every square is consumed by its first use.
    private static func attachmentDirectory() -> URL {
        let base =
            (try? FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
        return base.appending(path: "AgentBar/attachments", directoryHint: .isDirectory)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}

/// Carries the endpoint's state changes onto the main actor.
///
/// `StateChangeSink` is called from the connection's own task and must not
/// block, so this hands the batch to a `Task` and returns. The destination is
/// settable because the menu bar is built after the service it observes.
final class StateChangeRelay: StateChangeSink {
    /// Main-actor isolated, which is what lets this class be `Sendable` while
    /// still being mutable: it is written once during launch and read only
    /// after the hop below.
    @MainActor var destination: (@MainActor ([StateChange]) -> Void)?

    func record(_ changes: [StateChange]) {
        Task { @MainActor in destination?(changes) }
    }
}
