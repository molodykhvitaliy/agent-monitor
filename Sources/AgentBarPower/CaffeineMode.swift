/// What Caffeine is allowed to do.
///
/// Three settings rather than a switch, because "keep the Mac awake" has two
/// honest meanings and conflating them makes one of them unreachable:
/// following the agents, and simply staying awake. The default follows the
/// agents — that is the feature the product exists for — and `always` is a
/// deliberate override the indicator keeps visible.
public enum CaffeineMode: String, Sendable, Hashable, CaseIterable, Codable {
    /// AgentBar never takes an assertion. The Mac sleeps exactly as it would if
    /// AgentBar were not installed.
    case never
    /// The default: an assertion for as long as any session is `working`.
    case whileWorking
    /// An assertion for as long as AgentBar is running, whatever the sessions
    /// are doing.
    case always

    /// Whether this mode can ever produce an assertion.
    public var isActive: Bool { self != .never }
}
