import Foundation
import os

/// What the user chose, and what the footer's toggle restores.
///
/// `activeMode` exists because the indicator is a two-state button over a
/// three-state setting: turning Caffeine off and on again must not silently
/// demote `always` to `whileWorking`. It is never `never` — that is what
/// `mode` is for — and the initialiser enforces it, so a hand-edited defaults
/// value cannot produce a toggle that turns nothing on.
public struct CaffeineSettings: Sendable, Hashable, Codable {
    public private(set) var mode: CaffeineMode
    /// The mode `toggle()` comes back to. Always an active mode.
    public private(set) var activeMode: CaffeineMode

    public init(mode: CaffeineMode = .whileWorking, activeMode: CaffeineMode = .whileWorking) {
        self.mode = mode
        // An inactive `activeMode` would make the toggle a no-op switch that
        // never turns anything on. Prefer the mode itself when it is active,
        // which is also what makes `CaffeineSettings(mode: .always)` behave.
        self.activeMode = activeMode.isActive ? activeMode : (mode.isActive ? mode : .whileWorking)
    }

    public mutating func setMode(_ mode: CaffeineMode) {
        self.mode = mode
        if mode.isActive { activeMode = mode }
    }

    /// The footer button: off, or back to whatever the settings window last
    /// chose.
    public mutating func toggle() {
        setMode(mode.isActive ? .never : activeMode)
    }

    /// Decoded through the designated initialiser rather than by assigning the
    /// stored properties.
    ///
    /// The synthesised conformance would skip the repair above, so a stored
    /// `{"mode":"never","activeMode":"never"}` — a downgrade, a hand-edited
    /// defaults entry, a bug in a build that no longer exists — would survive a
    /// relaunch and leave the footer button a dead switch: `toggle()` would set
    /// `never` to `never` for ever, recoverable only through the settings
    /// window. An invariant that only the memberwise initialiser enforces is not
    /// an invariant.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try container.decode(CaffeineMode.self, forKey: .mode),
            activeMode: try container.decode(CaffeineMode.self, forKey: .activeMode))
    }
}

/// Where the choice is kept between launches.
///
/// A protocol so the controller can be driven from memory in a test, exactly as
/// `NotificationSettingsStoring` is.
public protocol CaffeineSettingsStoring: Sendable {
    func load() -> CaffeineSettings
    func save(_ settings: CaffeineSettings)
}

/// The real store: one JSON blob under one defaults key.
///
/// `UserDefaults` for the same reason the notification matrix uses it — the
/// value is small, changes only when the user says so, and is not worth a
/// second inspectable file on disk.
///
/// `@unchecked Sendable`: `UserDefaults` is documented as thread-safe but is
/// not annotated, so the compiler cannot see it. Nothing else here is mutable.
public final class UserDefaultsCaffeineSettings: CaffeineSettingsStoring, @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "com.molodykhvitalii.AgentBar", category: "caffeine")

    public static let defaultsKey = "caffeine.settings"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    /// Reads, and degrades to the defaults rather than to `never`.
    ///
    /// A stored blob this build cannot decode is a bug or a downgrade. Falling
    /// back to "follow the agents" restores the documented behaviour; falling
    /// back to `never` would leave a user whose Mac has stopped staying awake
    /// with nothing anywhere saying why.
    public func load() -> CaffeineSettings {
        guard let data = defaults.data(forKey: key) else { return CaffeineSettings() }
        do {
            return try JSONDecoder().decode(CaffeineSettings.self, from: data)
        } catch {
            Self.logger.error(
                """
                caffeine settings could not be read and were replaced by the \
                defaults: \(error, privacy: .public)
                """)
            return CaffeineSettings()
        }
    }

    public func save(_ settings: CaffeineSettings) {
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: key)
        } catch {
            // Nothing to fall back to, and nothing the user could do about it.
            // Losing a preference is survivable; hiding that it happened is not.
            Self.logger.error("caffeine settings could not be written: \(error, privacy: .public)")
        }
    }
}

/// Holds the choice in memory. The default for tests, and for an assembly with
/// no interest in persistence.
public final class InMemoryCaffeineSettings: CaffeineSettingsStoring, @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<CaffeineSettings>

    public init(_ settings: CaffeineSettings = CaffeineSettings()) {
        state = OSAllocatedUnfairLock(initialState: settings)
    }

    public func load() -> CaffeineSettings { state.withLock { $0 } }

    public func save(_ settings: CaffeineSettings) { state.withLock { $0 = settings } }
}
