import AgentBarCore
import Foundation

/// Where one provider's integration stands, in vocabulary the UI owns.
///
/// `AgentBarUI` may import only `AgentBarCore`, so it cannot hold a
/// `ClaudeCodeInstallReport` — `ModuleBoundaryTests` fails the build if it
/// tries, and CLAUDE.md's rule that nothing above the adapter knows the
/// providers exist says the same thing from the other direction.
///
/// So the type is **declared here and populated by the app target**, which is
/// already the assembly point and already links every module. The switch over a
/// provider's own install states lives next to that provider's installer. This
/// also lets a preview or a test build a status directly, which matters because
/// `ClaudeCodeInstallReport` has no public initialiser.
nonisolated public struct IntegrationStatus: Sendable, Hashable, Identifiable {
    public let provider: Provider
    public let condition: IntegrationCondition
    /// The second line: a drift's own sentence, an error's own text, or the
    /// reason a settings file could not be read. Already a finished English
    /// sentence — the card renders it and formats nothing itself.
    public let detail: String?
    /// Things the user should know that are not faults, rendered as muted `ⓘ`
    /// lines beneath the provider's row.
    public let notes: [String]
    /// Foreign hooks installed on the same events. Informational, and offered
    /// no action: AgentBar does not touch a foreign entry.
    public let coexistence: CoexistenceSummary
    /// Whether this integration is in a state that guarantees **no event can
    /// arrive**. Decides the onboarding card, which must not appear merely
    /// because a repairable drift exists — but must appear when the drift is one
    /// that silences every handler.
    public let preventsEvents: Bool

    public init(
        provider: Provider,
        condition: IntegrationCondition,
        detail: String? = nil,
        notes: [String] = [],
        coexistence: CoexistenceSummary = CoexistenceSummary(),
        preventsEvents: Bool? = nil
    ) {
        self.provider = provider
        self.condition = condition
        self.detail = detail
        self.notes = notes
        self.coexistence = coexistence
        self.preventsEvents = preventsEvents ?? condition.preventsEventsByDefault
    }

    public var id: Provider { provider }
}

/// The states a provider's integration can be in, as the panel has to say them.
///
/// One case per rung of the footer's condition table and per row of the
/// integration card, so both surfaces read the same fact rather than each
/// re-deriving it.
nonisolated public enum IntegrationCondition: String, Sendable, Hashable, CaseIterable {
    /// Nothing of AgentBar's is in the provider's configuration.
    case notConnected
    /// Configured, and AgentBar has no endpoint bound — every handler is posting
    /// into a refused connection.
    case notReceiving
    /// The configuration file exists and could not be read. Neither a repair nor
    /// a write may be offered: AgentBar refuses to write over a file it could
    /// not read.
    case settingsUnreadable
    /// Configured, but what is on disk would not reach this endpoint.
    case needsRepair
    /// Configured, and the provider will not run it until the user says so.
    case notTrusted
    case connected

    /// Whether a provider in this state can deliver anything at all.
    var preventsEventsByDefault: Bool { self != .connected }

    /// Counts towards the footer's `N of N connected`.
    var isHealthy: Bool { self == .connected }
}

/// What the coexistence line reports: foreign hooks on events AgentBar watches.
///
/// "Detect and report, change nothing" made visible. A family with no members is
/// simply absent from the line.
nonisolated public struct CoexistenceSummary: Sendable, Hashable {
    public let notifiers: Int
    public let keepAwake: Int
    public let others: Int
    /// One line per foreign handler, revealed on click.
    public let entries: [String]

    public init(notifiers: Int = 0, keepAwake: Int = 0, others: Int = 0, entries: [String] = []) {
        self.notifiers = notifiers
        self.keepAwake = keepAwake
        self.others = others
        self.entries = entries
    }

    public var isEmpty: Bool { notifiers == 0 && keepAwake == 0 && others == 0 }

    /// `2 notifiers, 1 keep-awake, 3 others`.
    public var summary: String {
        var parts: [String] = []
        if notifiers > 0 { parts.append(Self.count(notifiers, "notifier", "notifiers")) }
        if keepAwake > 0 { parts.append(Self.count(keepAwake, "keep-awake", "keep-awakes")) }
        if others > 0 { parts.append(Self.count(others, "other", "others")) }
        return parts.joined(separator: ", ")
    }

    private static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
    }
}

