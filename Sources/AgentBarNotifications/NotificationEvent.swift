import AgentBarCore
import Foundation

/// The four things worth interrupting someone for.
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
        case .finished: "Finished"
        case .failed: "Failed"
        }
    }

    /// One notification category per verb, registered from the first release so
    /// that these four identifiers never have to change.
    ///
    /// A category identifier is baked into every notification already delivered,
    /// so renaming one later orphans them. Registering all four now — with no
    /// actions attached — is what makes them safe to build on.
    ///
    /// > **Approve/Deny will add a category of its own, not actions to
    /// > `.waiting`.** The verb is chosen by the presence of a question line, so
    /// > `waiting` is shared by a permission prompt and by an ordinary
    /// > blocked-on-a-human event; hanging Approve and Deny on it would put
    /// > permission buttons on notifications that are not permission requests.
    /// > What step 07 guarantees is that these four keep their identifiers, not
    /// > that one of them is the right place to grow a decision.
    public var categoryIdentifier: String { "com.molodykhvitalii.AgentBar.\(rawValue)" }

    /// Whether this event asks the system to deliver at once and above a
    /// notification summary.
    ///
    /// Three of the four do: a question, a block and a failure are all "an agent
    /// has stopped and needs you", which is the single thing AgentBar exists to
    /// tell someone. `finished` is news the user can read whenever they look —
    /// marking it time-sensitive too would spend the privilege on the one event
    /// that does not need it, and teach the user to ignore the other three.
    ///
    /// `.critical` is never used anywhere: it needs Apple's approval for health
    /// and safety cases, which this is not.
    public var isTimeSensitive: Bool {
        switch self {
        case .question, .waiting, .failed: true
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
    /// When the store observed the change this came from.
    public let at: Date

    public init(
        sessionId: SessionID,
        provider: Provider,
        project: ProjectRef,
        event: NotificationEvent,
        body: String?,
        at: Date
    ) {
        self.sessionId = sessionId
        self.provider = provider
        self.project = project
        self.event = event
        self.body = body
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

    /// `{What} · {Provider} · {project}`, used only when the provider badge
    /// could not be attached.
    ///
    /// The provider is normally carried by the image. When there is no image the
    /// provider would simply be lost, and losing which agent is asking costs
    /// more than a longer title does.
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
