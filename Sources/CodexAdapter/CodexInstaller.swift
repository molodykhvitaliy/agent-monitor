import AgentBarCore
import AgentBarJSON
import Foundation

public enum CodexInstallerError: Error, Sendable, Hashable, CustomStringConvertible {
    case codexDirectoryMissing(URL)
    case hooksUnreadable(String)
    case hooksNotAnObject
    case hooksShapeUnexpected(key: String)
    case backupFailed(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .codexDirectoryMissing(let url):
            "\(url.path(percentEncoded: false)) does not exist — Codex is not set up here"
        case .hooksUnreadable(let reason): "hooks.json cannot be read: \(reason)"
        case .hooksNotAnObject: "hooks.json does not contain a JSON object"
        case .hooksShapeUnexpected(let key):
            "hooks.json has a \"\(key)\" that is not the shape Codex documents"
        case .backupFailed(let reason): "the backup could not be written: \(reason)"
        case .writeFailed(let reason): "hooks.json could not be written: \(reason)"
        }
    }
}

/// Installs, inspects and removes AgentBar's hooks in `~/.codex/hooks.json`.
///
/// The same three rules the Claude Code installer holds to: the file is never
/// overwritten wholesale, never written when the content would not change, and
/// never written at all when it could not be parsed. Two more are Codex's own.
///
/// **`config.toml` is opened read-only and never written**, not for hooks and
/// not for anything else. It is where `notify` lives, where this machine's
/// `caffeine.sh` entries live, and where Codex keeps its record of what the user
/// has trusted — three reasons to read it and none to touch it.
///
/// **No secret is written.** The helper reads the endpoint's token at the moment
/// it runs, so `hooks.json` holds a path and a timeout and nothing else. The
/// consequence is worth stating: a rotated token or a moved port leaves the hook
/// definitions untouched, and so cannot invalidate the trust the user granted.
public struct CodexInstaller {
    let hooksURL: URL
    let configURL: URL
    /// Where AgentBar remembers what Codex had recorded when it last wrote —
    /// **in AgentBar's own directory**, never in `~/.codex`. `nil` disables the
    /// memory, which is what the pure merge-rule tests want and what the app
    /// never does.
    let baseline: CodexTrustBaselineFile?
    let fileManager: FileManager
    let clock: any TimeSource

    public init(
        home: URL = CodexConfigFile.defaultHome(),
        trustBaselineURL: URL? = nil,
        fileManager: FileManager = .default,
        clock: any TimeSource = SystemTimeSource()
    ) {
        hooksURL = home.appending(path: "hooks.json")
        configURL = home.appending(path: "config.toml")
        baseline = trustBaselineURL.map(CodexTrustBaselineFile.init(url:))
        self.fileManager = fileManager
        self.clock = clock
    }

    /// Forgets the baseline, because a delivery has settled the question the
    /// baseline exists to ask.
    public func clearTrustBaseline() {
        baseline?.clear(fileManager: fileManager)
    }

    public var hooksFileURL: URL { hooksURL }
    public var configFileURL: URL { configURL }

    // MARK: - Status