/// What a provider row's button does, named at the level the UI understands.
///
/// The case comes back to the app target, which knows which installer to call.
nonisolated public enum IntegrationAction: String, Sendable, Hashable {
    case connect
    case repair
    case trust
    case retry
    case revealInFinder
}

/// What a write left behind. All three outcomes need a face, and a no-op must
/// not look like a failure.
nonisolated public enum IntegrationActionResult: Sendable, Hashable {
    /// The configuration changed; the row takes whatever its next report says.
    case changed
    /// A write ran and the file already said what AgentBar wanted. This is the
    /// only case that earns `Nothing to change`.
    case unchanged
    /// The action did not attempt a write and has nothing to report — revealing
    /// a file in Finder, or an action that does not apply to this provider.
    ///
    /// Distinct from `unchanged` on purpose: `Nothing to change` explains a
    /// no-op *write*, and putting it under a row that has just refused to write
    /// anything would claim AgentBar had tried.
    case acknowledged
    /// The write threw. The row keeps its previous state, gains this text as a
    /// second line, and keeps its action available.
    case failed(String)
}

nonisolated extension IntegrationCondition {
    /// The action offered on this rung, or `nil` when none is.
    ///
    /// `settingsUnreadable` gets no write action of any kind — only a way to go
    /// look at the file.
    public var action: IntegrationAction? {
        switch self {
        case .notConnected: .connect
        case .needsRepair: .repair
        case .notTrusted: .trust
        case .notReceiving: .retry
        case .settingsUnreadable: .revealInFinder
        case .connected: nil
        }
    }

    /// The card row's status line.
    public var statusLine: String {
        switch self {
        case .notConnected:
            String(localized: "Not connected", comment: "Integration status")
        case .notReceiving:
            String(localized: "Installed, not receiving", comment: "Integration status")
        case .settingsUnreadable:
            // Provider-neutral: the Codex row reaches this rung too, and Codex
            // has no `settings.json`. Which file it was is already on the second
            // line, in the report's own words.
            String(localized: "Can't read its configuration", comment: "Integration status")
        case .needsRepair:
            String(localized: "Needs repair", comment: "Integration status")
        case .notTrusted:
            String(localized: "Installed, not trusted", comment: "Integration status")
        case .connected:
            String(localized: "Connected", comment: "Integration status")
        }
    }

    /// The shape and colour the status line takes. Every accent is paired with
    /// a silhouette, here as everywhere.
    public var indicator: (kind: SessionStateKind, color: ColorToken)? {
        switch self {
        case .connected: (.working, .connected)
        case .notTrusted, .needsRepair: (.waiting, .stateWaiting)
        case .settingsUnreadable: (.failed, .stateFailed)
        case .notReceiving: (.failed, .stateFailed)
        case .notConnected: nil
        }
    }
}

nonisolated extension IntegrationAction {
    public var label: String {
        switch self {
        case .connect: String(localized: "Connect", comment: "Button")
        case .repair: String(localized: "Repair", comment: "Button")
        case .trust: String(localized: "Trust", comment: "Button")
        case .retry: String(localized: "Retry", comment: "Button")
        case .revealInFinder: String(localized: "Reveal in Finder", comment: "Button")
        }
    }

    /// Whether the button is filled rather than quiet. Only the two actions that
    /// are the whole point of the card are.
    public var isProminent: Bool { self == .connect || self == .trust }

    var fill: ColorToken {
        self == .trust ? .stateWaiting : .stateWorking
    }
}
