// CodexAdapter
//
// Codex's hook payloads, the `~/.codex/hooks.json` installer, the trust reading
// that says whether any of it will actually run, and the relay `agentbar-helper`
// is a thin entry point over. Raw Codex JSON does not leave this module:
// `CodexEventDecoder` is the only way in, and it hands back `AgentEvent`.
//
// Three constraints shape everything here, and each one is a rule rather than a
// preference.
//
// **`~/.codex/config.toml` is never written.** Codex resolves hooks from both
// that file and `hooks.json`, additively, and the TOML is where the user keeps
// `notify` — already occupied by Codex Computer Use on the developer's machine —
// along with comments a rewrite would lose. It is read, and only for the two
// tables that decide what AgentBar has to report: `[hooks.state]`, which records
// trust, and `[hooks]`, which is where this machine's existing `caffeine.sh`
// entries live.
//
// **Trust is Codex's to grant.** A hook is inert until the user reviews it in
// `/hooks`, and trust is keyed to a hash of the hook definition. Codex documents
// a flag that skips the review; AgentBar never passes it, never writes it into a
// configuration and never suggests it — the flag is named once, in ADR-0008,
// along with the reasoning. AgentBar detects the state and explains it; it never
// works around it.
//
// **The helper is a dumb pipe.** It reads one JSON object from stdin and relays
// the bytes unread to the loopback endpoint; every interpretation happens in the
// app, on the far side of the socket. That is why the relay can afford to be as
// small as it is, and why it is the only part of AgentBar that has to finish
// inside a millisecond budget somebody else set.