    /// Reads both files and says where the integration stands.
    ///
    /// `endpoint` is the helper AgentBar would install right now, or `nil` when
    /// there is none to name — that is what lets this answer "not receiving"
    /// without opening a connection to anything.
    ///
    /// `hasDelivered` is the one fact that cannot be inferred: a Codex event
    /// already arrived, so the hooks demonstrably run. It outranks the trust
    /// table, because the table's format is observed rather than documented and
    /// a delivery is proof (ADR-0008).
    ///
    /// `trustPending` is the other half of that asymmetry, and the caller is the
    /// only one who can supply it: AgentBar has rewritten a hook definition
    /// since the last delivery, so whatever Codex trusted, it did not trust
    /// *this*. Trust records are keyed by position, not by content, so a repair
    /// that changes only the command leaves a record standing that now describes
    /// a definition Codex will refuse to run.
    public func report(
        for endpoint: CodexEndpoint?, hasDelivered: Bool = false, trustPending: Bool = false
    ) -> CodexInstallReport {
        let root: JSONValue
        do {
            root = try readDocument()
        } catch let error as CodexInstallerError {
            return CodexInstallReport(
                hooksURL: hooksURL,
                state: .hooksUnreadable(reason: error.description),
                overlaps: [],
                warnings: [])
        } catch {
            return CodexInstallReport(
                hooksURL: hooksURL, state: .hooksUnreadable(reason: "\(error)"), overlaps: [],
                warnings: [])
        }

        let config = CodexConfigFile.read(at: configURL, fileManager: fileManager)
        let overlaps = CodexHooksFile.foreignHooks(in: root) + config.hooks
        let installed = CodexHooksFile.installedHooks(in: root)

        guard !installed.isEmpty else {
            return CodexInstallReport(
                hooksURL: hooksURL, state: .notInstalled, overlaps: overlaps, warnings: [])
        }

        var warnings: [CodexInstallWarning] = []
        if config.isPresent, !config.isReadable { warnings.append(.trustStateUnavailable) }
        if !config.hooks.isEmpty {
            warnings.append(.hooksAlsoInConfigToml(count: config.hooks.count))
        }

        guard let endpoint else {
            return CodexInstallReport(
                hooksURL: hooksURL, state: .endpointUnavailable, overlaps: overlaps,
                warnings: warnings)
        }

        let drift = Self.drift(between: installed, and: endpoint, exists: helperExists)
        guard drift.isEmpty else {
            return CodexInstallReport(
                hooksURL: hooksURL, state: .needsRepair(drift), overlaps: overlaps,
                warnings: warnings)
        }

        let recorded = baseline?.read(fileManager: fileManager)
        let trust = Self.trustStatus(
            of: installed, source: hooksURL, in: config, baseline: recorded)
        let state: CodexInstallState
        switch trust {
        // A delivery proves the hooks ran, whatever the trust table says or
        // fails to say. It cannot prove the opposite, which is why only this
        // direction is short-circuited.
        case _ where hasDelivered: state = .installed
        // A definition AgentBar has rewritten since the last delivery is one
        // Codex has never run. The record left at the same position still says
        // `trusted_hash`, because the key is a *position* and only the hash
        // changed — so reading it at face value would report a hook that cannot
        // run as `Connected`, the exact outcome ADR-0008 exists to forbid.
        //
        // The baseline answers this properly, and answers it in both directions:
        // a record that has *changed* since the write is consent for what is
        // there now. This flag is the fallback for the launch whose baseline
        // could not be written at all, and it is deliberately one-way.
        case _ where trustPending && recorded == nil: state = .installedNotTrusted(.notTrusted)
        case .trusted: state = .installed
        case .disabled: state = .disabledInCodex
        case .notTrusted, .unknown: state = .installedNotTrusted(trust)
        }
        return CodexInstallReport(
            hooksURL: hooksURL, state: state, overlaps: overlaps, warnings: warnings)
    }

    private func helperExists(_ path: String) -> Bool {
        fileManager.isExecutableFile(atPath: path)
    }

    // MARK: - Writing

    @discardableResult
    public func install(_ endpoint: CodexEndpoint) throws -> CodexInstallOutcome {
        try requireCodexDirectory()
        let root = try readDocument()
        let updated = CodexHooksFile.installed(root, endpoint: endpoint)
        let config = CodexConfigFile.read(at: configURL, fileManager: fileManager)

        // Read before the write, from the document as it was: whether the user
        // still owes Codex a trust decision is a question about the definitions
        // that were there, and after the write every definition is ours.
        let before = CodexHooksFile.installedHooks(in: root)
        let wasTrusted =
            Self.trustStatus(
                of: before, source: hooksURL, in: config,
                baseline: baseline?.read(fileManager: fileManager)) == .trusted
        // **Whole entries**, not just the commands. Codex hashes the definition,
        // so a changed timeout or matcher invalidates trust exactly as a changed
        // path does — and comparing only commands would miss both, because every
        // entry AgentBar writes carries the same command string.
        let definitionsChanged =
            Set(CodexHooksFile.installedHooks(in: updated)) != Set(before)

        let backup = try write(updated, ifDifferentFrom: root)
        let requiresTrust = !wasTrusted || definitionsChanged
        if requiresTrust {
            // Written after the file, and from the records as they stand *now*:
            // these are the hashes that must change before the definitions just
            // written can be called trusted. A failure to record it is survivable
            // — the caller keeps the same fact in memory for this launch — so it
            // must not fail the install that succeeded.
            try? baseline?.write(
                CodexTrustBaseline(
                    observed: Self.observedHashes(
                        of: CodexHooksFile.installedHooks(in: updated), source: hooksURL,
                        in: config)))
        }
        var warnings: [CodexInstallWarning] = []
        if config.isPresent, !config.isReadable { warnings.append(.trustStateUnavailable) }
        if !config.hooks.isEmpty {
            warnings.append(.hooksAlsoInConfigToml(count: config.hooks.count))
        }

        return CodexInstallOutcome(
            changed: backup.changed,
            backupURL: backup.backupURL,
            requiresTrust: requiresTrust,
            overlaps: CodexHooksFile.foreignHooks(in: updated) + config.hooks,
            warnings: warnings)
    }

