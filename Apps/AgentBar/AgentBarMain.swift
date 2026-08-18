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
// AppKit's lifecycle is used rather than SwiftUI's `App`: step 06 needs an
// NSStatusItem with a non-activating panel, which `MenuBarExtra` cannot express.

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

    private var statusItem: StatusItemController?
    private let store = SessionStore()
    private var ingest: IngestService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement in Info.plist already selects accessory activation. This
        // repeats it so a build with a mis-merged plist still comes up without a
        // Dock icon rather than as a windowless regular app the user cannot quit.
        NSApp.setActivationPolicy(.accessory)
        statusItem = StatusItemController()
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
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let ingest else { return .terminateNow }
        Task {
            _ = await withTaskGroup(of: Void.self, returning: Void.self) { group in
                group.addTask { await ingest.stop() }
                group.addTask { try? await Task.sleep(for: .seconds(2)) }
                await group.next()
                group.cancelAll()
            }
            self.ingest = nil
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItem?.remove()
        statusItem = nil
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Binds the loopback endpoint and registers the provider decoders.
    ///
    /// A failure here leaves AgentBar running and blind rather than taking the
    /// app down: an endpoint that cannot bind is a menu bar with nothing in it,
    /// and Claude Code carries on exactly as if AgentBar had never been
    /// installed. Step 06 turns this into something the panel can say.
    private func startIngest() {
        let service: IngestService
        do {
            service = IngestService(
                paths: try IngestPaths.applicationSupport(),
                store: store,
                decoders: [ClaudeCodeEventDecoder.route: ClaudeCodeEventDecoder()])
        } catch {
            Self.logger.error(
                "ingest not started, application support unavailable: \(error, privacy: .public)")
            return
        }
        ingest = service
        Task {
            do {
                let bound = try await service.start()
                Self.logger.notice(
                    """
                    ingest listening on \(bound.host, privacy: .public):\
                    \(bound.port, privacy: .public)
                    """)
            } catch IngestEndpointError.stoppedWhileStarting {
                // Quit beat the bind. Nothing to report and nothing left behind.
            } catch {
                Self.logger.error("ingest failed to start: \(error, privacy: .public)")
            }
        }
    }
}
