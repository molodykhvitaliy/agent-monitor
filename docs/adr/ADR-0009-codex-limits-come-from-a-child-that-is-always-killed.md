---
id: ADR-0009
title: Codex limits come from a child that is always killed
status: accepted
date: 2026-08-19
supersedes: null
superseded_by: null
amended_by: [ADR-0011, ADR-0012]
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

> **Amended on this point by
> [ADR-0011](ADR-0011-limits-are-read-when-someone-is-looking.md), step 11.**
> A fourth trigger was added — the panel being open — and three numbers in this
> record moved with it. The interval is **ten minutes**, not thirty, so "up to
> half an hour stale" below is now up to ten. The tightest gap between two
> readings is **one minute**, not two, and belongs to the new trigger; two
> minutes still bounds everything else. The decision this record is *about* —
> one child per reading, killed on every path — is unchanged and governs the new
> trigger too.

> **Amended again in step 11, on the word "killed".** `SIGTERM` is a *request*,
> and this record treated it as the guarantee. The measured Codex exits inside
> 10 ms, so nothing was ever observed surviving one — but a build that blocks the
> signal, or wedges while handling it, would have left a Rust runtime behind on
> every reading, and this project's non-negotiables do not admit a guarantee that
> depends on the child's manners. `CodexProcessTransport.end()` now arms a
> `SIGKILL` two seconds behind the `SIGTERM`, cancelled by the child's own
> termination handler the instant it exits, and aimed only while `Process` still
> reports the child alive. `ProcessTransportTests` pins it against a child that
> ignores `SIGTERM` outright.

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

A second review found two more, one of them a crash. `start()` refused after
`end()` but not after a first `start()`, so a second call would overwrite the
first child's handles and leave it running with nothing able to reach it — the
same leak from the other direction. And writing to a child that had already
exited raised **`SIGPIPE`**: `Process` closes the parent's copy of the stdin
pipe's read end at spawn, so the write lands in a pipe with no reader, and a
signal is not something a `catch` can answer. That path is not hypothetical — a
child that fails on a bad `config.toml` writes to stderr and exits, and the
exchange's next act is `initialize`. Removing the guard kills the test process
with signal 13.

`SIGTERM` is sufficient (measured: the server dies within 10 ms, idle or
mid-request), so no `SIGKILL` is needed, so `CodexAppServer` needs no
`import Darwin` and the loopback-only guard in `ModuleBoundaryTests` stays
exactly as narrow as it was. The signal is sent from two places, because `end()`
can arrive before the spawn it is meant to undo: `end()` kills a running child,
and `start()` kills one that came up after an `end()` had already been and gone.

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
