---
id: ADR-0008
title: Codex hook trust is observed, never asserted
status: accepted
date: 2026-08-19
supersedes: null
superseded_by: null
tags: [codex, hooks, trust, onboarding, honesty, safe-superset]
---

# Codex hook trust is observed, never asserted

## Context

Codex will not run a non-managed `command` hook until the user has reviewed and
trusted **the exact hook definition**, in `/hooks`. Trust is recorded as a hash
of that definition, so a changed definition goes back to needing review.

This makes the Codex integration different in kind from the Claude Code one.
There, writing `settings.json` is the whole of the install: the next hook fires
into AgentBar's endpoint and the panel fills up. Here, writing `hooks.json` gets
the user an integration that is **configured and completely inert**, with no
error, no prompt AgentBar can raise, and nothing in the panel to explain it. The
step's brief names this directly: *without this row the user gets an app that
silently shows nothing.*

So AgentBar has to answer a question it has no documented way to answer: **has
Codex trusted our hooks?** Three facts constrain the answer.

- The trust record exists on disk. `~/.codex/config.toml` gains a
  `[hooks.state]` table keyed by `<source path>:<event>:<group>:<hook>`, holding
  a `trusted_hash` and an optional `enabled`. This was reproduced against the
  developer's own hooks, and the strings in the installed `codex` binary agree.
  **It is not documented**, which puts it at rank 3 of the source precedence in
  the `platform-docs` skill — observed local behaviour — not rank 1.
- **The hash cannot be recomputed.** Four candidate pre-images were tried against
  three live records; none matched.
- `--dangerously-bypass-hook-trust` exists, and using it would make AgentBar the
  reason a user's hooks ran without review. The flag is named in this ADR, in
  `platform-integration.md` §2.5 and in `tos-boundary.md`'s checklist — all
  prose, none of it code. No source file, test or configuration in this
  repository contains it, and `make tos-check` fails if one starts to.

## Decision drivers

- **A silent integration is the failure mode.** "Connected" while nothing can
  arrive is worse than any other wrong answer this surface can give.
- The trust reading rests on an undocumented format, so the design has to keep
  working when that format changes.
- AgentBar never circumvents a security decision belonging to another tool.
- `config.toml` must not be written — it holds `notify`, the user's comments and
  their own hooks.

## Considered options

1. **Bypass the trust prompt.** Rejected outright. It defeats a security
   mechanism belonging to somebody else's tool, on a machine AgentBar was invited
   onto to watch rather than to act.
2. **Reproduce the hash and compare it.** Would give an exact answer — if the
   pre-image could be found, which it could not, and if it never changed, which
   nobody promises. A monitor that confidently reports a dead hook as healthy is
   the worst outcome available; this option makes that outcome a silent
   consequence of a Codex release.
3. **Ignore trust and report "installed".** Honest about what AgentBar wrote and
   useless about whether it works. It is the design the brief exists to reject.
4. **Read the trust table, and let a delivered event outrank it.** Chosen, with
   the correction below.

## Decision

**Trust is observed from two sources, and the stronger one is behaviour.**

`CodexInstaller.report(for:hasDelivered:trustPending:)` decides in this order:

1. **A Codex event has arrived since launch → `installed`.** A hook that did not
   run cannot deliver anything, so a delivery is proof. The app feeds this in
   from the push leg, where a `StateChange` carries its provider.
2. **Every installed entry has a `trusted_hash`, none is disabled, and the
   record has moved since AgentBar last wrote the definition → `installed`.**
3. **Every entry has a record and at least one is disabled → `disabledInCodex`.**
   Trusted and switched off is a different sentence, and a `Trust` button cannot
   fix it.
4. **Anything else → `installedNotTrusted`.** No record, an unreadable
   `config.toml`, a key format that has moved — all of it resolves to the state
   that asks the user to open `/hooks`.

### The correction: a record is a position, not a definition

The first version of this decision read the table at face value, and a review
found what that costs. A trust key is
`<source>:<event>:<group>:<hook>` — a **position**. AgentBar's own repair rewrites
the command at the same position, so the record survives unchanged, still saying
`trusted_hash`, now describing a definition whose hash no longer matches and
which Codex will therefore skip. Reading it would have put `Connected` under an
inert integration on the most ordinary path there is: the documented `cp -R …
/Applications`, which produces `helperMoved` drift and a `Repair` button.

So AgentBar records, in **its own** directory, the hashes present at the moment
it wrote (`CodexTrustBaseline`). A record that has *changed since* is consent for
what is there now; one that has not is consent for what used to be there. The
question the baseline asks is settled by a delivery, and the file is deleted when
one arrives. If the baseline cannot be written at all, an in-memory flag keeps
the same pessimism for the launch that wrote it — one-way, because only the
baseline can promote a verdict, never demote it.

This remains a note about AgentBar's own action rather than a copy of somebody
else's decision, which is the line this ADR draws.

The asymmetry is deliberate. A delivery can only make the verdict *better*, and
uncertainty always makes it *worse*. If the undocumented key format changes, the
integration reports "installed, not trusted" until the first event arrives and
then corrects itself — a wrong answer in the direction that costs a sentence of
onboarding, never one that costs a user their sessions.

The `Trust` button does not grant trust, because nothing outside Codex can. It
re-reads the state and reports what it found — including saying so plainly when
the answer has not changed.

`config.toml` is read and never written, and only two tables are read out of it:
`[hooks.state]` and `[hooks]`. Everything else in that file, including whatever
credentials a model provider stanza may hold, is parsed into oblivion rather than
into a value AgentBar could log by accident.

## Consequences

- The onboarding card has a real third state, and the user is told what to do
  rather than left with an app showing nothing.
- AgentBar depends on an undocumented file format for a *hint*, never for a
  guarantee. `TOMLTables` cannot throw, and everything it fails to understand
  degrades to "not trusted".
- Trust survives token rotation and a moved port, because `hooks.json` carries
  neither. It does **not** survive the app being moved, since the definition
  names the helper's absolute path — so the installer detects that as
  `helperMoved` drift and says that repairing it means trusting again.
- The proof-by-delivery signal is per launch and is not persisted. A restart of
  AgentBar with an unreadable `config.toml` shows "not trusted" until the next
  Codex event. Persisting it was rejected as a second source of truth about
  somebody else's decision — the baseline is not the same thing, because it
  records what AgentBar wrote and when, not what the user decided.
- The baseline is one small file in AgentBar's application support directory. It
  is disposable: losing it means the table is read at face value again, which is
  the behaviour this ADR corrected, so the in-memory flag covers the launch that
  wrote it and the next delivery settles it for good.
- One key format remains unconfirmed: `[hooks.state]` keys for entries declared
  in `hooks.json` rather than in `config.toml`. Confirming it needs a real
  session, and until then the fallback above is what carries the feature.

## References

- `docs/dev/platform-integration.md` §2.5 — the observed format and what was
  tried against the hash
- `Sources/CodexAdapter/CodexTrustState.swift`, `CodexInstaller.trustStatus`
- `.scratch/plan/agentbar/steps/09-codex-adapter.md` — "a user who has not yet
  trusted the hook is told so explicitly"
