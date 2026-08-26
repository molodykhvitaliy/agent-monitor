import AgentBarIngest
import AgentBarNotifications
import AgentBarPower
import AgentBarUI
import ClaudeCodeAdapter
import CodexAdapter
import CodexAppServer
import Foundation
import ServiceManagement
import os

/// Takes AgentBar back out of the two files it wrote and deletes what it made.
///
/// > **The rule this whole type obeys: never guess on the way out.** Every step
/// > removes exactly what AgentBar wrote, recognised by the marker AgentBar
/// > wrote it with — a hook `url` on AgentBar's own loopback path, a hook
/// > `command` naming `agentbar-helper`, a file at a path this app derived. When
/// > a step cannot do that, it does **not** widen the match, look for something
/// > similar, or delete a directory it merely recognises the shape of. It
/// > reports the exact location and the exact thing to look for there, and the
/// > sequence carries on.
///
/// > **Order is load-bearing in one place.** A provider's hooks come out before
/// > the file they name, so a hook removal that fails leaves an executable that
/// > still exists rather than nine hook entries pointing at nothing. The Claude
/// > Code and Codex halves are independent of each other and run in that order
/// > only because it is the order the rest of the app names them in.
///
/// It lives in the app target for the reason every provider decision does:
/// this is the only place allowed to know that Claude Code and Codex both
/// exist, and `AgentBarUI` — which renders the report — may reach only
/// `AgentBarCore`.
@MainActor
final class AgentBarRemoval {
    private static let logger = Logger(
        subsystem: "com.molodykhvitalii.AgentBar", category: "removal")

    /// The defaults keys AgentBar owns, checked after the domain is removed so
    /// the step can say whether it actually worked rather than assume it did.
    ///
    /// Spelled from the constants that write them, never as literals: a key that
    /// gets renamed must break this list at compile time rather than leave the
    /// check quietly looking for something nothing writes.
    ///
    /// Internal, like the stored properties below, because `+Footprint` is an
    /// extension in another file and an extension cannot see a private member.
    static let ownedDefaultsKeys = [
        UserDefaultsNotificationSettings.defaultsKey,
        UserDefaultsCaffeineSettings.defaultsKey,
        OnboardingState.defaultsKey,
        QuotaSettings.intervalDefaultsKey,
        CodexExecutable.overrideDefaultsKey,
    ]

    let claudeSettingsURL: URL
    let codexHome: URL
    let applicationSupport: URL?
    let ingest: IngestService?
    let launchAtLogin: LaunchAtLogin
    let defaults: UserDefaults
    let bundleIdentifier: String
    let fileManager = FileManager.default

    init(
        ingest: IngestService?,
        launchAtLogin: LaunchAtLogin,
        claudeSettingsURL: URL? = nil,
        codexHome: URL? = nil,
        applicationSupport: URL? = nil,
        defaults: UserDefaults = .standard,
        bundleIdentifier: String = Bundle.main.bundleIdentifier
            ?? "com.molodykhvitalii.AgentBar"
    ) {
        self.ingest = ingest
        self.launchAtLogin = launchAtLogin
        self.claudeSettingsURL = claudeSettingsURL ?? ClaudeCodeInstaller.defaultSettingsURL()
        self.codexHome = codexHome ?? CodexConfigFile.defaultHome()
        self.applicationSupport =
            applicationSupport ?? (try? IngestPaths.applicationSupport())?.directory
        self.defaults = defaults
        self.bundleIdentifier = bundleIdentifier
    }

    /// Runs every step, in order, whatever any of them does.
    func removeEverything() async -> RemovalReport {
        var steps: [RemovalStep] = []
        steps.append(await stopEndpoint())
        steps.append(await removeClaudeCodeHooks())
        let codexHooks = await removeCodexHooks()
        steps.append(codexHooks)
        steps.append(codexTrustRecord(hadHooks: codexHooks.outcome != .nothingToRemove))
        steps.append(await removeCodexHelper())
        steps.append(removeLoginItem())
        steps.append(removeApplicationSupport())
        steps.append(removeCaches())
        steps.append(removePreferences())
        let report = RemovalReport(steps: steps)
        Self.logger.notice(
            """
            removal finished: \(report.steps.count - report.failures.count, privacy: .public) \
            of \(report.steps.count, privacy: .public) done
            """)
        return report
    }

    // MARK: - The endpoint

