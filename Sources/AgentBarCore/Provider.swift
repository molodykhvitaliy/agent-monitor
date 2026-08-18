/// The coding agent an event came from.
///
/// This is the one place the domain names the outside world, and it names it
/// only as a label: no behaviour above the adapter layer may branch on it.
/// Display names, colours and glyphs belong to the UI.
public enum Provider: String, Sendable, Hashable, CaseIterable {
    case claudeCode
    case codex
}
