import AgentBarCore
import Foundation

/// What macOS has been asked, and what it said.
public enum NotificationAuthorization: String, Sendable, Hashable, CaseIterable {
    /// Never asked. AgentBar asks once, at launch.
    case notDetermined
    case denied
    case authorized
    /// Delivered quietly, straight to Notification Center. AgentBar never
    /// requests this, but a user can arrive in it through System Settings.
    case provisional

    /// Whether posting is worth attempting.
    ///
    /// `provisional` counts: the notification is delivered, silently and without
    /// a banner, and the honest thing is to keep posting so Notification Center
    /// fills up rather than to decide on the user's behalf that quiet means no.
    public var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional: true
        case .notDetermined, .denied: false
        }
    }

    /// The sentence the settings window shows when delivery is impossible.
    public var problemDescription: String? {
        switch self {
        case .authorized, .provisional:
            nil
        case .notDetermined:
            "AgentBar has not been allowed to send notifications yet"
        case .denied:
            "Notifications are turned off for AgentBar in System Settings"
        }
    }
}

/// One notification, fully decided, in the vocabulary of this module rather than
/// of `UserNotifications`.
///
/// The seam exists so every rule above it — which verb, which sound, suppressed
/// or not, coalesced or not — is testable without an app bundle, an entitlement,
/// or a user who has to click Allow.
public struct PreparedNotification: Sendable, Hashable {
    /// The session. Reusing it as the notification identifier is what makes the
    /// notification centre **replace** a session's previous banner instead of
    /// stacking a second one beside it.
    public let identifier: String
    /// The project, so macOS groups a project's notifications together.
    public let threadIdentifier: String
    public let categoryIdentifier: String
    public let title: String
    /// The title to use if the attachment turns out not to be attachable after
    /// all. Names the provider, which the badge would otherwise have carried.
    public let titleWithoutBadge: String
    public let body: String?
    public let sound: SoundSelection
    public let isTimeSensitive: Bool
    /// A pre-rendered provider badge, or `nil` when one could not be produced —
    /// in which case `title` already names the provider instead.
    public let attachment: URL?

    public init(
        identifier: String,
        threadIdentifier: String,
        categoryIdentifier: String,
        title: String,
        titleWithoutBadge: String,
        body: String?,
        sound: SoundSelection,
        isTimeSensitive: Bool,
        attachment: URL?
    ) {
        self.identifier = identifier
        self.threadIdentifier = threadIdentifier
        self.categoryIdentifier = categoryIdentifier
        self.title = title
        self.titleWithoutBadge = titleWithoutBadge
        self.body = body
        self.sound = sound
        self.isTimeSensitive = isTimeSensitive
        self.attachment = attachment
    }
}

/// The notification centre, as this module uses it.
@MainActor
public protocol NotificationPresenting: AnyObject {
    /// Registers one category per event, with no actions attached.
    ///
    /// Registered now although nothing uses them: the reserved Approve and Deny
    /// buttons attach to a category, and a category identifier that changes
    /// later would orphan every notification already delivered under the old
    /// one.
    func registerCategories(_ identifiers: [String])
    func authorizationStatus() async -> NotificationAuthorization
    /// Asks, once. A refusal is a final answer until the user changes it in
    /// System Settings — it must never be re-asked in a loop.
    func requestAuthorization() async -> NotificationAuthorization
    /// Delivers, or says why it could not. Never throws: a notification that
    /// fails to post is a diagnostic, not a fault the caller can repair.
    func post(_ notification: PreparedNotification) async -> String?
}

/// Supplies the pre-rendered provider badge a notification carries.
///
/// A seam because the badge is drawn by `AgentBarUI`, which this module may not
/// import — and must not, since the two are siblings. `Apps/AgentBar` links both
/// and is where the image is actually produced.
@MainActor
public protocol NotificationAttachmentProviding: AnyObject {
    /// A file URL for the provider's badge image, or `nil` if none could be
    /// produced. Called on every send and expected to be cached by the
    /// implementation.
    func badgeImageURL(for provider: Provider) -> URL?
}

/// No badge, ever. The fallback path made explicit, and the default for an
/// assembly that has not wired a renderer.
public final class NoNotificationAttachments: NotificationAttachmentProviding {
    public init() {}
    public func badgeImageURL(for provider: Provider) -> URL? { nil }
}

/// Reads which application the user is looking at.
///
/// The frontmost application's bundle identifier needs **no** Accessibility
/// permission — unlike reading a window title or the focused element, which is
/// why AgentBar identifies an app and never a document. That is also why the
/// suppression list is per application rather than per project: nothing
/// available here can say which project a frontmost editor window belongs to.
@MainActor
public protocol FrontmostApplicationReading: AnyObject {
    func frontmostBundleIdentifier() -> String?
}

/// Nothing is ever frontmost. The default for tests.
public final class NoFrontmostApplication: FrontmostApplicationReading {
    public init() {}
    public func frontmostBundleIdentifier() -> String? { nil }
}

/// A notification centre that is not there.
///
/// For the one case where `UNUserNotificationCenter` cannot be reached at all —
/// a process with no bundle identifier, where asking for it would trap. The
/// settings window still opens and still writes the matrix against this, because
/// a gear that does nothing reads as a broken app rather than as an unavailable
/// capability; its permission row says notifications are not authorised, which
/// is exactly true.
public final class UnavailableNotificationCentre: NotificationPresenting {
    public init() {}
    public func registerCategories(_ identifiers: [String]) {}
    public func authorizationStatus() async -> NotificationAuthorization { .denied }
    public func requestAuthorization() async -> NotificationAuthorization { .denied }
    public func post(_ notification: PreparedNotification) async -> String? {
        "no notification centre in this process"
    }
}