    /// Stops listening before anything is deleted.
    ///
    /// Two reasons, and the second is the one that matters. The endpoint owns
    /// the socket and the discovery file in the directory two steps below are
    /// about to remove, and `stop()` retracts both properly rather than leaving
    /// them to be unlinked from underneath it. And a helper that runs during the
    /// removal then finds no endpoint and exits silently, instead of posting
    /// into a port that is about to stop answering.
    private func stopEndpoint() async -> RemovalStep {
        let title = String(localized: "Event endpoint", comment: "Removal step")
        guard let ingest else {
            return RemovalStep(
                id: "endpoint", title: title, location: "127.0.0.1",
                outcome: .nothingToRemove)
        }
        // Read for the wording, and **not** used to decide whether to stop.
        // `IngestService.stopRequested` exists because a stop issued while a
        // bind is in flight would otherwise be overtaken by the start it was
        // meant to cancel — and during that window `boundEndpoint` is still
        // `nil`. Skipping `stop()` here would defeat exactly the guard the
        // endpoint has for this, and the start would then republish the
        // discovery file and re-bind the socket into a directory two steps
        // below are about to delete.
        let wasBound = await ingest.boundEndpoint != nil
        await ingest.stop()
        guard wasBound else {
            return RemovalStep(
                id: "endpoint", title: title, location: "127.0.0.1",
                outcome: .nothingToRemove)
        }
        return RemovalStep(
            id: "endpoint", title: title, location: "127.0.0.1",
            outcome: .removed(
                detail: String(
                    localized: """
                        Stopped listening. AgentBar will not receive another event until it is \
                        restarted.
                        """,
                    comment: "Detail of the endpoint removal step")))
    }

    // MARK: - Claude Code

    private func removeClaudeCodeHooks() async -> RemovalStep {
        let title = String(localized: "Claude Code hooks", comment: "Removal step")
        let location = Self.display(claudeSettingsURL)
        // The path, not a URL with a port in it: the ladder moves the port, and
        // the path is what the installer itself matches on. Spelled from
        // `ClaudeCodeEndpoint.path` so the instruction cannot drift from the
        // marker it describes.
        let remedy = String(
            localized: """
                Open \(location) and delete the hook entries whose "url" ends with \
                \(ClaudeCodeEndpoint.path) — those are the only ones AgentBar wrote. Leave \
                everything else exactly as it is.
                """,
            comment: "How to remove Claude Code hooks by hand")

        let settingsURL = claudeSettingsURL
        let outcome: RemovalOutcome = await Task.detached {
            let installer = ClaudeCodeInstaller(settingsURL: settingsURL)
            // Read first, so "nothing of ours was there" and "we could not read
            // it" are told apart before anything is written. A file AgentBar
            // cannot parse is a file AgentBar must not rewrite — the installer's
            // own rule, and the reason this asks rather than tries.
            let report: ClaudeCodeInstallReport
            do {
                report = try installer.report(for: nil)
            } catch {
                return RemovalOutcome.failed(reason: "\(error)", remedy: remedy)
            }
            // **Only the unreadable rung short-circuits.** `notInstalled` is
            // decided by there being no AgentBar *handlers*, and the uninstall
            // removes one more thing than that: AgentBar's URL from
            // `allowedHttpHookUrls`. Handlers deleted by hand, or by a removal
            // that failed halfway, would otherwise leave that entry in a file
            // the user owns under a step reporting `Nothing there`. Letting the
            // write decide costs one read and cannot be wrong: it is a no-op
            // when there is genuinely nothing of ours left.
            if case .settingsUnreadable(let reason) = report.state {
                return .failed(reason: reason, remedy: remedy)
            }
            do {
                let done = try installer.uninstall()
                guard done.changed else { return .nothingToRemove }
                return .removed(
                    detail: Self.removedDetail(
                        backupURL: done.backupURL,
                        leftEmpty: Self.isNowAnEmptyObject(at: settingsURL)))
            } catch let error as ClaudeCodeInstallerError {
                return .failed(reason: error.description, remedy: remedy)
            } catch {
                return .failed(reason: "\(error)", remedy: remedy)
            }
        }.value
        return RemovalStep(id: "claude-hooks", title: title, location: location, outcome: outcome)
    }

    // MARK: - Codex

    private func removeCodexHooks() async -> RemovalStep {
        let home = codexHome
        let hooksURL = home.appending(path: "hooks.json")
        let title = String(localized: "Codex hooks", comment: "Removal step")
        // `CodexHookCommand.executableName` for the same reason the Claude Code
        // remedy spells its path: it is the marker `isAgentBarCommand` matches
        // on, so the instruction and the recogniser cannot drift apart.
        let remedy = String(
            localized: """
                Open \(Self.display(hooksURL)) and delete the entries whose "command" names \
                \(CodexHookCommand.executableName) — those are the only ones AgentBar wrote. \
                Leave everything else exactly as it is.
                """,
            comment: "How to remove Codex hooks by hand")

        let outcome: RemovalOutcome = await Task.detached {
            let installer = CodexInstaller(home: home)
            // Written out rather than defaulted, and only the unreadable rung
            // short-circuits — the same two rules as the Claude Code step above.
            // A `default` would let a state added to `CodexInstallState` later
            // fall silently into an uninstall attempt.
            switch installer.report(for: nil).state {
            case .hooksUnreadable(let reason):
                return RemovalOutcome.failed(reason: reason, remedy: remedy)
            case .notInstalled, .installed, .installedNotTrusted, .disabledInCodex,
                .needsRepair, .endpointUnavailable:
                break
            }
            do {
                // No Application Support directory passed: the helper is a step
                // of its own below, so that a hooks failure and a helper failure
                // are two lines rather than one, and so the hooks always come
                // out first.
                let done = try installer.uninstall()
                guard done.changed else { return .nothingToRemove }
                // No `leftEmpty`: the Codex installer removes a `hooks.json`
                // that held nothing but AgentBar's entries, backup and all.
                return .removed(detail: Self.removedDetail(backupURL: done.backupURL))
            } catch let error as CodexInstallerError {
                return .failed(reason: error.description, remedy: remedy)
            } catch {
                return .failed(reason: "\(error)", remedy: remedy)
            }
        }.value
        return RemovalStep(
            id: "codex-hooks", title: title, location: Self.display(hooksURL), outcome: outcome)
    }

