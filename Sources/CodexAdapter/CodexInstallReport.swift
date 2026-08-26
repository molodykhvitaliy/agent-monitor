import Foundation

/// Why the configuration on disk is not the configuration AgentBar would write.
public enum CodexInstallDrift: Sendable, Hashable, CustomStringConvertible {
    case missingHandler(event: String)
    /// A handler on an event AgentBar no longer installs — an older version's.
    case obsoleteHandler(event: String)
    case duplicateHandler(event: String)
    /// The command names a helper somewhere other than this app bundle, which
    /// happens when the app is moved. Repairing it rewrites the definition, and
    /// rewriting the definition sends the user back to `/hooks`.
    case helperMoved(found: String, expected: String)
    /// The command names a helper that is not there at all: every hook Codex
    /// runs fails, visibly, in the user's own session.
    case helperMissing(path: String)
    case timeoutChanged(event: String, found: Int?, expected: Int)
    case matcherChanged(event: String, found: String?, expected: String?)

    public var description: String {
        switch self {
        case .missingHandler(let event): "no hook on \(event)"
        case .obsoleteHandler(let event): "a hook on \(event) that AgentBar no longer installs"
        case .duplicateHandler(let event): "more than one AgentBar hook on \(event)"
        case .helperMoved(let found, let expected):
            "the hooks run \(found); this copy of AgentBar is at \(expected)"
        case .helperMissing(let path): "the hooks run \(path), which is not there"
        case .timeoutChanged(let event, let found, let expected):
            """
            the hook on \(event) has timeout \
            \(found.map(String.init) ?? "none"), not \(expected)
            """
        case .matcherChanged(let event, let found, let expected):
            """
            the hook on \(event) matches \(found ?? "everything"), \
            not \(expected ?? "everything")
            """
        }
    }
}

/// What Codex has decided about the hooks AgentBar installed.
///
/// Trust is the difference between a configured integration and a working one,
/// and it is not AgentBar's to grant: a hook stays inert until the user reviews
/// it in `/hooks`. See ADR-0008.
public enum CodexTrustStatus: Sendable, Hashable, CustomStringConvertible {
    /// Every installed entry has a trust record, and none of them is disabled.
    case trusted
    /// At least one entry has no trust record. The ordinary state right after an
    /// install, and the one the onboarding card exists for.
    case notTrusted
    /// Trusted, and switched off by hand in `/hooks`. A different sentence from
    /// "not trusted", and one a `Trust` button cannot fix.
    case disabled
    /// `config.toml` is there and could not be read, so nothing can be said.
    /// Treated as "not trusted" everywhere a decision is made — the direction
    /// that asks the user to look rather than the one that claims silence is
    /// success.
    case unknown

    public var description: String {
        switch self {
        case .trusted:
            String(localized: "Trusted in Codex", comment: "Codex hook trust state")
        case .notTrusted:
            String(
                localized: "Run /hooks in Codex and trust the AgentBar entries",
                comment: "What to do about untrusted Codex hooks")
        case .disabled:
            String(
                localized: "The AgentBar hooks are switched off in Codex — /hooks re-enables them",
                comment: "Codex hooks are trusted but disabled")
        case .unknown:
            String(
                localized: """
                    Codex's config.toml could not be read, so trust cannot be confirmed — \
                    /hooks shows it
                    """,
                comment: "Trust state could not be determined")
        }
    }
}

/// Where the integration stands, as the panel needs to say it.
public enum CodexInstallState: Sendable, Hashable {
    case notInstalled
    /// Installed, trusted, and pointing at a live endpoint.
    case installed
    /// Installed and inert: Codex will not run these hooks until the user says
    /// so. The state the whole onboarding flow exists for.
    case installedNotTrusted(CodexTrustStatus)
    /// Installed and trusted, and then switched off in `/hooks`.
    case disabledInCodex
    /// Installed, but what is on disk is not what AgentBar would write.
    case needsRepair([CodexInstallDrift])
    /// Hooks are configured and AgentBar has no endpoint bound, so every relay
    /// posts into a refused connection.
    ///
    /// Derived from the endpoint the caller passes in, never from a probe:
    /// AgentBar originates no HTTP request, not even to itself (ADR-0002 §5.2).
    case endpointUnavailable
    /// `hooks.json` exists and could not be read, so nothing can be said about
    /// it — and nothing may be written over it either.
    case hooksUnreadable(reason: String)
}

