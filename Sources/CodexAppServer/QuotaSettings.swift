import Foundation

/// How often the limits are re-read, and the floor under it.
///
/// **Configurable through a defaults key rather than a settings control.** The
/// design brief makes restraint an explicit product requirement and enumerates
/// what the settings window contains; a polling interval is not on that list,
/// and a control for it would be the first element in the app that exists
/// because it was easy rather than because it earns its place. The key is here
/// for the user whose account is metered differently than ours, and it is
/// documented in `docs/dev/architecture.md`.
public struct QuotaSettings: Sendable, Hashable {
    /// `defaults write com.molodykhvitalii.AgentBar codex.limitsRefreshMinutes -int 60`
    public static let intervalDefaultsKey = "codex.limitsRefreshMinutes"

    /// Half-hourly. A weekly window moves slowly enough that a shorter interval
    /// would spend a child process to redraw the same bar.
    public static let defaultInterval: Duration = .seconds(30 * 60)

    /// The shortest interval the key can select.
    ///
    /// Every read is a network round trip made by the user's own Codex against
    /// their own account, so a tight poll is rude to a service AgentBar is a
    /// guest of. Five minutes is well inside anything that could look like
    /// automation, and still far more often than a weekly bar needs.
    public static let minimumInterval: Duration = .seconds(5 * 60)

    /// The shortest gap between two reads, whatever asked for them.
    ///
    /// Turn completions arrive in bursts — several agents finishing inside a
    /// minute is an ordinary afternoon — and without this each one would spawn
    /// its own child. The interval bounds the idle case; this bounds the busy
    /// one.
    public static let minimumSpacing: Duration = .seconds(2 * 60)

    public let interval: Duration

    public init(interval: Duration = QuotaSettings.defaultInterval) {
        self.interval = max(Self.minimumInterval, interval)
    }

    /// Reads the key, and ignores anything that is not a usable number of
    /// minutes. A hand-edited defaults value is not worth a diagnostic — the
    /// documented default is the honest fallback.
    public static func load(from defaults: UserDefaults = .standard) -> QuotaSettings {
        guard defaults.object(forKey: intervalDefaultsKey) != nil else { return QuotaSettings() }
        let minutes = defaults.integer(forKey: intervalDefaultsKey)
        guard minutes > 0 else { return QuotaSettings() }
        return QuotaSettings(interval: .seconds(minutes * 60))
    }
}
