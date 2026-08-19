import AppKit
import Foundation
import UserNotifications
import os

/// `UNUserNotificationCenter`, behind the module's own vocabulary.
///
/// The only file here that knows the framework exists. Everything it does is
/// translation and error reporting; every decision was already made by the time
/// a `PreparedNotification` arrives.
@MainActor
public final class UserNotificationCentre: NSObject, NotificationPresenting {
    private static let logger = Logger(
        subsystem: "com.molodykhvitalii.AgentBar", category: "notifications")

    private let centre: UNUserNotificationCenter

    /// `nil` when the process is not a bundled application.
    ///
    /// `UNUserNotificationCenter.current()` **traps** in a process with no
    /// bundle identifier — a command-line build, or a test host — rather than
    /// returning an error. AgentBar always runs as a bundle, but a crash in a
    /// unit test would be a crash with no diagnosis at all, so the condition is
    /// checked rather than assumed.
    public static func ifAvailable() -> UserNotificationCentre? {
        guard Bundle.main.bundleIdentifier != nil else {
            logger.error("no bundle identifier — notifications are unavailable in this process")
            return nil
        }
        return UserNotificationCentre(centre: UNUserNotificationCenter.current())
    }

    init(centre: UNUserNotificationCenter) {
        self.centre = centre
        super.init()
    }

    /// Installs the delegate.
    ///
    /// Called from `applicationDidFinishLaunching` and nowhere else: the system
    /// may relaunch the app to deliver a response to a notification, and a
    /// delegate installed later than that misses it.
    public func installDelegate(_ delegate: UNUserNotificationCenterDelegate) {
        centre.delegate = delegate
    }

    public func registerCategories(_ identifiers: [String]) {
        // No actions, deliberately. The categories exist so Approve and Deny can
        // be added to one of them without every notification already delivered
        // being orphaned by a renamed identifier.
        let categories = identifiers.map {
            UNNotificationCategory(
                identifier: $0, actions: [], intentIdentifiers: [], options: [])
        }
        centre.setNotificationCategories(Set(categories))
    }

    public func authorizationStatus() async -> NotificationAuthorization {
        Self.translate(await centre.notificationSettings().authorizationStatus)
    }

    public func requestAuthorization() async -> NotificationAuthorization {
        do {
            // No `.badge`: an LSUIElement app has no Dock tile to badge, and
            // asking for a permission that cannot be used is noise in the
            // prompt. No `.criticalAlert` either — it needs Apple's approval.
            _ = try await centre.requestAuthorization(options: [.alert, .sound])
        } catch {
            Self.logger.error(
                "notification authorisation could not be requested: \(error, privacy: .public)")
        }
        // The status is re-read rather than inferred from the boolean: a user
        // who answered in System Settings while the prompt was up, or a
        // provisional grant, are both cases where the two disagree.
        return await authorizationStatus()
    }

    /// Posts, and returns the reason it could not.
    public func post(_ notification: PreparedNotification) async -> String? {
        let content = UNMutableNotificationContent()
        if let body = notification.body { content.body = body }
        content.categoryIdentifier = notification.categoryIdentifier
        content.threadIdentifier = notification.threadIdentifier
        content.sound = Self.sound(for: notification.sound)
        // `.timeSensitive` needs the entitlement of the same name, which needs
        // no approval from Apple. Where the entitlement is absent the system
        // treats the notification as `.active`, which is a graceful loss of a
        // privilege rather than a failure to deliver.
        content.interruptionLevel = notification.isTimeSensitive ? .timeSensitive : .active

        // The title is decided by whether a badge was actually attached, not by
        // whether one was found: the caller could only check that the file
        // exists, and the attachment can still be refused here. Without this a
        // refusal would cost the banner both its badge and the provider's name.
        let attachment = Self.attachment(at: notification.attachment)
        if let attachment { content.attachments = [attachment] }
        content.title =
            notification.attachment != nil && attachment == nil
            ? notification.titleWithoutBadge : notification.title

        // No trigger: delivered as soon as the centre will take it.
        let request = UNNotificationRequest(
            identifier: notification.identifier, content: content, trigger: nil)
        do {
            try await centre.add(request)
            return nil
        } catch {
            Self.logger.error("notification not delivered: \(error, privacy: .public)")
            return "\(error)"
        }
    }