    @discardableResult
    public func uninstall() throws -> CodexInstallOutcome {
        guard fileManager.fileExists(atPath: hooksURL.path(percentEncoded: false)) else {
            return CodexInstallOutcome(
                changed: false, backupURL: nil, requiresTrust: false, overlaps: [], warnings: [])
        }
        let root = try readDocument()
        let hadOurs = !CodexHooksFile.installedHooks(in: root).isEmpty
        let updated = CodexHooksFile.uninstalled(root)

        // A file that holds nothing but AgentBar's hooks goes with them. The
        // condition is "removing ours emptied it", so a file with anything else
        // in it — a description, somebody else's hook, an event AgentBar never
        // touched — survives untouched. A user who happened to keep an *empty*
        // `hooks.json` before AgentBar arrived loses that file here; the backup
        // taken a line below is what makes that recoverable rather than rude.
        if hadOurs, CodexHooksFile.isVacant(updated) {
            let backup = try makeBackup()
            do {
                try fileManager.removeItem(at: hooksURL)
            } catch {
                throw CodexInstallerError.writeFailed("\(error)")
            }
            pruneBackups()
            return CodexInstallOutcome(
                changed: true, backupURL: backup, requiresTrust: false, overlaps: [], warnings: [])
        }

        let backup = try write(updated, ifDifferentFrom: root)
        return CodexInstallOutcome(
            changed: backup.changed,
            backupURL: backup.backupURL,
            requiresTrust: false,
            overlaps: CodexHooksFile.foreignHooks(in: updated),
            warnings: [])
    }

    // MARK: - Comparison

    static func drift(
        between installed: [InstalledCodexHook],
        and endpoint: CodexEndpoint,
        exists: (String) -> Bool
    ) -> [CodexInstallDrift] {
        var drift: [CodexInstallDrift] = []
        let expectedPath = endpoint.helperURL.path(percentEncoded: false)
        let byEvent = Dictionary(grouping: installed, by: \.event)

        for handler in CodexHookHandler.monitoring {
            let event = handler.event.rawValue
            guard let found = byEvent[event], let first = found.first else {
                drift.append(.missingHandler(event: event))
                continue
            }
            if found.count > 1 { drift.append(.duplicateHandler(event: event)) }
            let foundPath = CodexHookCommand.helperPath(in: first.command) ?? first.command
            if foundPath != expectedPath {
                drift.append(.helperMoved(found: foundPath, expected: expectedPath))
            } else if !exists(foundPath) {
                drift.append(.helperMissing(path: foundPath))
            }
            if first.timeout != handler.timeout {
                drift.append(
                    .timeoutChanged(event: event, found: first.timeout, expected: handler.timeout))
            }
            if first.matcher != handler.matcher {
                drift.append(
                    .matcherChanged(event: event, found: first.matcher, expected: handler.matcher))
            }
        }
        let expectedEvents = Set(CodexHookHandler.monitoring.map(\.event.rawValue))
        for event in byEvent.keys.sorted() where !expectedEvents.contains(event) {
            drift.append(.obsoleteHandler(event: event))
        }
        // A moved app is one fact, not eight: eight identical lines is a status
        // surface nobody reads.
        var seen: Set<CodexInstallDrift> = []
        return drift.filter { seen.insert($0).inserted }
    }

    /// What Codex has decided about the entries in `source`.
    ///
    /// Pessimistic by construction. An entry with no record, a record AgentBar
    /// could not read, or an event it does not recognise all count against
    /// trust, because the failure this exists to prevent is an integration that
    /// says `Connected` and delivers nothing.
    static func trustStatus(
        of installed: [InstalledCodexHook],
        source: URL,
        in config: CodexConfigReading,
        baseline: CodexTrustBaseline? = nil
    ) -> CodexTrustStatus {
        guard !installed.isEmpty else { return .notTrusted }
        guard config.isReadable else { return .unknown }

        var sawDisabled = false
        for hook in installed {
            guard let key = hook.trustKey(source: source), let record = config.trust[key] else {
                return .notTrusted
            }
            guard record.trustedHash != nil else { return .notTrusted }
            // With a baseline, the record has to have *moved* since AgentBar
            // wrote: the key names a position, so an unchanged record is consent
            // for the definition that used to be there.
            if let baseline, !baseline.isSatisfied(at: key, by: record) { return .notTrusted }
            if !record.enabled { sawDisabled = true }
        }
        return sawDisabled ? .disabled : .trusted
    }

    /// The hashes recorded at AgentBar's own keys right now, for a baseline.
    static func observedHashes(
        of installed: [InstalledCodexHook], source: URL, in config: CodexConfigReading
    ) -> [String: String] {
        var observed: [String: String] = [:]
        for hook in installed {
            guard let key = hook.trustKey(source: source) else { continue }
            observed[key] = config.trust[key]?.trustedHash ?? ""
        }
        return observed
    }
}
