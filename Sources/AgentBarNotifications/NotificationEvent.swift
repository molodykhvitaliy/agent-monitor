import AgentBarCore
import Foundation

/// The five things worth notifying someone about.
///
/// A separate, smaller vocabulary from `SessionStateKind`: these name an
/// **event**, not a state, which is why `finished` may appear here while the
/// five state words have no sixth. Fixed by `docs/dev/design-spec.md`
/// § Notifications, where each is also given the predicate that selects it.
///
/// Each verb is the first word of its title, so a banner truncated at about
/// thirty characters still delivers the meaning.
public enum NotificationEvent: String, Sendable, Hashable, CaseIterable, Codable {
    /// An agent asked a specific question, and the question line came with it.
    case question
    /// An agent is waiting for an approval in its own interface.
    case approval
    /// An agent is blocked on a person with nothing more to say about it.
    case waiting
    /// A turn ended normally.
    case finished
    /// A turn died.
    case failed

    /// The title's first word. Never localised for the same reason
    /// `Provider.displayName` is not: it is a fixed term of the interface.
    public var verb: String {
        switch self {
        case .question: "Question"
        case .waiting: "Waiting"
        case .approval: "Approval"
        case .finished: "Finished"
        case .failed: "Failed"
        }
    }

    /// One notification category per verb.
    ///
    /// A category identifier is baked into every notification already delivered,
    /// so renaming one later orphans them. Registering all five now — with no
    /// actions attached — is what makes them safe to build on.
    ///
    /// `approval` deliberately has no actions. A later Approve/Deny feature can
    /// add them without putting permission buttons on an ordinary `.waiting`
    /// notification, and without treating this monitor's observation id as a
    /// decision handle.
    public var categoryIdentifier: String { "com.molodykhvitalii.AgentBar.\(rawValue)" }

    /// Whether this event asks the system to deliver at once and above a
    /// notification summary.
    ///
    /// Four of the five do: a question, an approval, a block and a failure are
    /// all "an agent has stopped and needs you", which is the single thing
    /// AgentBar exists to tell someone. `finished` is news the user can read whenever they look —
    /// marking it time-sensitive too would spend the privilege on the one event
    /// that does not need it, and teach the user to ignore the other four.
    ///
    /// `.critical` is never used anywhere: it needs Apple's approval for health
    /// and safety cases, which this is not.
    public var isTimeSensitive: Bool {
        switch self {
        case .question, .waiting, .approval, .failed: true
        case .finished: false
        }
    }
}

/// One notification, decided but not yet rendered.
///
/// The seam between the pure half of this module — which verb, which body,
/// suppressed or not — and the half that talks to `UNUserNotificationCenter`.
/// Everything above is testable without a notification centre, an entitlement
/// or a user.
public struct NotificationDraft: Sendable, Hashable {
    public let sessionId: SessionID
    public let provider: Provider
    public let project: ProjectRef
    public let event: NotificationEvent
    /// The one relevant detail line, already clamped, or `nil` when the title is
    /// the whole message.
    public let body: String?
    /// Opaque state identity used only to distinguish otherwise identical
    /// notifications. Permission observations set this to their local request
    /// id so two approvals with the same summary remain separate news.
    public let fingerprint: String?
    /// When the store observed the change this came from.
    public let at: Date

    public init(
        sessionId: SessionID,
        provider: Provider,
        project: ProjectRef,
        event: NotificationEvent,
        body: String?,
        fingerprint: String? = nil,
        at: Date
    ) {
        self.sessionId = sessionId
        self.provider = provider
        self.project = project
        self.event = event
        self.body = body
        self.fingerprint = fingerprint
        self.at = at
    }

    /// `{What} · {project}` — what needs me, then where.
    ///
    /// The project is the bare `ProjectRef.name`, never the panel's
    /// disambiguated label: a notification is emitted per event and has no view
    /// of what else is on screen, so the panel's collision rule is not available
    /// to it. Two worktrees of one repository therefore produce two identically
    /// titled notifications; the panel is one click away and disambiguates.
    public var title: String {
        "\(event.verb)\(NotificationDraft.separator)\(project.name)"
    }

    /// The banner's second line: which agent this is from.
    ///
    /// > **The provider, and nothing else.** The design asks for a session
    /// > ordinal — `Claude Code · session 2` — when several sessions are
    /// > running, and there is no honest source for one here. A draft names one
    /// > session; the router sees a stream of changes and holds no register of
    /// > what is live, and the store that does is on the other side of a module
    /// > boundary that exists precisely so a notification cannot reach into it.
    /// > A number invented for a banner is the failure mode `NotificationPolicy`
    /// > already refuses in `3 files changed`, so this says the true half and
    /// > stops.
    public var subtitle: String { provider.displayName }

    /// `{What} · {Provider} · {project}`, used only when the art could not be
    /// attached.
    ///
    /// Kept as a safety net rather than removed now that `subtitle` names the
    /// provider unconditionally. `subtitle` is a slot the system may truncate or
    /// drop before the title — an alert-style notification lays out differently
    /// from a banner — and losing which agent is asking costs more than a
    /// repeated word does in the rare path where no art was attached.
    public var titleNamingProvider: String {
        [event.verb, provider.displayName, project.name]
            .joined(separator: NotificationDraft.separator)
    }

    /// U+00B7 with ordinary spaces, from one constant so it cannot drift into a
    /// hyphen. The panel holds its own copy for the same reason; they are
    /// deliberately not shared, because `AgentBarUI` and this module may not
    /// import each other.
    static let separator = " · "
}
