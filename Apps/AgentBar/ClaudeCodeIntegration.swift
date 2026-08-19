import AgentBarCore
import AgentBarIngest
import AgentBarUI
import AppKit
import ClaudeCodeAdapter
import Foundation
import os

/// Claude Code, as the panel needs to see it.
///
/// The switch over `ClaudeCodeInstallState`, its drift and its warnings lives
/// **here**, in the app target, next to the installer it belongs to.
/// `AgentBarUI` may import only `AgentBarCore`, so it cannot hold a
/// `ClaudeCodeInstallReport` — and CLAUDE.md's rule that nothing above the
/// adapter knows the providers exist says the same thing from the other
/// direction.
@MainActor
final class ClaudeCodeIntegration: ProviderIntegration {
    private static let logger = Logger(
        subsystem: "com.molodykhvitalii.AgentBar", category: "integration")

    /// The file, not an installer.
    ///
    /// `ClaudeCodeInstaller` holds a `FileManager` and is deliberately not
    /// `Sendable`, so it is built where the work happens — which is off this
    /// actor, see `readReport` below.
    private let settingsURL: URL
    /// Absent when the endpoint could not even be constructed — no application
    /// support directory. The integration still reports what is on disk, which
    /// is the difference between a panel that says `Not receiving events` and a
    /// panel with nothing in it at all.
    private let ingest: IngestService?

    init(ingest: IngestService?, settingsURL: URL? = nil) {
        self.ingest = ingest
        self.settingsURL = settingsURL ?? ClaudeCodeInstaller.defaultSettingsURL()
    }

    var provider: Provider { .claudeCode }

    /// Reads the file and maps what it says onto the UI's own vocabulary.
    ///
    /// A read that throws is not a crash and not an empty panel: it is the
    /// `settingsUnreadable` rung, which the card renders with no write action of
    /// any kind. AgentBar refuses to write over a file it could not read.
    func status() async -> IntegrationStatus {
        let endpoint = await currentEndpoint()
        let read = await Self.readReport(at: settingsURL, for: endpoint)
        guard let report = read.report else {
            return IntegrationStatus(
                provider: .claudeCode, condition: .settingsUnreadable, detail: read.failure)
        }
        return Self.status(from: report)
    }

    /// Reads the file **off the main actor**.
    ///
    /// `nonisolated async` rather than a `Task.detached`: it is the language's
    /// own way of saying "this runs on the generic executor". The work inside is
    /// entirely synchronous — a read of `settings.json`, a `stat` for the
    /// permission warning, a read of `settings.local.json` — and every one of
    /// those blocks for as long as the volume takes. On the main thread that is
    /// a frozen panel at exactly the moment it is being presented.
    nonisolated private static func readReport(
        at settingsURL: URL, for endpoint: ClaudeCodeEndpoint?
    ) async -> (report: ClaudeCodeInstallReport?, failure: String?) {
        // `Task.detached`, not a bare `nonisolated async` body. The app target
        // builds with `SWIFT_APPROACHABLE_CONCURRENCY`, under which a
        // `nonisolated async` function runs on its **caller's** executor — and
        // the caller is the main actor, so the reads below would happen on the
        // main thread after all. That is the frozen panel this exists to avoid.
        await Task.detached {
            do {
                return (
                    try ClaudeCodeInstaller(settingsURL: settingsURL).report(for: endpoint), nil
                )
            } catch {
                return (nil, "\(error)")
            }
        }.value
    }

