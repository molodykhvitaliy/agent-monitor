import AgentBarCore
import AgentBarIngest
import AgentBarNotifications
import AgentBarUI
import ClaudeCodeAdapter
import CodexAdapter
import Foundation

/// Assembly: the endpoint, the provider decoders, the push leg's fan-out, and
/// the menu bar built around them.
///
/// Split from the lifecycle half of the delegate for length. What is left there
/// is the application's own life — launch, sleep and wake, termination — and
/// what is here is the wiring those methods start and stop.
extension AppDelegate {

    /// Binds the loopback endpoint, registers the provider decoders, and brings
    /// up the menu bar around them.
    ///
    /// A failure here leaves AgentBar running and blind rather than taking the
    /// app down: an endpoint that cannot bind is a menu bar with an honest
    /// `Not receiving events` in its footer, and Claude Code carries on exactly
    /// as if AgentBar had never been installed.
    func startIngest() {
        let paths: IngestPaths
        do {
            paths = try IngestPaths.applicationSupport()
        } catch {
            Self.logger.error(
                "ingest not started, application support unavailable: \(error, privacy: .public)")
            // Still register the integration: without an endpoint it reports
            // what is on disk, which is the difference between a footer that
            // says `Not receiving events` and a panel with nothing in it.
            startMenuBar(
                with: [ClaudeCodeIntegration(ingest: nil), CodexIntegration(ingest: nil)],
                ingest: nil)
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
            diagnostics: ingestDiagnostics,
            stateChanges: relay)
        ingest = service

        let codex = CodexIntegration(ingest: service)
        let integrations: [any ProviderIntegration] = [
            ClaudeCodeIntegration(ingest: service), codex,
        ]
        let menuBar = startMenuBar(with: integrations, ingest: service)
        // The Codex helper is refreshed once, at launch, rather than on every
        // status read — see `CodexIntegration.prepare()`: a read that writes is
        // also a read that would put the helper back a moment after the
        // uninstaller removed it.
        //
        // It runs beside the menu bar rather than before it, so a slow volume
        // cannot delay the status item appearing, and every report is re-read
        // when it lands: the first read can legitimately find no helper, and
        // the row must not be left saying so once there is one.
        Task {
            await codex.prepare()
            menuBar.endpointDidChange()
        }
        relay.destination = pushLeg(menuBar: menuBar, codex: codex)

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

    /// The push leg's fan-out: four observers, none of which knows the others
    /// exist.
    ///
    /// The menu bar re-reads the store and redraws; the router decides whether
    /// anything is worth interrupting the user for; the caffeine controller
    /// decides whether the Mac should still be kept awake; and the Codex
    /// integration learns the one thing no file on disk can tell it.
    private func pushLeg(
        menuBar: MenuBarController, codex: CodexIntegration
    ) -> @MainActor ([StateChange]) -> Void {
        // Held strongly by a local rather than captured weakly: an actor is
        // `Sendable`, and the quota service owns the only child process in this
        // app — it has to be reachable for as long as events arrive.
        let quota = quota
        return { [weak menuBar, weak notifications, caffeine, weak codex] changes in
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
    }

    /// Whether a state change is a Codex turn coming to an end.
    ///
    /// The rule itself is `StateChange.endsATurn`, in the domain, where a suite
    /// reaches it. All that is left here is the provider, which is the only part
    /// of the question this file is entitled to know about.
    private static func endsACodexTurn(_ change: StateChange) -> Bool {
        change.provider == .codex && change.endsATurn
    }

    @discardableResult
    private func startMenuBar(
        with integrations: [any ProviderIntegration], ingest: IngestService?
    ) -> MenuBarController {
        let diagnostics = AgentBarDiagnostics(
            ingest: ingest, integrations: integrations, notifications: notifications,
            caffeine: caffeineBridge, recorder: ingestDiagnostics)
        let controller = MenuBarController(
            services: AppServices(
                store: store, integrations: integrations, caffeine: caffeineBridge,
                quota: quota),
            settings: NotificationSettingsBridge(
                router: notifications ?? Self.unavailableRouter(),
                providers: Self.providers,
                caffeine: caffeineBridge,
                launchAtLogin: launchAtLogin,
                removal: AgentBarRemoval(ingest: ingest, launchAtLogin: launchAtLogin),
                diagnostics: diagnostics))
        menuBar = controller
        controller.start()
        // After the bind rather than before it, and after the integrations have
        // been registered: a self-test run at the moment the app started would
        // report an endpoint that has not finished binding as a fault.
        Task {
            try? await Task.sleep(for: Self.selfTestDelay)
            await diagnostics.runStartupSelfTest()
        }
        return controller
    }

    /// How long the launch self-test waits before asking.
    ///
    /// The bind is a few milliseconds and the first install read a few more;
    /// two seconds is long enough that neither is in flight, and short enough
    /// that the log line is still next to the launch it describes.
    private static let selfTestDelay: Duration = .seconds(2)

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
