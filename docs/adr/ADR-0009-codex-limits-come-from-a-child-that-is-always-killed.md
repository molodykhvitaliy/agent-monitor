---
id: ADR-0009
title: Codex limits come from a child that is always killed
status: accepted
date: 2026-08-19
supersedes: null
superseded_by: null
tags: [codex, quota, process, architecture]
---

## Context

Codex limits are the one quota AgentBar can legally show, and they come from
`codex app-server` — a local integration surface spoken to over stdio, where the
network request is made by the user's own binary under the user's own session
([ADR-0002](ADR-0002-tos-boundary.md)).

Spawning a subprocess is the largest new capability the project has taken on. It
is also the one whose failure mode is invisible: a leaked child is not a crash,
not a wrong number, and not a log line — it is a `codex` process in Activity
Monitor that nobody connects to the menu-bar app that started it, holding memory
until the machine is restarted. AgentBar's safe-superset rule says that if it is
not running, both tools behave exactly as if it never existed, and a surviving
child is precisely a violation of that.

The step's own research left the lifetime open: a long-lived sidecar would let
AgentBar subscribe to `account/rateLimits/updated` instead of polling.

## Decision drivers

- No process may outlive the app, on any path, including force-quit.
- No RPC may hang the reader. `account/rateLimits/read` was measured at 3.2 s and
  at 1.4 s on different days; it is a network round trip and can be much worse.
- Restraint: the brief makes "not overloaded" an explicit product requirement,
  and a permanent background process is the invisible version of that.
- The surface is labelled `[experimental]` and the account methods are not in the
  prose documentation at all.

## Considered options

1. **A long-lived sidecar**, connected at launch, subscribed to
   `account/rateLimits/updated`, kept alive for the session.
2. **One child per reading**, handshaken, asked, killed.
3. **`codex app-server daemon`**, the shared local daemon the CLI offers.

## Decision

**Option 2.** One `codex app-server` per reading, under a single 20-second budget
for the whole exchange, killed with `SIGTERM` on every path — success, failure,
timeout, cancellation and quit alike. `AppServerExchange.run` is the only place
that can forget, and it does not.

Option 1 was rejected on the evidence rather than on taste.
`account/rateLimits/updated` is documented as a *"sparse rolling rate-limit
update"* — the numbers a turn's own response carried. AgentBar's connection never
starts a thread, so the notification would describe work it never does, and the
quota it actually needs to follow is spent by Codex sessions in the user's editor
that this connection knows nothing about. A permanent child process, for updates
that would never arrive.

Option 3 shares a daemon with whatever else is using it. It moves the lifetime of
a process AgentBar started outside AgentBar's control, which is the one property
this decision exists to keep.

The cost of option 2 is a spawn per reading, measured end to end at **1.39 s** and
taken at most every two minutes. Nothing waits on it: the panel renders the last
reading, and a refresh in flight is invisible.

Three things ask for a reading, and they cover different failures: **launch**,
because AgentBar is usually started while agents are already at work; a **Codex
turn ending**, because that is when the number has just moved; and a
**conservative interval**, default 30 minutes, because a Codex session in another
editor spends quota this process never hears about.

## Consequences

**Positive.** The lifetime is bounded by construction rather than by care. A
force-quit is covered by a second mechanism — the pipe's write end closes with
the process and the child exits on its own within 2.74 s — so the guarantee does
not rest on AgentBar getting to run its teardown.

Two paths needed closing before that was true, and a review found both. `Task`'s
`value` is **not** cancellation-aware, so a cancelled refresh would have left the
child running until the budget expired — up to twenty seconds after
`QuotaService.stop()` returned; `run` now waits inside a
`withTaskCancellationHandler` that ends the transport. And `end()` returns early
on every call after the first, so a `start()` after one would have spawned a
child that the next `end()` declined to kill; `start()` now claims the transport
under the same lock that records the process, and refuses if it has been ended.
Both are covered by tests that fail when the fix is removed — the cancellation
one by asserting the *elapsed time*, because without the handler it still passes,
thirty seconds later, and the `start()` one by counting spawns, because a
transport that spawned and then killed would throw the same error.

`SIGTERM` is sufficient (measured: the server dies within 10 ms, idle or
mid-request), so no `SIGKILL` is needed, so `CodexAppServer` needs no
`import Darwin` and the loopback-only guard in `ModuleBoundaryTests` stays
exactly as narrow as it was.

**Negative.** A refresh costs a process launch, and the freshest possible number
is not available: between an interval and a turn ending, the bar can be up to
half an hour stale. For a weekly window at 80 % this is not a number anybody
watches move.

**Accepted trade-off.** A slightly stale bar beats a background process the user
did not ask for and cannot see.

**A new guard.** `Process` is restricted to `CodexAppServer` by
`ModuleBoundaryTests`, matched as `Process()` so `ProcessInfo` does not trip it.
One module spawns, so one module can be held to killing.

## References

- [docs/dev/platform-integration.md](../dev/platform-integration.md) §3.5.2 — the
  four shutdown measurements this rests on
- [docs/dev/architecture.md](../dev/architecture.md) — Codex limits
- [ADR-0002](ADR-0002-tos-boundary.md) — why a local child is inside the boundary
- [ADR-0007](ADR-0007-caffeine-is-a-leased-process-owned-assertion.md) — the same
  argument about a resource that outlives its owner, one step earlier
