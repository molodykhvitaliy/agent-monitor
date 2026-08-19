import AgentBarCore
import Foundation

/// What the panel puts where the session list goes.
///
/// An empty list and "not installed" are different facts, and conflating them
/// turns a quiet morning into a broken app.
nonisolated public enum PanelContent: Sendable, Hashable {
    /// Sessions are running. Always this, whatever the integrations say — a
    /// user with sessions running does not need to be told to install anything,
    /// and the footer carries any degradation.
    case sessions
    /// Nothing is running and something guarantees nothing can arrive.
    case onboarding
    /// Nothing is running and everything is healthy.
    case allQuiet

    /// The precedence, first match wins. Both halves are needed: `isEmpty`
    /// answers only the first clause, and the rest lives in each provider's
    /// install report.
    public static func decide(
        snapshot: StoreSnapshot, integrations: [IntegrationStatus]
    ) -> PanelContent {
        guard snapshot.isEmpty else { return .sessions }
        guard !integrations.contains(where: \.preventsEvents) else { return .onboarding }
        return .allQuiet
    }
}

/// The footer's install-status line: one indicator, one sentence.
///
/// A problem **replaces** the count rather than appending to it. The footer has
/// room for one of the two, and the problem is the actionable half.
nonisolated public struct FooterStatus: Sendable, Hashable {
    /// The shape the indicator draws, from the same state-shape language as
    /// everything else.
    public let shape: SessionStateKind
    public let color: ColorToken
    public let text: String

    /// Several conditions can hold at once, so this is ordered and the first
    /// match wins — `docs/dev/design-spec.md` § Footer.
    ///
    /// Rule 1 comes first deliberately: a user who has installed nothing needs
    /// to be told that before being told the endpoint is not receiving events
    /// they were never going to send. Rules 2 and 3 are faults rather than
    /// warnings — a file AgentBar cannot read is not a repair it can offer.
    public static func summarise(_ integrations: [IntegrationStatus]) -> FooterStatus {
        let total = integrations.count
        let healthy = integrations.count { $0.condition.isHealthy }

        // 1 — nothing is set up at all.
        if total == 0 || integrations.allSatisfy({ $0.condition == .notConnected }) {
            return FooterStatus(
                shape: .waiting, color: .stateWaiting,
                text: String(localized: "Not connected", comment: "Footer install status"))
        }
        // 2 — configured and nothing can arrive.
        if integrations.contains(where: { $0.condition == .notReceiving }) {
            return FooterStatus(
                shape: .failed, color: .stateFailed,
                text: String(
                    localized: "Not receiving events", comment: "Footer install status"))
        }
        // 3 — a file AgentBar cannot read, which is neither of the above and
        // would otherwise deflate the connected count with no explanation.
        if integrations.contains(where: { $0.condition == .settingsUnreadable }) {
            return FooterStatus(
                shape: .failed, color: .stateFailed,
                text: String(localized: "Can't read settings", comment: "Footer install status"))
        }
        // 4 — repairable drift.
        if integrations.contains(where: { $0.condition == .needsRepair }) {
            return FooterStatus(
                shape: .waiting, color: .stateWaiting,
                text: String(localized: "Repair needed", comment: "Footer install status"))
        }
        // 5 — installed and waiting on the user's trust.
        if let untrusted = integrations.first(where: { $0.condition == .notTrusted }) {
            return FooterStatus(
                shape: .waiting, color: .stateWaiting,
                text: String(
                    localized: "\(untrusted.provider.displayName) not trusted",
                    comment: "Footer install status naming a provider"))
        }
        // 6 — one provider of several is not set up. With a single integration
        // rule 1 has already covered it.
        if let missing = integrations.first(where: { $0.condition == .notConnected }) {
            return FooterStatus(
                shape: .waiting, color: .stateWaiting,
                text: String(
                    localized: "\(missing.provider.displayName) not connected",
                    comment: "Footer install status naming a provider"))
        }
        // 7 — healthy. Both numbers come from the integrations the assembly
        // actually registers, never from a constant: a hardcoded denominator
        // would show a permanent `1 of 2` and report an unbuilt feature as a
        // broken install.
        return FooterStatus(
            shape: .working, color: .connected,
            text: String(
                localized: "\(healthy) of \(total) connected", comment: "Footer install status"))
    }
}

/// The status item's accessibility label — a full sentence, recomputed on every
/// state change, because VoiceOver gets nothing from the silhouette.
nonisolated public enum StatusItemLabel {
    /// The project is named only when exactly one session is in the leading
    /// state; otherwise the count carries it.
    public static func describe(_ snapshot: StoreSnapshot) -> String {
        guard let leading = snapshot.mostUrgentState else {
            return String(
                localized: "AgentBar: nothing running",
                comment: "Menu-bar accessibility label when no sessions exist")
        }
        let matching = snapshot.sessions.filter { $0.state.kind == leading }
        let verb = leading.progressiveLabel
        guard matching.count == 1, let only = matching.first else {
            return String(
                localized: "AgentBar: \(matching.count) sessions \(verb)",
                comment: "Menu-bar accessibility label, several sessions in one state")
        }
        let project = ProjectLabels(projects: snapshot.projects.map(\.project))
            .label(for: only.project)
        return String(
            localized: "AgentBar: 1 session \(verb) in \(project)",
            comment: "Menu-bar accessibility label, one session in the leading state")
    }
}

nonisolated extension SessionStateKind {
    /// The verb form the accessibility sentence needs: "1 session **waiting**".
    var progressiveLabel: String {
        switch self {
        case .idle: String(localized: "idle", comment: "Session state, in a sentence")
        case .working: String(localized: "working", comment: "Session state, in a sentence")
        case .waiting: String(localized: "waiting", comment: "Session state, in a sentence")
        case .failed: String(localized: "failed", comment: "Session state, in a sentence")
        case .unknown: String(localized: "unknown", comment: "Session state, in a sentence")
        }
    }
}
