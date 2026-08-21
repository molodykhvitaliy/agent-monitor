---
id: ADR-0013
title: The Codex helper waits on a deadline, and drops what does not arrive
status: accepted
date: 2026-08-20
supersedes: null
superseded_by: null
tags: [codex, helper, process, safe-superset]
---

## Context

`agentbar-helper` is the one binary an agent spawns on AgentBar's behalf, and it
is spawned on **every tool call**. Codex runs a `command` hook through a shell,
with the session's `cwd` as the working directory, and writes the hook payload
into the process's standard input.

The helper read that input to end of file in a loop with no deadline of any
kind. Every other wait in the project is bounded — the relay carries a 500 ms
total, the endpoint's connections carry an idle timeout, the App Server exchange
carries a budget — and this one was not, because "read until the writer closes"
does not look like a wait at all.

It is one. Measured on 2026-08-20: a writer that held the pipe open held the
shipped helper open for exactly as long, with no upper bound. And the helper is
a grandchild of Codex behind the shell that runs it, so a helper that outlives
its agent is reparented to `launchd` and keeps the session's repository as its
working directory. One per tool call, for as long as the day lasts. The product
owner's report — around fifty orphaned shells rooted in the project directories,
saturating the CPU between them — is that shape exactly.

Whether Codex kills a `command` hook that overruns its `timeout` is not
documented, and this decision deliberately does not depend on the answer. A
process AgentBar spawns has to be bounded by AgentBar.

## Decision drivers

- **The safe superset.** If AgentBar is not running, crashed or uninstalled,
  both tools must behave exactly as if it never existed. A process left behind in
  the user's repository is the loudest possible violation of that.
- Draining to EOF exists for a reason and the reason still holds: a reader that
  leaves early hands the writer `EPIPE`, which is a visible effect on the agent.
- Codex caps a `SessionEnd` hook at **one second** and runs it synchronously
  whatever `async` says, so whatever bound is chosen has to fit inside a budget
  the helper shares with the relay.
- A truncated payload is worth less than nothing: the endpoint refuses it and
  records a diagnostic naming AgentBar's own helper as the source.

## Considered options

1. **Leave it unbounded and rely on Codex's hook timeout.** Undocumented, and it
   would make the guarantee somebody else's to keep.
2. **A per-syscall timeout.** Does not compose: a writer trickling one byte at a
   time restarts the clock on every chunk and holds the helper indefinitely — the
   trap `RelayTimeouts` already documents for the socket path.
3. **One deadline over the whole drain**, enforced by `poll` before every read.
4. **A quiet period plus a ceiling**: give up after the writer has said nothing
   for a short while, and never run longer than a hard bound whatever it does.

## Decision

**Option 4.** 150 ms of silence, 400 ms in total, `poll` before every read, and
what has not arrived by then is **dropped rather than waited for**.

Option 3 was written first and measured second, which is how it was rejected. A
total budget conflates "the writer stopped" with "the payload is large", and the
worst legitimate payload is larger than it looks: a `PostToolUse` carrying the
endpoint's whole 4 MB limit through a 64 KB pipe takes about a millisecond on an
idle machine and **93–105 ms** with this repository's suite running in parallel.
A 250 ms total was therefore within 2.5× of dropping a real event on a busy Mac,
and the fix — a larger total — would have spent most of the agent's own budget to
buy it.

Measuring **silence** makes the payload's size irrelevant: a writer that is
writing never goes quiet, however long it takes, so the bound tightens rather
than loosens as it gets closer to what it is really detecting. The ceiling is
what keeps that from being unbounded again — a trickle resets the quiet period
for ever — and it is chosen against the whole helper run: 400 ms here plus the
relay's 500 ms is 900 ms, inside the one second Codex gives a `SessionEnd` hook.

**The first byte is exempt from the quiet period**, and the exemption is what
makes the quiet period safe rather than an optimisation on top of it. "The writer
has gone quiet" is not a statement anybody can make about a writer that has not
started, and the gap between this process being spawned and Codex writing into
the pipe belongs to Codex and to how busy the Mac is. Until something arrives the
ceiling is the only bound. Without this the quiet period governs that gap, which
is the version that failed under nothing worse than this repository's own suite
running in parallel.

Everything that is not a clean end of file is a **fragment**, and a fragment is
never relayed. `StandardInput.DrainOutcome` names the three endings —
`complete`, `expired`, `failed(code:)` — because a bound that expired and a read
that failed are different faults and used to be indistinguishable from success.

## Consequences

- The helper cannot outlive its agent. The one unbounded wait in the project is
  gone, and it is the one in the process that gets spawned most often.
- **A payload that goes quiet mid-flight, or trickles past the ceiling, is
  lost**, and the event with it. That is the price, and it is the right way round: a lost heartbeat costs a
  session that reads as quiet for a few seconds until the next event, where a
  hung helper costs a process that never leaves. Both agents remain unaffected —
  the exit code is still `0`, both streams are still empty.
- **Codex may see `EPIPE` on that path**, which the safe-superset rule otherwise
  forbids. It is accepted only here, and only once a writer has said nothing for
  150 ms or dribbled for 400 — at which point the alternative is not "no visible
  effect" but "a process in the user's repository for ever".
- A dropped payload now reaches `os_log`, so the failure is discoverable in
  Console rather than only through an environment variable nobody sets. Neither
  stream Codex reads is touched.
- A quieter bug went with it: `EAGAIN` on a descriptor somebody else left
  non-blocking used to read as end of input, which dropped the payload in
  silence.

## References

- [docs/dev/platform-integration.md](../dev/platform-integration.md) §2.6 — hook
  timeouts, and the measured helper latency
- [CLAUDE.md](../../CLAUDE.md) — the safe-superset rule this exists to keep
- `Tests/CodexAdapterTests/StandardInputTests.swift` — each of these bounds,
  pinned
