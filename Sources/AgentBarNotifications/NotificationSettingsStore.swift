import Foundation
import os

/// Where the matrix is kept between launches.
///
/// A protocol so the router can be driven from memory in a test, and so the
/// settings window has one thing to write through.
public protocol NotificationSettingsStoring: Sendable {
    func load() -> NotificationSettings
    func save(_ settings: NotificationSettings)
}

/// The real store: one JSON blob under one defaults key.
///
/// `UserDefaults` rather than a file in Application Support, for a change that
/// is small, frequent and entirely the user's: a settings window that writes on
/// every toggle should not be doing filesystem error handling, and there is
/// nothing here worth a second inspectable file on disk. The value is JSON
/// rather than a plist tree so the shape is versioned and readable in one line
/// of `defaults read`.
/// `@unchecked Sendable`: `UserDefaults` is documented as thread-safe but is
/// not annotated, so the compiler cannot see it. Nothing else here is mutable.
public final class UserDefaultsNotificationSettings: NotificationSettingsStoring,
    @unchecked Sendable
{
    private static let logger = Logger(
        subsystem: "com.molodykhvitalii.AgentBar", category: "notification-settings")

    public static let defaultsKey = "notifications.settings"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    /// Reads, and degrades to the defaults rather than to silence.
    ///
    /// A stored blob this build cannot decode is a bug or a downgrade, and in
    /// both cases the safe answer is "notify normally". Returning nothing — or
    /// an empty matrix — would turn a schema change into an app that quietly
    /// stops telling the user anything, which is the one failure mode this
    /// product cannot have.
    public func load() -> NotificationSettings {
        guard let data = defaults.data(forKey: key) else { return NotificationSettings() }
        do {
            return try JSONDecoder().decode(NotificationSettings.self, from: data).completed()
        } catch {
            Self.logger.error(
                """
                notification settings could not be read and were replaced by the \
                defaults: \(error, privacy: .public)
                """)
            return NotificationSettings()
        }
    }

    public func save(_ settings: NotificationSettings) {
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: key)
        } catch {
            // Nothing to fall back to, and nothing the user could do about it.
            // Losing a preference is survivable; hiding that it happened is not.
            Self.logger.error(
                "notification settings could not be written: \(error, privacy: .public)")
        }
    }
}

/// Holds the settings in memory. The default for tests, and for an assembly
/// that has no interest in persistence.
public final class InMemoryNotificationSettings: NotificationSettingsStoring, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<NotificationSettings>(initialState: .init())

    public init(_ settings: NotificationSettings = NotificationSettings()) {
        lock.withLock { $0 = settings }
    }

    public func load() -> NotificationSettings { lock.withLock { $0 } }
    public func save(_ settings: NotificationSettings) { lock.withLock { $0 = settings } }
}
