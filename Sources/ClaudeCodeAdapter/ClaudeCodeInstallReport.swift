import Foundation

/// Why the configuration on disk is not the configuration AgentBar would write.
public enum ClaudeCodeInstallDrift: Sendable, Hashable, CustomStringConvertible {
    case missingHandler(event: String)
    /// A handler on an event AgentBar no longer installs — an older version's.
    case obsoleteHandler(event: String)
    case duplicateHandler(event: String)
    /// The endpoint moved: the port ladder took a different port.
    case endpointChanged(found: String, expected: String)
    /// The stored token was replaced, so every hook on disk carries the old one.
    case tokenChanged
    case timeoutChanged(event: String, found: Int?, expected: Int)
    case matcherChanged(event: String, found: String?, expected: String?)
    /// `allowedHttpHookUrls` exists and does not list AgentBar's URL, so the
    /// handlers are configured and none of them will run.
    case urlNotAllowed

    public var description: String {
        switch self {
        case .missingHandler(let event): "no handler on \(event)"
        case .obsoleteHandler(let event):
            "a handler on \(event) that AgentBar no longer installs"
        case .duplicateHandler(let event): "more than one AgentBar handler on \(event)"
        case .endpointChanged(let found, let expected):
            "the handler posts to \(found); the endpoint is at \(expected)"
        case .tokenChanged: "the installed handlers carry an old token"
        case .timeoutChanged(let event, let found, let expected):
            """
            the handler on \(event) has timeout \
            \(found.map(String.init) ?? "none"), not \(expected)
            """
        case .matcherChanged(let event, let found, let expected):
            """
            the handler on \(event) matches \(found ?? "everything"), \
            not \(expected ?? "everything")
            """
        case .urlNotAllowed: "allowedHttpHookUrls does not list AgentBar's URL"
        }
    }
}

/// Where the integration stands, as the panel needs to say it.
public enum ClaudeCodeInstallState: Sendable, Hashable {
    case notInstalled
    case installed
    /// Installed, but what is on disk would not reach this endpoint.
    case needsRepair([ClaudeCodeInstallDrift])
    /// Hooks are configured and AgentBar has no endpoint bound, so every one of
    /// them is currently posting into a refused connection.
    ///
    /// Derived from the endpoint the caller passes in, never from a probe:
    /// AgentBar originates no HTTP request, not even to itself (ADR-0002 §5.2).
    case endpointUnavailable
    /// The settings file exists and could not be read, so nothing can be said
    /// about it — and nothing may be written over it either. A state rather than
    /// a thrown error because a status surface has to render every case.
    case settingsUnreadable(reason: String)
}

/// Something the user should know, which is not a fault.
public enum ClaudeCodeInstallWarning: Sendable, Hashable, CustomStringConvertible {
    /// `settings.json` is readable by other accounts on this Mac, and it now
    /// holds AgentBar's bearer token. The permission is left as it was found —
    /// tightening a file the user owns is not the installer's decision to make.
    case settingsReadableByOthers(mode: Int)
    /// An `allowedHttpHookUrls` list exists, so http hooks run only when they
    /// are on it. AgentBar added itself to the copy it can write; a list defined
    /// in a project's own settings is invisible from here and has to be extended
    /// by hand, or none of these hooks will run.
    case allowListInEffect

    public var description: String {
        switch self {
        case .settingsReadableByOthers(let mode):
            "settings.json is mode \(String(mode, radix: 8)) and now holds AgentBar's token"
        case .allowListInEffect:
            """
            allowedHttpHookUrls is in effect; a copy defined in a project's own \
            settings must list AgentBar's URL too, or its hooks will not run
            """
        }
    }
}

/// Everything the install status surface needs, from one read of one file.
public struct ClaudeCodeInstallReport: Sendable, Hashable {
    public let settingsURL: URL
    public let state: ClaudeCodeInstallState
    public let overlaps: [ForeignHookOverlap]
    public let warnings: [ClaudeCodeInstallWarning]

    /// Whether AgentBar has handlers in the file. `false` when the file could
    /// not be read, because then nothing is known either way.
    public var isInstalled: Bool {
        switch state {
        case .notInstalled, .settingsUnreadable: false
        case .installed, .needsRepair, .endpointUnavailable: true
        }
    }

    /// The drift as one sentence: the first, and a count of the rest.
    ///
    /// Every drift case already carries a finished English sentence, so this
    /// picks and counts rather than composing. `nil` when there is no drift.
    ///
    /// > **Here rather than in the app target**, which is where it used to live.
    /// > It is a statement about this provider's install report and nothing
    /// > else, and where it sat before, `swift test` could not reach it — the
    /// > app bundle has no test target. The *presentation* decision it feeds
    /// > cannot follow it here: `IntegrationStatus` lives in `AgentBarUI`, which
    /// > no adapter may import.
    public var driftSummary: String? {
        guard case .needsRepair(let drift) = state, let first = drift.first else { return nil }
        return drift.count > 1
            ? "\(first.description) and \(drift.count - 1) more" : first.description
    }

    /// Whether what is on disk means **no** event can arrive.
    ///
    /// A repairable drift usually does not: a stale token or a moved port still
    /// leaves handlers that run and are refused, which is a different fact from
    /// handlers that never run at all. `urlNotAllowed` is the exception, and the
    /// distinction decides whether an empty panel says `All quiet` or shows the
    /// onboarding card.
    public var silencesEveryHandler: Bool {
        guard case .needsRepair(let drift) = state else { return false }
        return drift.contains(.urlNotAllowed)
    }
}

/// What a write actually did.
public struct ClaudeCodeInstallOutcome: Sendable, Hashable {
    /// `false` when the file already said what AgentBar wanted it to say. A
    /// second install writes nothing and takes no backup.
    public let changed: Bool
    public let backupURL: URL?
    public let overlaps: [ForeignHookOverlap]
    public let warnings: [ClaudeCodeInstallWarning]
}
