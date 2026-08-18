// AgentBarIngest
//
// The local endpoint both providers deliver events to: a loopback HTTP listener
// and a Unix socket for the Codex helper, bearer-token authentication, and the
// boundary where a request becomes an `AgentEvent`.
//
// Two properties hold the whole module together.
//
// **Nothing here reaches a remote host.** The only address bound is 127.0.0.1
// and the only client that exists is a process on this machine. ADR-0002 rests
// on that staying literally true, so the address is a constant rather than a
// setting, and `Tests/ArchitectureTests` is where a remote client would be
// caught arriving.
//
// **No failure path answers with an opinion.** A malformed body, a decoder that
// refuses, a handler that overruns its deadline — every one of them ends in
// 200 with an empty body, which Claude Code reads as "the hook had nothing to
// say" and continues. `IngestStatus` has no 5xx case at all, because an agent's
// tool call is not the place to report our own bugs.
