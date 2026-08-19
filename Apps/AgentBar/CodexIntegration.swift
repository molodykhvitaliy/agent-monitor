import AgentBarCore
import AgentBarIngest
import AgentBarUI
import AppKit
import CodexAdapter
import Foundation
import os

/// Codex, as the panel needs to see it.
///
/// The Claude Code integration's counterpart, with one difference that shapes
/// the whole surface: writing the configuration is not enough. Codex will not
/// run a `command` hook until the user has reviewed and trusted it in `/hooks`,
/// so this integration has a state between "not connected" and "connected", and
/// the card exists to say so out loud rather than leave the user with an app
/// that shows nothing and explains nothing.
///
/// AgentBar cannot grant that trust, and never suggests the flag that skips it.
/// What it can do is notice — see ADR-0008.
@MainActor
final class CodexIntegration: ProviderIntegration {
    /// `nonisolated` because the writes happen off the main actor, and a
    /// `Logger` is `Sendable`: the app target defaults to main-actor isolation,
    /// which would otherwise put the log line out of reach of the code that has
    /// something to say.
    nonisolated private static let logger = Logger(
        subsystem: "com.molodykhvitalii.AgentBar", category: "integration")

    /// The Codex home directory, not an installer: `CodexInstaller` holds a
    /// `FileManager` and is deliberately not `Sendable`, so it is built where
    /// the work happens — off this actor, see `readReport` below.
    private let home: URL
    /// Absent when the endpoint could not be constructed at all. The integration
    /// still reports what is on disk, which is the difference between a panel
    /// that says `Not receiving events` and a panel with nothing in it.
    private let ingest: IngestService?
    /// The helper this build of AgentBar would install, or `nil` when the app is
    /// not running from a bundle that contains one.
    private let helperURL: URL?

    /// Whether a Codex event has actually arrived since this launch.
    ///
    /// The one fact that cannot be wrong. A hook that did not run cannot deliver
    /// anything, so a delivery proves the definitions are trusted — where the
    /// `[hooks.state]` table is only evidence, and evidence in a format Codex
    /// does not document.
    private var hasDelivered = false
    /// Whether AgentBar has rewritten a hook definition that Codex has not run
    /// since.
    ///
    /// The counterweight to `hasDelivered`, and the reason a repair cannot read
    /// as `Connected`. Codex keys a trust record to a hook's **position**, so
    /// rewriting the command at the same position leaves the old record in place
    /// looking exactly like consent — for a definition whose hash no longer
    /// matches and which Codex will therefore skip. Only this object knows the
    /// rewrite happened; the disk cannot tell.
    private var trustPending = false

    /// Where AgentBar remembers what Codex had trusted when it last wrote.
    ///
    /// In AgentBar's own directory, never in `~/.codex`. Absent only when the
    /// application support directory could not be resolved at all, in which case
    /// the launch's own `trustPending` flag is all that carries the fact.
    private let trustBaselineURL: URL?

    init(
        ingest: IngestService?,
        home: URL? = nil,
        helperURL: URL? = nil,
        trustBaselineURL: URL? = nil
    ) {
        self.ingest = ingest
        self.home = home ?? CodexConfigFile.defaultHome()
        self.helperURL = helperURL ?? CodexHookCommand.bundledHelperURL()
        self.trustBaselineURL =
            trustBaselineURL
            ?? (try? IngestPaths.applicationSupport())?.directory
            .appending(path: "codex-trust-baseline.json")
    }

    var provider: Provider { .codex }

    /// Called from the push leg when a change carrying `.codex` arrives.
    func noteDelivery() {
        trustPending = false
        guard !hasDelivered else { return }
        hasDelivered = true
        Self.logger.notice("codex hooks are live — an event arrived")
        // The baseline exists to ask "has Codex reviewed what we wrote?". A
        // delivery answers it, so the question — and the file — can go.
        let installer = CodexInstaller(home: home, trustBaselineURL: trustBaselineURL)
        Task.detached { installer.clearTrustBaseline() }
    }