    /// Codex's own record of the trust decision, which AgentBar will not touch.
    ///
    /// `config.toml` is read-only to this app on every path — it holds the
    /// `notify` slot, this machine's own hooks, and Codex's settings — so the
    /// `[hooks.state]` entries for hooks that have just been removed stay behind
    /// as orphans. They are inert: a trust record for a definition that no
    /// longer exists governs nothing. They are still AgentBar's to *report*.
    ///
    /// `hadHooks` is what stops this reporting a leftover nobody has. A user who
    /// only ever connected Claude Code still has a `config.toml`, and telling
    /// them AgentBar left a record of "the hooks you trusted" behind would be
    /// describing something that never existed.
    private func codexTrustRecord(hadHooks: Bool) -> RemovalStep {
        let configURL = codexHome.appending(path: "config.toml")
        let title = String(localized: "Codex trust record", comment: "Removal step")
        guard hadHooks, fileManager.fileExists(atPath: configURL.path(percentEncoded: false))
        else {
            return RemovalStep(
                id: "codex-trust", title: title, location: Self.display(configURL),
                outcome: .nothingToRemove)
        }
        return RemovalStep(
            id: "codex-trust",
            title: title,
            location: Self.display(configURL),
            outcome: .leftAlone(
                reason: String(
                    localized: """
                        AgentBar never writes this file, so Codex's record of the hooks you \
                        trusted stays where it is. It governs nothing once the hooks are gone.
                        """,
                    comment: "Why the Codex trust record is not removed"),
                remedy: String(
                    localized: """
                        To clear it anyway, open \(Self.display(configURL)) and delete the \
                        [hooks.state] entries whose key contains hooks.json and agentbar-helper.
                        """,
                    comment: "How to clear the Codex trust record by hand")))
    }

    private func removeCodexHelper() async -> RemovalStep {
        let title = String(localized: "Codex helper", comment: "Removal step")
        let fallback = "~/Library/Application Support/AgentBar/bin/agentbar-helper"
        // A path that could not be derived is **not** "nothing there": AgentBar
        // does not know whether a helper is left behind, and the one answer this
        // report may never give for that is the reassuring one. The same rule
        // `removeOwnedDirectory` states, applied to the step that runs first.
        guard let applicationSupport else {
            return RemovalStep(
                id: "codex-helper", title: title, location: fallback,
                outcome: .failed(
                    reason: String(
                        localized: "AgentBar could not work out where its helper lives",
                        comment: "Application Support could not be resolved"),
                    remedy: String(
                        localized: "Delete \(fallback) by hand if it is there.",
                        comment: "How to remove the Codex helper by hand")))
        }
        let helperURL = CodexHelperDeployment.destination(in: applicationSupport)
        let location = Self.display(helperURL)
        let outcome: RemovalOutcome = await Task.detached {
            let existed = FileManager.default.fileExists(
                atPath: helperURL.path(percentEncoded: false))
            do {
                let removed = try CodexHelperDeployment.removeOwnedHelper(in: applicationSupport)
                if removed { return RemovalOutcome.removed() }
                // `removeOwnedHelper` returns `false` both for "there was no
                // file" and for "that directory is not one AgentBar owns". The
                // second is unreachable while the path comes from
                // `IngestPaths`, and reporting it as an absence would be the
                // reassuring answer again — so the file is asked about directly.
                guard existed else { return .nothingToRemove }
                return .failed(
                    reason: String(
                        localized: "\(location) is not a file AgentBar recognises as its own",
                        comment: "The derived helper path failed its own ownership guard"),
                    remedy: String(
                        localized: "Delete \(location) by hand.",
                        comment: "How to remove the Codex helper by hand"))
            } catch {
                return .failed(
                    reason: "\(error)",
                    remedy: String(
                        localized: "Delete \(location) by hand.",
                        comment: "How to remove the Codex helper by hand"))
            }
        }.value
        return RemovalStep(
            id: "codex-helper", title: title, location: location, outcome: outcome)
    }
}
