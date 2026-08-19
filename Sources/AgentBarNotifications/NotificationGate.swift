import AgentBarCore
import Foundation

/// Why a draft that was worth writing is not worth delivering.
///
/// Named cases rather than a bare `Bool`, because "AgentBar did not tell me"
/// has to be answerable. Every one of these is logged, and the two the user can
/// have caused — quiet hours and a focused application — say which.
public enum NotificationSuppression: Sendable, Hashable, CustomStringConvertible {
    /// The global switch is off.
    case notificationsOff
    /// macOS has not been asked, or was asked and said no.
    case notAuthorized
    /// This provider and event were turned off in the matrix.
    case eventDisabled
    case quietHours
    case applicationFocused(name: String)
    /// The same thing was said about the same session moments ago.
    case repeated

    public var description: String {
        switch self {
        case .notificationsOff: "notifications are turned off"
        case .notAuthorized: "macOS has not authorised notifications"
        case .eventDisabled: "this event is turned off for this provider"
        case .quietHours: "quiet hours"
        case .applicationFocused(let name): "\(name) is frontmost"
        case .repeated: "an identical notification was just delivered"
        }
    }
}

/// Everything that can stop a draft, in one pure function.
///
/// Order matters only for which reason gets reported, and it runs cheapest and
/// most global first: a user who turned notifications off should be told that,
/// not that it is half past ten.
public struct NotificationGate: Sendable {
    private let settings: NotificationSettings
    private let calendar: Calendar

    /// The settings and the calendar are held rather than passed: neither varies
    /// between two drafts in the same batch, and a function taking six arguments
    /// is one whose call sites start getting them in the wrong order.
    public init(settings: NotificationSettings, calendar: Calendar) {
        self.settings = settings
        self.calendar = calendar
    }

    public func suppression(
        for draft: NotificationDraft,
        authorization: NotificationAuthorization,
        frontmostBundleIdentifier: String?,
        now: Date
    ) -> NotificationSuppression? {
        guard settings.isEnabled else { return .notificationsOff }
        guard authorization.allowsDelivery else { return .notAuthorized }
        guard settings.preference(for: draft.provider, event: draft.event).isEnabled else {
            return .eventDisabled
        }
        if settings.quietHours.contains(now, calendar: calendar) { return .quietHours }
        if let application = settings.focusSuppression.suppresses(
            bundleIdentifier: frontmostBundleIdentifier)
        {
            return .applicationFocused(name: application.name)
        }
        return nil
    }
}

/// Collapses a burst of state moves into the notifications a person would
/// actually want.
///
/// A busy turn moves a session several times a second, and every move that
/// reaches a verb would otherwise be its own banner. Two mechanisms, and they
/// solve different problems:
///
/// * **Within the window**, only the newest draft per session survives. A
///   session that went waiting and then failed while the window was open
///   produces one notification saying it failed, which is true, rather than two
///   of which the first is already stale.
/// * **Across windows**, an identical draft for the same session — same verb,
///   same body — is dropped for `repeatWindow`. A different question is not
///   identical and is delivered, which is the case that matters: it is genuinely
///   new information.
///
/// Notifications also carry the session id as their notification identifier, so
/// the notification centre itself replaces a session's previous banner rather
/// than stacking them. That is the third mechanism and it needs no code here.
///
/// > **`drain` does not record a delivery.** The repeat window has to start when
/// > a notification is actually delivered, not when one was merely considered:
/// > a draft the gate then suppresses — quiet hours, a focused editor, a
/// > disabled cell — would otherwise begin a twenty-second window during which
/// > the same news is refused for a second reason. The caller runs the gate and
/// > then calls `recordDelivery`, so the two stages agree about what
/// > "delivered" means.
public struct NotificationCoalescer: Sendable {

    /// How long a draft waits for a better one to replace it.
    ///
    /// Long enough that a session which moves twice in quick succession — a
    /// wait answered and the turn finishing, say — announces only where it
    /// ended up, and short enough that the one signal the product exists for
    /// still feels immediate. The panel's own push coalescing is 150 ms; this is
    /// deliberately an order of magnitude longer, because a redrawn menu-bar
    /// glyph costs nothing and a banner costs the user's attention.
    ///
    /// It cannot collapse a `waiting → working` flicker, because `working`
    /// produces no draft at all and so has nothing to replace the wait with.
    /// That is correct: the agent really did stop and ask.
    public static let window: Duration = .milliseconds(1_500)

    /// How long an identical notification stays suppressed after one was
    /// delivered.
    public static let repeatWindow: Duration = .seconds(20)

    private var pending: [SessionID: NotificationDraft] = [:]
    private var delivered: [SessionID: Delivered] = [:]

    private struct Delivered: Sendable, Hashable {
        let event: NotificationEvent
        let body: String?
        /// Monotonic, not wall time. The repeat window measures an interval, and
        /// `TimeSource` keeps the two readings apart precisely so an NTP
        /// correction cannot make a twenty-second window a twenty-minute one.
        let at: MonotonicInstant
    }

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }

    /// Later drafts replace earlier ones for the same session. Ordering is by
    /// `at` rather than by arrival: the store stamps the moment it observed the
    /// change, and that is the order the user's day happened in.
    public mutating func enqueue(_ draft: NotificationDraft) {
        if let existing = pending[draft.sessionId], existing.at > draft.at { return }
        pending[draft.sessionId] = draft
    }

    /// One draft per session, oldest first, and the queue emptied.
    ///
    /// Sorted by `at` and then by session id: a dictionary has no order, and two
    /// banners appearing in a different order on two runs is the kind of
    /// difference that makes a test flake and a user distrust the app.
    public mutating func drain() -> [NotificationDraft] {
        let candidates = pending.values.sorted {
            ($0.at, $0.sessionId) < ($1.at, $1.sessionId)
        }
        pending.removeAll(keepingCapacity: true)
        return candidates
    }

    /// Whether this draft says exactly what was last delivered for its session,
    /// recently enough that saying it again would be noise.
    public func isRepeat(_ draft: NotificationDraft, now: MonotonicInstant) -> Bool {
        guard let last = delivered[draft.sessionId] else { return false }
        return last.event == draft.event && last.body == draft.body
            && now - last.at < Self.repeatWindow
    }

    /// Called after a draft has actually been delivered, which is what starts
    /// its repeat window.
    public mutating func recordDelivery(of draft: NotificationDraft, at now: MonotonicInstant) {
        delivered[draft.sessionId] = Delivered(
            event: draft.event, body: draft.body, at: now)
        forgetDeliveries(before: now)
    }

    /// A session AgentBar has not heard from in a long while is not one whose
    /// last banner still needs remembering. Without this the map grows for the
    /// life of the process.
    private mutating func forgetDeliveries(before now: MonotonicInstant) {
        delivered = delivered.filter { now - $0.value.at < Self.repeatWindow * 4 }
    }
}
