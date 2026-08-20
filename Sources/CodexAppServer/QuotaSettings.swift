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

    /// Ten-minutely.
    ///
    /// Half-hourly at first, on the reasoning that a weekly window moves slowly
    /// enough that a shorter interval would spend a child process to redraw the
    /// same bar. True of the bar, wrong about the person: at half an hour the
    /// only refresh anyone ever saw was a turn finishing, so the number read as
    /// something that only moved when *this* Mac spent quota — and watching the
    /// figure move is most of why the section exists. Ten minutes is four
    /// spawns an hour of a local binary.
    public static let defaultInterval: Duration = .seconds(10 * 60)

    /// The shortest interval the key can select.
    ///
    /// Every read is a network round trip made by the user's own Codex against
    /// their own account, so a tight poll is rude to a service AgentBar is a
    /// guest of. Five minutes is well inside anything that could look like
    /// automation, and still far more often than a weekly bar needs.
    public static let minimumInterval: Duration = .seconds(5 * 60)

    /// The longest interval the key can select.
    ///
    /// An interval longer than a day is not a refresh interval — it is the
    /// feature switched off with extra steps, and the honest way to switch it
    /// off is not to be signed in to Codex. The ceiling also keeps the value
    /// well inside what `Task.sleep` will ever be asked to hold: a duration a
    /// few doublings below `Int64.max` seconds is not a number any clock
    /// arithmetic should have to survive.
    public static let maximumInterval: Duration = .seconds(24 * 60 * 60)

    /// The shortest gap between two reads, whatever asked for them.
    ///
    /// Turn completions arrive in bursts — several agents finishing inside a
    /// minute is an ordinary afternoon — and without this each one would spawn
    /// its own child. The interval bounds the idle case; this bounds the busy
    /// one.
    public static let minimumSpacing: Duration = .seconds(2 * 60)

    /// The shortest gap between two reads **while the user is looking at the
    /// panel**.
    ///
    /// Shorter than `minimumSpacing` and deliberately so. The reads it governs
    /// are the ones a person asked for by opening the panel and leaving it open,
    /// which is the opposite of a background poll: they stop the moment the
    /// panel closes, and an open panel is a surface measured in seconds. A
    /// minute is short enough to watch a number move and long enough that
    /// nothing here resembles automation.
    public static let watchingSpacing: Duration = .seconds(60)

    public let interval: Duration

    public init(interval: Duration = QuotaSettings.defaultInterval) {
        self.interval = min(Self.maximumInterval, max(Self.minimumInterval, interval))
    }

    /// Reads the key, and ignores anything that is not a usable number of
    /// minutes. A hand-edited defaults value is not worth a diagnostic — the
    /// documented default is the honest fallback.
    ///
    /// The multiplication is checked for the same reason `RateLimitMapping`
    /// checks its own: an overflow is a trap rather than an error, and
    /// `defaults write … -int 9223372036854775807` would otherwise be a crash on
    /// every launch that the user has no way to connect to what they typed.
    public static func load(from defaults: UserDefaults = .standard) -> QuotaSettings {
        guard defaults.object(forKey: intervalDefaultsKey) != nil else { return QuotaSettings() }
        let minutes = defaults.integer(forKey: intervalDefaultsKey)
        guard minutes > 0 else { return QuotaSettings() }
        let (seconds, overflowed) = minutes.multipliedReportingOverflow(by: 60)
        guard !overflowed else { return QuotaSettings() }
        return QuotaSettings(interval: .seconds(seconds))
    }
}
