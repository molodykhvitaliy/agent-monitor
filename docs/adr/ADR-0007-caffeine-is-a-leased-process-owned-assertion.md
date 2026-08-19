---
id: ADR-0007
title: Caffeine is a leased, process-owned power assertion
status: accepted
date: 2026-08-19
supersedes: null
superseded_by: null
tags: [power, caffeine, macos, safety, honesty]
---

# Caffeine is a leased, process-owned power assertion

## Context

AgentBar keeps the Mac awake while an agent is working. The feature is small and
its failure mode is not: a keep-awake that is left on drains a battery, heats a
bag, and is invisible until the damage is done. Nothing in the interface makes a
Mac that never sleeps look like a bug, so whatever holds the Mac awake has to be
something that **cannot be left behind**.

Three separate ways exist to end up holding it for ever:

1. **A stuck session.** A session that never leaves `working` — its agent was
   killed, its helper failed, the machine slept mid-turn — would satisfy any
   "keep awake while working" rule indefinitely.
2. **A dead app.** AgentBar is a `LSUIElement` process with no window; a user
   who force-quits it has no way of knowing something was held on its behalf.
3. **A wedged app.** A process that is alive but has stopped deciding is the
   case neither of the first two answers covers, and the one hardest to notice.

Step 08's brief states the standard plainly: *the assertion appears and
disappears exactly in step with real activity, and no failure mode leaves it
held.*

## Decision drivers

- No failure path may leave the Mac awake.
- The mechanism must be observable from outside the app, because the symptom —
  a Mac that did not sleep — appears hours after the cause.
- `AgentBarPower` may reach only `AgentBarCore`, so the decision has to be
  expressible from a `StoreSnapshot` alone.
- The honest limits have to be stated rather than hidden: no assertion type
  survives the lid closing, and macOS sleeps on low battery regardless.

## Considered options

### A. Shell out to `/usr/bin/caffeinate`

The obvious answer, and the one the step forbids. `caffeinate` is a child
process, and a child process **survives its parent being force-quit**. A user who
Force Quits AgentBar mid-turn would be left with an orphan holding the Mac awake
and nothing on screen to connect the two. It also puts a process spawn on a path
that runs whenever an agent starts working.

### B. An unbounded `IOPMAssertion`

`IOPMAssertionCreateWithName` with `kIOPMAssertionTypePreventUserIdleSystemSleep`
answers hazards 1 and 2: the watchdog in `AgentBarCore` already refuses to keep a
silent session in `working`, and the kernel releases a process-owned assertion
when the process dies — verified with `kill -9`. It answers hazard 3 with
nothing. A main actor that stops making progress keeps the assertion until a
human notices and quits.

### C. A bounded assertion, renewed while it is wanted

The same assertion, created with `kIOPMAssertionTimeoutKey` and re-armed on a
timer far shorter than the lease. The assertion becomes something AgentBar has to
keep asking for, so a controller that stops asking stops holding it.

The cost is a second reason the assertion can drop, and a second number to get
right: too short a lease and a busy machine sleeps mid-build, which is precisely
the failure the feature exists to prevent.

## Decision

**Option C.** One `PreventUserIdleSystemSleep` assertion, owned by the AgentBar
process, taken with a **150-second lease** and re-armed every **30 seconds** for
as long as a reading of the store still wants it.

The three mechanisms are kept deliberately distinct, because they fail
independently:

| Hazard | What releases the assertion |
|---|---|
| A session stuck in `working` | the `AgentBarCore` watchdog — `unknown` is derived on every read, so the release needs no sweep |
| AgentBar killed, crashed, force-quit | the kernel, because the assertion is process-owned |
| AgentBar alive but no longer deciding | the lease expiring unrenewed |

The lease uses `kIOPMAssertionTimeoutActionTurnOff` rather than
`TimeoutActionRelease`: the id stays valid after expiry, so a recovered
controller re-arms it and the assertion comes back with no bookkeeping about
whether the id is still real
([platform-integration.md §7.2](../dev/platform-integration.md)).

`kIOPMAssertionDetailsKey` carries a plain-English reason — `1 agent session
working in agent-monitor` — refreshed on every renewal, so `pmset -g assertions`
answers "why is my Mac awake?" without AgentBar being open.

**Naming the project there is deliberate**, and it is the first value AgentBar
publishes outside its own log: `pmset -g assertions` is readable by any process
running as the user, and a `sysdiagnose` captures it. The name is a directory
basename that could carry a client or an unannounced codename. It is kept
because the diagnostic is worthless without it on a machine with several
projects, and because a `sysdiagnose` already contains the full paths of every
open file — a basename adds nothing to what such a bundle discloses. Only the
count is published when more than one session is working, since a list of names
would not fit the line anyway.

`isHolding` is derived from whether the assertion is **on**, not from whether an
id is owned. `TimeoutActionTurnOff` leaves the id valid after the lease runs out,
so the holder records when the lease was last armed and reports no hold once it
has passed. The controller's answer to that is to arm it again, which makes the
pessimistic reading free.

Consequences for the interface, which follow from the same honesty argument:

- The panel footer carries a live indicator with four distinct silhouettes:
  holding, armed, off, and refused. *On and holding* and *on and nothing needs
  it* are different facts and must not share a face.
- A refused assertion is drawn as a fault and never as a hold. The only other
  symptom is a Mac that fell asleep during a build, hours later, with nothing to
  connect the two.
- The settings window states the limits in full: this does not keep the display
  awake, does not survive closing the lid, and does not outrank a low battery.

## Consequences

**Good.** No path leaves the Mac awake: kill it, wedge it, or leave a session
stuck, and the assertion goes. The state is readable from `pmset` by anyone
debugging a Mac that will not sleep, including someone who has never heard of
AgentBar. `IOKit` is restricted to `AgentBarPower` by `ModuleBoundaryTests`, so
"one owner, one release path" is enforced rather than remembered.

**Bad.** There is a fourth number in the system — the lease — and getting it
wrong in the strict direction puts the Mac to sleep under a running build. 150
seconds is five renewal periods, which is slack enough that a busy main actor
never drops it by accident and short enough that a wedged app costs two and a
half minutes of wakefulness. A renewal timer also runs whenever the assertion is
held, although not otherwise: an idle AgentBar has no clock of its own here, and
the push leg is what wakes it.

**Reserved.** Anything else that wants to keep the Mac awake — a future Codex
quota poll, a long install — goes through `CaffeineController` rather than taking
its own assertion. The module boundary makes that a build failure rather than a
convention.

## References

- [docs/dev/platform-integration.md §7](../dev/platform-integration.md) — the
  IOKit facts, each verified by experiment.
- [docs/dev/architecture.md](../dev/architecture.md) — the watchdog allowances
  the hold depends on, and where the module sits.
- `.scratch/plan/agentbar/steps/08-caffeine.md` — the step this settles.