    static func status(from report: ClaudeCodeInstallReport) -> IntegrationStatus {
        let condition: IntegrationCondition
        var detail: String?
        var preventsEvents: Bool?

        switch report.state {
        case .notInstalled:
            condition = .notConnected
        case .installed:
            condition = .connected
        case .endpointUnavailable:
            // Defined as "hooks configured, no endpoint bound", so it is the
            // nil-endpoint case by definition and belongs on the red rung.
            condition = .notReceiving
        case .settingsUnreadable(let reason):
            condition = .settingsUnreadable
            detail = reason
        case .needsRepair(let drift):
            condition = .needsRepair
            // Every drift case already carries a finished English sentence.
            // Show the first and count the rest; the card formats nothing.
            detail = drift.first.map { first in
                drift.count > 1
                    ? "\(first.description) and \(drift.count - 1) more"
                    : first.description
            }
            // A repairable drift does not normally silence the integration —
            // except `urlNotAllowed`, where the handlers are configured and not
            // one of them will run. That distinction is what decides whether an
            // empty panel says "All quiet" or shows the onboarding card.
            preventsEvents = drift.contains(.urlNotAllowed)
        }

        return IntegrationStatus(
            provider: .claudeCode,
            condition: condition,
            detail: detail,
            notes: report.warnings.map(\.description),
            coexistence: Self.coexistence(report.overlaps),
            preventsEvents: preventsEvents)
    }

    private static func coexistence(_ overlaps: [ForeignHookOverlap]) -> CoexistenceSummary {
        CoexistenceSummary(
            notifiers: overlaps.count { $0.family == .notifier },
            keepAwake: overlaps.count { $0.family == .caffeine },
            others: overlaps.count { $0.family == .other },
            entries: overlaps.map { "\($0.event): \($0.summary)" })
    }

    /// Runs one card action.
    ///
    /// `install` writes a secret into a file the user owns, which is exactly why
    /// it needed a UI before it could be offered at all.
    func perform(_ action: IntegrationAction) async -> IntegrationActionResult {
        switch action {
        case .connect, .repair:
            return await write()
        case .retry:
            return await rebind()
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([settingsURL])
            // Not `.unchanged`: this is the one row where AgentBar has refused
            // to write, and `Nothing to change` would claim it had tried.
            return .acknowledged
        case .trust:
            // Codex only. Nothing to do for Claude Code, and inventing a
            // success would be worse than doing nothing.
            return .acknowledged
        }
    }

    private func write() async -> IntegrationActionResult {
        guard let endpoint = await currentEndpoint() else {
            return .failed(
                String(
                    localized: """
                        AgentBar has no endpoint to point the hooks at, so there is nothing \
                        to install yet.
                        """,
                    comment: "Install refused because no endpoint is bound"))
        }
        return await Self.install(at: settingsURL, endpoint: endpoint)
    }

    /// Writes **off the main actor**, for the same reason the read does — and
    /// more so: this one reads the file, takes a backup and writes it back.
    nonisolated private static func install(
        at settingsURL: URL, endpoint: ClaudeCodeEndpoint
    ) async -> IntegrationActionResult {
        await Task.detached {
            do {
                let outcome = try ClaudeCodeInstaller(settingsURL: settingsURL).install(endpoint)
                return outcome.changed ? .changed : .unchanged
            } catch let error as ClaudeCodeInstallerError {
                return .failed(error.description)
            } catch {
                return .failed("\(error)")
            }
        }.value
    }

    /// `Retry` is **not** a bare `start()`: that throws `alreadyRunning` when an
    /// endpoint is already bound. It means "bind if not bound, then re-read
    /// every report" — and if an endpoint *is* bound, re-reading the report is
    /// the whole of the work, because the state was stale.
    private func rebind() async -> IntegrationActionResult {
        guard let ingest else {
            return .failed(
                String(
                    localized: """
                        AgentBar has nowhere to keep its endpoint: its Application Support \
                        directory is unavailable.
                        """,
                    comment: "Retry refused because no endpoint can exist"))
        }
        guard await ingest.boundEndpoint == nil else { return .unchanged }
        do {
            _ = try await ingest.start()
            return .changed
        } catch IngestEndpointError.alreadyRunning {
            return .unchanged
        } catch {
            return .failed("\(error)")
        }
    }

    /// The endpoint the installer writes and the report is judged against — the
    /// pair the service holds, never the token file read a second time behind
    /// its back.
    private func currentEndpoint() async -> ClaudeCodeEndpoint? {
        guard let ingest, let credential = await ingest.boundCredential else { return nil }
        return ClaudeCodeEndpoint(bound: credential.endpoint, token: credential.token)
    }
}
