// ClaudeCodeAdapter
//
// Claude Code's hook payloads and the `~/.claude/settings.json` installer. Raw
// Claude Code JSON does not leave this module: `ClaudeCodeEventDecoder` is the
// only way in, and it hands back `AgentEvent`.
//
// The module depends on AgentBarIngest as well as AgentBarCore, which is the one
// place the dependency graph points at the transport instead of only inward.
// `EventDecoding` is the seam the ingest layer publishes for exactly this, and
// implementing it where the payload knowledge already lives is what keeps the
// stronger invariant — that provider JSON stops at the adapter — true without a
// bridge in the app target that nothing tests.
