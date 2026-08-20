---
id: ADR-0011
title: Codex limits are read when someone is looking, on a leash that ends
status: accepted
date: 2026-08-19
supersedes: null
superseded_by: null
tags: [codex, quota, tos, cadence]
---

## Context

[ADR-0009](ADR-0009-codex-limits-come-from-a-child-that-is-always-killed.md)
settled *how* a reading is taken — one `codex app-server` child per reading,
killed on every path — and left the cadence at three triggers: launch, a turn
ending, and a thirty-minute interval, with a two-minute floor between any two
reads.

Half an hour turned out to be wrong about the person rather than about the bar.
A weekly window really does move slowly, so the reasoning held for the *number*;
what it missed is that at that interval the only refresh anyone ever observed was
a turn finishing on this Mac. The figure read as one that moved when AgentBar
made it move — which is the opposite of what a limits section is for. The
product owner's report was blunt: *limits only update when an agent finishes; I
would like to watch them change.*

The obvious fix — tighten the interval — is the one that has to be argued
against. Every reading is a request the user's own `codex` binary makes against
the user's own account. Nothing here is prohibited by
[tos-boundary.md](../dev/tos-boundary.md) at any frequency, because AgentBar
originates no provider request. But *ordinary, individual usage* is the standard
those accounts are held to, and a background poll that runs whether or not
anybody is looking spends the user's quota-adjacent goodwill on nothing.

## Decision drivers

- The number is worth reading when somebody can see it, and worth very little
  otherwise. A menu-bar panel is closed almost all of the time.
- A read costs a child process, ~1.4 s, and a network round trip on the user's
  account. That cost is fine occasionally and wrong continuously.
- Nothing may resemble automation against a provider account (ADR-0002).
- Whatever bound is chosen has to be one the **code enforces**, not one a
  comment asserts.

## Considered options

**1. Tighten the interval alone.** One constant, no new concepts. Rejected as
the worst trade available: to make an open panel feel live the interval would
have to reach a minute or two, and it would then run all day with nobody looking.

**2. Refresh only when the panel opens.** Honest and cheap, and it answers "is
the number current when I look at it". Rejected as insufficient: watching a bar
*change* was the actual request, and a single reading per opening cannot show
movement.

**3. A separate, tighter cadence while the panel is open, unbounded.** What was
built first, and what review caught. Its justification — "an open panel is a
surface measured in seconds" — is false here: `hidesOnDeactivate` is false and
the panel is never key on the mouse path, so switching apps, changing Space or
walking away all leave it on screen. Verified against the running app: the panel
survives ⌘-Tab and activating another application indefinitely. Unbounded, this
is a one-a-minute poll wearing a justification it stopped deserving the moment
the user looked away.

**4. A tighter cadence while the panel is open, with a time bound.** Option 3
with the premise enforced instead of assumed.

## Decision

**Option 4**, and the interval shortened as a separate, smaller change.

| Asks for a reading | Spacing | Why |
|---|---|---|
| Launch | — | AgentBar is usually started beside agents already at work |
| A Codex turn ending | 2 min | the number has just moved; a burst of completions is one reading |
| The interval | 10 min | a Codex session in another editor spends quota this process never hears about |
| **The panel being open** | 1 min, for the first 5 min | the only moment anybody is looking at the answer |

- The panel's leg runs on the panel's existing one-second clock and is spaced
  down inside `QuotaService`, not at the call site: the caller's job is to say
  *that* somebody is looking, never to decide what that is worth.
- After five minutes of an open panel it **stops asking** and goes back to
  displaying whatever the interval brings in. The panel is not closed and nothing
  is hidden — only the asking ends.
- The interval moves 30 → 10 minutes. Four spawns an hour of a local binary,
  against two an hour before.
- The floor under the user-configurable `codex.limitsRefreshMinutes` stays at
  five minutes and is untouched.

## Consequences

**Good.** Opening the panel gives a reading within a second or two, and leaving
it open shows the figure move. Observed end to end: opening the panel spawns
exactly one `codex app-server`, which is gone in under three seconds.

**Good.** Reads are now concentrated where they have a viewer. The busiest
possible pattern — a panel held open — is bounded at five readings, and the idle
pattern is four an hour rather than two.

**Bad.** There are now three spacings and a window, where ADR-0009 had one
spacing and an interval. Four numbers is more than a reader wants to hold, and
the honest mitigation is that every one of them lives in `QuotaSettings` or
`MenuBarController` with the reason attached, and each is pinned by a test that
fails if it is loosened.

**Bad, and accepted.** The five-minute window is arbitrary in the way every such
number is. It is long enough to watch a bar move and short enough that a
forgotten panel costs nothing. It is a constant with a test around it rather than
a truth.

**Neutral.** A panel open past the window shows a reading up to ten minutes old
with nothing saying so. The design has no "last updated" element and this record
does not add one — restraint is an explicit product requirement, and the figure
being slightly stale is not a fault the interface needs to narrate.

## References

- [ADR-0009](ADR-0009-codex-limits-come-from-a-child-that-is-always-killed.md) —
  one child per reading, killed on every path. Unchanged, and it governs the new
  trigger too.
- [ADR-0002](ADR-0002-tos-boundary.md) and
  [tos-boundary.md](../dev/tos-boundary.md) — why the cadence is a decision at
  all, and the 2026-08-19 re-verification this change required.
- [architecture.md](../dev/architecture.md) § *When a reading is taken* — the
  table above, as living documentation.
