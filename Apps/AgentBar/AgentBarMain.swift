import AgentBarCore
import AgentBarIngest
import AgentBarUI
import AppKit
import ClaudeCodeAdapter
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

    private let store = SessionStore()
    private var menuBar: MenuBarController?
    private var ingest: IngestService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement in Info.plist already selects accessory activation. This
        // repeats it so a build with a mis-merged plist still comes up without a
        // Dock icon rather than as a windowless regular app the user cannot quit.
        NSApp.setActivationPolicy(.accessory)
        startIngest()
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
        menuBar?.stop()
        menuBar = nil
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
            startMenuBar(with: [ClaudeCodeIntegration(ingest: nil)])
            return
        }

        // Declared before the service so the push leg can be handed in at
        // construction: an observer attached afterwards would miss every event
        // that arrived in between.
        let relay = StateChangeRelay()
        let service = IngestService(
            paths: paths,
            store: store,
            decoders: [ClaudeCodeEventDecoder.route: ClaudeCodeEventDecoder()],
            stateChanges: relay)
        ingest = service

        let menuBar = startMenuBar(with: [ClaudeCodeIntegration(ingest: service)])
        relay.destination = { [weak menuBar] changes in
            menuBar?.stateDidChange(changes)
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

    @discardableResult
    private func startMenuBar(with integrations: [ClaudeCodeIntegration]) -> MenuBarController {
        let controller = MenuBarController(
            services: AppServices(store: store, integrations: integrations))
        menuBar = controller
        controller.start()
        return controller
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
