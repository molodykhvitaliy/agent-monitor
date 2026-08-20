---
id: ADR-0012
title: A finished session is retired, not doubted
status: accepted
date: 2026-08-20
supersedes: null
superseded_by: null
tags: [watchdog, performance, panel, domain]
---

## Context

The watchdog was designed around one hazard: a session that stays `working`
after its agent has died keeps the Mac awake and tells the user an agent is busy
when nothing is. Every allowance was chosen against that hazard, and the two
that govern a session which has *finished* were chosen as an afterthought — eight
hours of tolerated silence for `idle` and `failed`, then an hour of `unknown` on
top before the session is retired at all. Nine hours, in a product whose panel is
a list of what is happening now.

The first full day of real use produced the consequence. Sessions do not
usually end with a `SessionEnd`: a terminal closed, an editor quit, a machine
that changed projects — none of them says goodbye, and both providers' farewell
hooks only fire on an orderly exit. So a working day accumulated one row per
project per tool per restart, all of them finished hours earlier, none of them
retired. The product owner's report was a menu bar full of dead sessions and a
laptop with its fans on.

The cost is not the memory. It is that **every one of those rows is redrawn on
the open panel's one-second clock**, each row constructing its state label, its
accessibility sentence and a formatted start time, and the panel re-measured
against the result. The system's own record for 2026-08-20 has AgentBar at 98 %
of a core for 92 seconds with every sample inside the panel's layout. The rows
being dead was not incidental to that; it was the multiplier.

## Decision drivers

- The panel answers "what are my agents doing **now**". A session that finished
  this morning is not an answer to that question, whatever the store knows
  about it.
- `unknown` means *AgentBar has no opinion about whether this is alive*. That is
  a real question about a session that was working or waiting, and a
  meaningless one about a session that already stopped — which is why running a
  finished session through `unknown` added an hour to its retirement for no
  information.
- Per-frame cost scales with the row count, and the row count was governed by a
  timeout nobody had revisited since it was written.
- Nothing is lost by retiring early. The store adopts a session on whatever
  event reaches it first, so a session that speaks again is simply back.

## Considered options

1. **Leave the allowances and cap the panel's row count.** Bounds the render
   cost and leaves the store's picture of the world wrong. It also invents an
   interface — "showing 20 of 47" — for a problem that is not the user's.
2. **Shorten `restingTimeout` alone.** Ten minutes of silence, then `unknown`,
   then the eviction timeout: seventy minutes to retirement, and an hour of it
   spent showing a row labelled `Unknown` about a session that plainly is not.
3. **Retire a resting session outright at its allowance.** Ten minutes, and it
   leaves the list rather than changing colour.

## Decision

**Option 3.** `SessionState.isResting` — `idle` or `failed` — and
`WatchdogPolicy.verdict` answers `.evict` rather than `.markUnknown` for those
states. `restingTimeout` is **ten minutes**.

The other allowances are untouched and deliberately so: fifteen minutes for a
working session, an hour with a tool open, two hours waiting on a human. Those
are the ones the original hazard is about, and shortening them is how a build
loses its power assertion.

## Consequences

- The panel is a list of live sessions again. On the day that produced this,
  the high-water mark falls from around fifty rows to the handful actually
  running.
- **A session left idle while its output is read disappears after ten minutes.**
  It returns the moment the user types, because the store adopts a session on
  any event. This is the price, it is stated rather than hidden, and it is the
  right way round: a row that reappears costs a glance, a row that never leaves
  costs a core.
- `Unknown` now means only what it says. A resting session can still *read* as
  `unknown` in the gap between its allowance expiring and the next sweep —
  `unknown` is derived on every read and the store owns no timer — but that gap
  is a second while the panel is open and at most the closed clock's interval
  otherwise, rather than the hour it used to be. **Both clocks sweep**, which
  they did not before this change: the open one only re-read, so a panel left on
  screen turned every finished session into a permanent *Stopped reporting* row.
  That was found by watching the real app fail to shrink its panel ten minutes
  after the sessions went quiet, and it is what made this decision true rather
  than intended.
- The history behind the list is unchanged and still bounded at a hundred
  entries, so what was retired is still recorded.
- `Tests/AgentBarCoreTests/AccumulationTests.swift` pins the bound rather than
  the number: a simulated day of sessions that never say goodbye must never
  leave more than a couple on the list at once.

## References

- [docs/dev/architecture.md](../dev/architecture.md) — the allowance table
- [ADR-0007](ADR-0007-caffeine-is-a-leased-process-owned-assertion.md) — the
  watchdog is what stops a stuck session holding the Mac awake
- `/Library/Logs/DiagnosticReports/AgentBar_2026-08-20-090914_*.cpu_resource.diag`
  — the system's own record of the failure