    func status() async -> IntegrationStatus {
        let endpoint = await currentEndpoint()
        let report = await Self.readReport(
            home: home, baselineURL: trustBaselineURL, endpoint: endpoint,
            hasDelivered: hasDelivered, trustPending: trustPending)
        var status = Self.status(from: report)
        // A bundle with no helper in it cannot install anything, and the report
        // has no way to say so — it is a fact about this build, not about the
        // user's configuration.
        if helperURL == nil {
            status = IntegrationStatus(
                provider: .codex,
                condition: status.condition == .connected ? .notReceiving : status.condition,
                detail: String(
                    localized: "This build of AgentBar has no helper to install",
                    comment: "The app bundle is missing agentbar-helper"),
                notes: status.notes,
                coexistence: status.coexistence,
                preventsEvents: true)
        }
        return status
    }

    /// Reads both files **off the main actor**, for the same reason the Claude
    /// Code integration does: `hooks.json`, `config.toml` and a `stat` for the
    /// helper each block for as long as the volume takes, and on the main thread
    /// that is a frozen panel at the moment it is being presented.
    nonisolated private static func readReport(
        home: URL, baselineURL: URL?, endpoint: CodexEndpoint?, hasDelivered: Bool,
        trustPending: Bool
    ) async -> CodexInstallReport {
        // `Task.detached`, not a bare `nonisolated async` call. The app target
        // builds with `SWIFT_APPROACHABLE_CONCURRENCY`, under which a
        // `nonisolated async` function runs on its **caller's** executor — and
        // the caller here is the main actor, which is precisely the frozen panel
        // this indirection exists to avoid.
        await Task.detached {
            CodexInstaller(home: home, trustBaselineURL: baselineURL).report(
                for: endpoint, hasDelivered: hasDelivered, trustPending: trustPending)
        }.value
    }

    static func status(from report: CodexInstallReport) -> IntegrationStatus {
        let condition: IntegrationCondition
        var detail: String?
        var preventsEvents: Bool?

        switch report.state {
        case .notInstalled:
            condition = .notConnected
        case .installed:
            condition = .connected
        case .installedNotTrusted(let trust):
            // The headline state of this whole step: configured, inert, and the
            // second line says what to do about it.
            condition = .notTrusted
            detail = trust.description
        case .disabledInCodex:
            condition = .notTrusted
            detail = CodexTrustStatus.disabled.description
        case .endpointUnavailable:
            condition = .notReceiving
        case .hooksUnreadable(let reason):
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
            // Most drift degrades the integration. These two stop it dead: the
            // hooks name a helper that is not where Codex will look, so every
            // one of them fails in the user's own session.
            preventsEvents = drift.contains {
                switch $0 {
                case .helperMissing, .helperMoved: true
                default: false
                }
            }
        }

        return IntegrationStatus(
            provider: .codex,
            condition: condition,
            detail: detail,
            notes: report.warnings.map(\.description),
            coexistence: Self.coexistence(report.overlaps),
            preventsEvents: preventsEvents)
    }

    private static func coexistence(_ overlaps: [CodexHookOverlap]) -> CoexistenceSummary {
        CoexistenceSummary(
            notifiers: overlaps.count { $0.family == .notifier },
            keepAwake: overlaps.count { $0.family == .caffeine },
            others: overlaps.count { $0.family == .other },
            entries: overlaps.map { "\($0.event): \($0.summary)" })
    }

    // MARK: - Actions

    func perform(_ action: IntegrationAction) async -> IntegrationActionResult {
        switch action {
        case .connect, .repair:
            return await write()
        case .trust:
            return await recheckTrust()
        case .retry:
            return await rebind()
        case .revealInFinder:
            let installer = CodexInstaller(home: home)
            let target =
                FileManager.default.fileExists(
                    atPath: installer.hooksFileURL.path(percentEncoded: false))
                ? installer.hooksFileURL : home
            NSWorkspace.shared.activateFileViewerSelecting([target])
            // Not `.unchanged`: this is the row where AgentBar has refused to
            // write, and `Nothing to change` would claim it had tried.
            return .acknowledged
        }
    }

