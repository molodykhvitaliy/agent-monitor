import AgentBarCore
import AgentBarIngest
import AgentBarNotifications
import AgentBarUI
import AppKit
import CodexAdapter
import Foundation
import os

/// The self-test, and everything else the diagnostics section shows.
///
/// > **Why this is a feature and not a log line.** AgentBar answers every hook
/// > with success whatever happens — that is the safe-superset rule, and it is
/// > not negotiable — so a payload it could not decode, a token that no longer
/// > matches and a hook posting at a port nobody holds are all completely
/// > invisible from the agent's side. Until this existed the only record was
/// > `os_log`, which is a fine place for a developer to look and no place at all
/// > for the person the failure is happening to.
///
/// It runs at launch as well as on demand: the launch run writes the whole
/// report to the unified log, so the state at start-up is recoverable after the
/// fact even by somebody who never opened the window.
@MainActor
final class AgentBarDiagnostics {
    private static let logger = Logger(
        subsystem: "com.molodykhvitalii.AgentBar", category: "diagnostics")

    private let ingest: IngestService?
    private let integrations: [any ProviderIntegration]
    private let notifications: NotificationRouter?
    private let caffeine: CaffeineBridge
    private let recorder: IngestDiagnosticsRecorder
    private let applicationSupport: URL?
    private let launchedAt = ContinuousClock.now

    init(
        ingest: IngestService?,
        integrations: [any ProviderIntegration],
        notifications: NotificationRouter?,
        caffeine: CaffeineBridge,
        recorder: IngestDiagnosticsRecorder,
        applicationSupport: URL? = (try? IngestPaths.applicationSupport())?.directory
    ) {
        self.ingest = ingest
        self.integrations = integrations
        self.notifications = notifications
        self.caffeine = caffeine
        self.recorder = recorder
        self.applicationSupport = applicationSupport
    }

    // MARK: - The report

    func report() async -> DiagnosticsReport {
        var checks: [DiagnosticsCheck] = [await endpointCheck()]
        for integration in integrations {
            checks.append(DiagnosticsCheck(integration: await integration.status()))
        }
        checks.append(helperCheck())
        checks.append(await notificationCheck())
        checks.append(caffeineCheck())

        let snapshot = recorder.snapshot()
        return DiagnosticsReport(
            checks: checks,
            counters: Self.counters(snapshot.counters),
            recent: snapshot.recent.map(Self.entry),
            resources: ProcessResources.summary(since: launchedAt),
            takenAt: Date())
    }

    /// Runs the self-test at launch and writes it to the unified log.
    ///
    /// The one place the report goes without anybody asking. A user who never
    /// opens the window still leaves a record of what was true when the app came
    /// up, which is exactly the question a "nothing arrives" report starts from.
    func runStartupSelfTest() async {
        let report = await self.report()
        for check in report.checks {
            let line = "\(check.verdict.rawValue) — \(check.title): \(check.detail)"
            switch check.verdict {
            case .pass: Self.logger.info("self-test \(line, privacy: .public)")
            case .warn: Self.logger.notice("self-test \(line, privacy: .public)")
            case .fail: Self.logger.error("self-test \(line, privacy: .public)")
            }
        }
    }

    // MARK: - Checks

    private func endpointCheck() async -> DiagnosticsCheck {
        let title = String(localized: "Loopback endpoint", comment: "Self-test check")
        guard let ingest else {
            return DiagnosticsCheck(
                id: "endpoint", title: title, verdict: .fail,
                detail: String(
                    localized: "not started",
                    comment: "Self-test detail when the endpoint could not be built"),
                remedy: String(
                    localized: """
                        AgentBar could not reach its Application Support directory, so it has \
                        nowhere to keep its token. Nothing can arrive until that is fixed.
                        """,
                    comment: "Remedy when the endpoint could not be built"))
        }
        guard let bound = await ingest.boundEndpoint else {
            return DiagnosticsCheck(
                id: "endpoint", title: title, verdict: .fail,
                detail: String(
                    localized: "not listening", comment: "Self-test detail for an unbound endpoint"
                ),
                remedy: String(
                    localized: """
                        Open the panel and press Retry on a provider row. If it keeps failing, \
                        something else is holding every port in AgentBar's range.
                        """,
                    comment: "Remedy for an unbound endpoint"))
        }
        let socket = bound.socketPath.map { $0.lastPathComponent } ?? "—"
        return DiagnosticsCheck(
            id: "endpoint", title: title, verdict: .pass,
            detail: "127.0.0.1:\(bound.port) · \(socket)")
    }

