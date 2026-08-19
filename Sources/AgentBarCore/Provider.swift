/// The coding agent an event came from.
///
/// This is the one place the domain names the outside world, and it names it
/// only as a label: no behaviour above the adapter layer may branch on it.
/// Colours and glyphs belong to the UI.
public enum Provider: String, Sendable, Hashable, CaseIterable {
    case claudeCode
    case codex

    /// The provider's own name, spelled the one way AgentBar spells it: never
    /// "OpenAI Codex", never abbreviated, **never localised**.
    ///
    /// A fixed term of the interface rather than a display decision, which is
    /// why it sits beside the case it names instead of in a presentation layer.
    /// Two independent surfaces need it — the panel and a notification title —
    /// and `AgentBarUI` and `AgentBarNotifications` may not import each other,
    /// so the alternative is the same string written twice and one copy drifting
    /// to "OpenAI Codex". `docs/dev/design-spec.md` § Vocabulary fixes the value.
    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}