    private func write() async -> IntegrationActionResult {
        guard let helperURL else {
            return .failed(
                String(
                    localized: """
                        AgentBar cannot find its own helper, so there is nothing to point \
                        Codex's hooks at.
                        """,
                    comment: "Install refused because the bundle has no helper"))
        }
        let (result, requiresTrust) = await Self.install(
            home: home, baselineURL: trustBaselineURL,
            endpoint: CodexEndpoint(helperURL: helperURL))
        if requiresTrust {
            // Whatever Codex trusted, it did not trust what was just written.
            // Both flags move together: the delivery that would clear this is
            // the next one, from the definition that now exists.
            trustPending = true
            hasDelivered = false
        }
        return result
    }

    /// Writes **off the main actor**, for the same reason the read is: this one
    /// reads the file, takes a backup and writes it back.
    ///
    /// `requiresTrust` comes back rather than only reaching the log, because it
    /// is what the caller has to remember: Codex keys trust to a position, so
    /// the record left behind by a definition AgentBar has just replaced would
    /// otherwise read as consent for the one it wrote.
    nonisolated private static func install(
        home: URL, baselineURL: URL?, endpoint: CodexEndpoint
    ) async -> (result: IntegrationActionResult, requiresTrust: Bool) {
        await Task.detached {
            do {
                let outcome = try CodexInstaller(home: home, trustBaselineURL: baselineURL)
                    .install(endpoint)
                // A write that needs trusting is still a write that succeeded,
                // and must not be painted as a failure. The row's next report is
                // `Installed, not trusted`, which carries the instruction as its
                // own second line — the designed path through this flow, and the
                // reason the state exists at all.
                if outcome.requiresTrust {
                    logger.notice(
                        "codex hooks written; they are inert until the user trusts them")
                }
                return (outcome.changed ? .changed : .unchanged, outcome.requiresTrust)
            } catch let error as CodexInstallerError {
                return (.failed(error.description), false)
            } catch {
                return (.failed("\(error)"), false)
            }
        }.value
    }

    /// The `Trust` button, which cannot trust anything.
    ///
    /// Codex records trust from its own interface, and there is no supported way
    /// to write that record from outside. The documented bypass flag is not an
    /// option here — see ADR-0008, which names it and says why. So the button
    /// does the only honest thing: it re-reads the state and says what it found.
    private func recheckTrust() async -> IntegrationActionResult {
        let endpoint = await currentEndpoint()
        let report = await Self.readReport(
            home: home, baselineURL: trustBaselineURL, endpoint: endpoint,
            hasDelivered: hasDelivered, trustPending: trustPending)
        switch report.state {
        case .installed:
            return .changed
        case .installedNotTrusted(let trust):
            return .failed(trust.description)
        case .disabledInCodex:
            return .failed(CodexTrustStatus.disabled.description)
        default:
            // Any other state is one the row will render for itself on its next
            // report; claiming a result here would be inventing one.
            return .acknowledged
        }
    }

    /// `Retry` means "bind if not bound, then re-read every report" — never a
    /// bare `start()`, which throws when an endpoint is already bound.
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

    /// The helper AgentBar would install, or `nil` when there is no endpoint for
    /// it to reach.
    ///
    /// Unlike the Claude Code endpoint this carries no port and no token: the
    /// helper reads the discovery file when it runs. What the binding decides
    /// here is only whether the hooks have anywhere to deliver to.
    private func currentEndpoint() async -> CodexEndpoint? {
        guard let helperURL, let ingest, await ingest.boundEndpoint != nil else { return nil }
        return CodexEndpoint(helperURL: helperURL)
    }
}