    private func helperCheck() -> DiagnosticsCheck {
        let title = String(localized: "Codex helper", comment: "Self-test check")
        guard let applicationSupport else {
            return DiagnosticsCheck(
                id: "helper", title: title, verdict: .fail,
                detail: String(
                    localized: "no Application Support directory",
                    comment: "Self-test detail when the helper path cannot be derived"))
        }
        let url = CodexHelperDeployment.destination(in: applicationSupport)
        let path = url.path(percentEncoded: false)
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return DiagnosticsCheck(
                id: "helper", title: title, verdict: .warn,
                detail: String(
                    localized: "not deployed", comment: "Self-test detail for a missing helper"),
                // Not "press Repair": the row offers `Connect` when the hooks
                // are not installed and `Repair` when they are, and naming the
                // wrong one sends the user looking for a button that is not
                // there.
                remedy: String(
                    localized: """
                        Use the button on the Codex row in AgentBar's panel. Every Codex hook \
                        runs this file, so none of them can deliver until it is there.
                        """,
                    comment: "Remedy for a missing helper"))
        }
        return DiagnosticsCheck(
            id: "helper", title: title, verdict: .pass,
            detail: String(localized: "deployed", comment: "Self-test detail for a live helper"))
    }

    private func notificationCheck() async -> DiagnosticsCheck {
        let title = String(localized: "Notification permission", comment: "Self-test check")
        guard let notifications else {
            return DiagnosticsCheck(
                id: "notifications", title: title, verdict: .fail,
                detail: String(
                    localized: "no notification centre",
                    comment: "Self-test detail when the centre is unreachable"),
                remedy: String(
                    localized: """
                        AgentBar is not running as an application bundle, so macOS will not \
                        deliver anything. Launch AgentBar.app rather than the built executable.
                        """,
                    comment: "Remedy when the notification centre is unreachable"))
        }
        await notifications.refreshAuthorization()
        switch notifications.authorization {
        case .authorized:
            return DiagnosticsCheck(
                id: "notifications", title: title, verdict: .pass,
                detail: String(localized: "granted", comment: "Self-test detail"))
        case .provisional:
            return DiagnosticsCheck(
                id: "notifications", title: title, verdict: .warn,
                detail: String(localized: "quiet delivery only", comment: "Self-test detail"),
                remedy: String(
                    localized: """
                        macOS is delivering silently to Notification Centre. Turn on banners in \
                        System Settings › Notifications › AgentBar.
                        """,
                    comment: "Remedy for provisional authorisation"))
        case .notDetermined:
            return DiagnosticsCheck(
                id: "notifications", title: title, verdict: .warn,
                detail: String(localized: "not asked yet", comment: "Self-test detail"),
                remedy: String(
                    localized: "Press Allow in the banner at the top of this window.",
                    comment: "Remedy for unasked authorisation"))
        case .denied:
            return DiagnosticsCheck(
                id: "notifications", title: title, verdict: .fail,
                detail: String(localized: "refused", comment: "Self-test detail"),
                remedy: String(
                    localized: """
                        Turn AgentBar on in System Settings › Notifications. Nothing AgentBar \
                        sends will be shown until you do.
                        """,
                    comment: "Remedy for denied authorisation"))
        }
    }

    private func caffeineCheck() -> DiagnosticsCheck {
        let indicator = caffeine.indicator()
        let title = String(localized: "Keeping the Mac awake", comment: "Self-test check")
        guard indicator.appearance != .failed else {
            return DiagnosticsCheck(
                id: "caffeine", title: title, verdict: .fail, detail: indicator.summary,
                remedy: String(
                    localized: """
                        macOS refused the power assertion. AgentBar will keep trying; the Mac \
                        may sleep under a running agent until it succeeds.
                        """,
                    comment: "Remedy when the power assertion was refused"))
        }
        return DiagnosticsCheck(
            id: "caffeine", title: title, verdict: .pass, detail: indicator.summary)
    }
}