    /// A sound object, or `nil` for silence.
    ///
    /// `UNNotificationSound(named:)` cannot fail and cannot report: it hands
    /// back an object whatever name it is given, and falls back to the default
    /// at play time if nothing resolves. That is precisely why the name reaching
    /// this point has already been checked against the filesystem — by this
    /// point there is nothing left to test.
    private static func sound(for selection: SoundSelection) -> UNNotificationSound? {
        switch selection {
        case .systemDefault: .default
        case .silent: nil
        case .named(let name): UNNotificationSound(named: UNNotificationSoundName(name))
        }
    }

    private static func attachment(at url: URL?) -> UNNotificationAttachment? {
        guard let url else { return nil }
        do {
            return try UNNotificationAttachment(identifier: "provider", url: url, options: nil)
        } catch {
            // The caller has already titled the notification for this case: the
            // provider is named in the title when no badge could be attached.
            Self.logger.error(
                "provider badge not attached: \(error, privacy: .public)")
            return nil
        }
    }

    static func translate(_ status: UNAuthorizationStatus) -> NotificationAuthorization {
        switch status {
        case .authorized: .authorized
        case .provisional: .provisional
        case .denied: .denied
        case .notDetermined: .notDetermined
        // `.ephemeral` is an App Clip state that cannot occur on macOS, and the
        // enum is not frozen. An unrecognised status is treated as "do not
        // deliver", never as permission.
        @unknown default: .denied
        }
    }
}

/// The notification centre's delegate.
///
/// Two obligations, both of which have bitten someone. `completionHandler()` is
/// **always** called, on every path, or the system stops delivering — which is
/// why these are the completion-handler forms rather than the `async` ones: the
/// guarantee is visible in the code instead of implied by a return. And a
/// response is never allowed to become a decision: AgentBar has no actions
/// today, and when Approve and Deny arrive, an unrecognised action identifier —
/// from an older notification still in Notification Center, say — must resolve
/// to nothing at all.
///
/// `nonisolated`, because the notification centre calls its delegate from its
/// own queue and neither `UNNotification` nor `UNNotificationResponse` is
/// `Sendable`. Only the identifiers cross to the main actor, and they are
/// strings.
///
/// > **The delegate is held weakly by `UNUserNotificationCenter`.** Whoever
/// > installs it has to keep it alive; a delegate that is released stops
/// > receiving responses and nothing says so.
public final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private static let logger = Logger(
        subsystem: "com.molodykhvitalii.AgentBar", category: "notifications")

    /// Called when the user opens a notification, so the app can show the panel.
    private let onOpen: @Sendable @MainActor (String) -> Void

    public init(onOpen: @escaping @Sendable @MainActor (String) -> Void) {
        self.onOpen = onOpen
        super.init()
    }

    /// Show the banner even when AgentBar is frontmost.
    ///
    /// It is frontmost only when the settings window is open, and a user
    /// adjusting the sound matrix is exactly the user who wants to see the
    /// notification they just triggered.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) ->
            Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let identifier = response.notification.request.identifier
        switch action {
        case UNNotificationDefaultActionIdentifier:
            let onOpen = self.onOpen
            Task { @MainActor in onOpen(identifier) }
        case UNNotificationDismissActionIdentifier:
            break
        default:
            // No custom action exists yet, and the reserved Approve and Deny are
            // not implemented. An action identifier arriving here therefore
            // resolves to nothing — never to a decision, and never to a
            // permission being granted.
            Self.logger.notice("notification action ignored: \(action, privacy: .public)")
        }
        // Last statement on every path, including the one that did nothing.
        completionHandler()
    }
}

/// The frontmost application, from `NSWorkspace`.
///
/// No Accessibility permission is involved: the frontmost application's bundle
/// identifier is ordinary workspace information, unlike anything about its
/// windows or its focused element.
@MainActor
public final class WorkspaceFrontmostApplication: FrontmostApplicationReading {
    public init() {}

    public func frontmostBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