/// Something the user should know, which is not a fault.
public enum CodexInstallWarning: Sendable, Hashable, CustomStringConvertible {
    /// `config.toml` is present and unreadable, so the trust state came from
    /// nowhere. AgentBar reports "not trusted" in this case, which may be
    /// pessimistic — and pessimistic is the only safe direction.
    case trustStateUnavailable
    /// Codex resolves `hooks.json` and `config.toml` additively, and the user
    /// has hooks in the TOML. Nothing is wrong with that; it is where a doubled
    /// notification or a competing `caffeinate` comes from.
    case hooksAlsoInConfigToml(count: Int)

    public var description: String {
        switch self {
        case .trustStateUnavailable:
            """
            Codex's config.toml could not be read, so AgentBar cannot confirm the hooks \
            are trusted
            """
        case .hooksAlsoInConfigToml(let count):
            """
            \(count) hook\(count == 1 ? "" : "s") in config.toml run alongside these; \
            AgentBar never writes that file
            """
        }
    }
}

/// Everything the install status surface needs, from one read of two files.
public struct CodexInstallReport: Sendable, Hashable {
    public let hooksURL: URL
    public let state: CodexInstallState
    /// Foreign hooks from both layers Codex resolves, `hooks.json` first.
    public let overlaps: [CodexHookOverlap]
    public let warnings: [CodexInstallWarning]

    /// Whether AgentBar has hooks in the file. `false` when the file could not
    /// be read, because then nothing is known either way.
    public var isInstalled: Bool {
        switch state {
        case .notInstalled, .hooksUnreadable: false
        case .installed, .installedNotTrusted, .disabledInCodex, .needsRepair,
            .endpointUnavailable:
            true
        }
    }

    /// The drift as one sentence: the first, and a count of the rest.
    ///
    /// Every drift case already carries a finished English sentence, so this
    /// picks and counts rather than composing. `nil` when there is no drift.
    ///
    /// > **Here rather than in the app target**, which is where it used to live
    /// > and where `swift test` could not reach it. The presentation decision it
    /// > feeds stays there: `IntegrationStatus` lives in `AgentBarUI`, which no
    /// > adapter may import.
    public var driftSummary: String? {
        guard case .needsRepair(let drift) = state, let first = drift.first else { return nil }
        return drift.count > 1
            ? "\(first.description) and \(drift.count - 1) more" : first.description
    }

    /// Whether what is on disk means **no** Codex hook can deliver.
    ///
    /// Most drift degrades the integration. These two stop it dead: the hooks
    /// name a helper that is not where Codex will look, so every one of them
    /// fails in the user's own session rather than merely posting somewhere
    /// stale.
    public var silencesEveryHandler: Bool {
        guard case .needsRepair(let drift) = state else { return false }
        return drift.contains {
            switch $0 {
            case .helperMissing, .helperMoved: true
            default: false
            }
        }
    }
}

/// What a write actually did.
public struct CodexInstallOutcome: Sendable, Hashable {
    /// `false` when the file already said what AgentBar wanted it to say. A
    /// second install writes nothing and takes no backup.
    public let changed: Bool
    public let backupURL: URL?
    /// Whether the entries AgentBar just wrote are ones Codex has never seen.
    ///
    /// True after a first install, and true again whenever a repair changed the
    /// command — because trust is keyed to the definition's hash, and a rewritten
    /// definition is a new hook as far as Codex is concerned. The card uses it to
    /// say so out loud instead of leaving the user with a silent integration.
    public let requiresTrust: Bool
    public let overlaps: [CodexHookOverlap]
    public let warnings: [CodexInstallWarning]
}
