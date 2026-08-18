---
id: ADR-0004
title: The ingest token is written literally into the user's settings file
status: accepted
date: 2026-08-18
supersedes: null
superseded_by: null
tags: [security, installer, claude-code, ingest]
---

# ADR-0004 — The ingest token is written literally into the user's settings file

## Context

The loopback ingest endpoint authenticates every request with
`Authorization: Bearer <token>` (ADR-0002, step 03). Claude Code performs the
POST itself, so the header has to be written into the hook configuration in
`~/.claude/settings.json`, and Claude Code offers exactly two ways to fill it:

- a literal value, written into the file;
- `$VAR` interpolation, where a handler names the variable in `allowedEnvVars`
  and the value comes from the environment of whatever launched the agent.

`~/.claude/settings.json` is mode `0644` on the developer's machine, which is
what Claude Code creates. So the literal route puts a secret in a file every
account on the Mac can read.

## Decision drivers

- A hook that fails is **visible in the user's transcript**. AgentBar is
  supposed to be invisible when it is not working, and noisy authentication
  failures are the opposite of that.
- The installer must not change how the user's *other* hooks behave.
- AgentBar is a menu-bar app launched from the Finder. It inherits no shell
  environment and cannot cause one to exist.
- What the token actually protects: an endpoint that accepts events and answers
  `200` with an empty body. In the MVP it grants no decision and no data.

## Considered options

**A. Literal token in `settings.json`.** No environment involved. The secret
sits in a file readable by other local accounts.

**B. `$AGENTBAR_TOKEN` with `allowedEnvVars`.** The secret stays out of the
file. But an unset variable interpolates to an **empty string**, so every hook
becomes a `401` and every event becomes a non-blocking error in the transcript —
and a variable exported in a login shell is not a variable a Finder-launched
VS Code inherits. Making it reliable means `launchctl setenv` and a login item,
which is a second installer with its own failure modes.

There is a second, worse problem with B. Interpolation is gated by
`httpHookAllowedEnvVars` as well as per-handler `allowedEnvVars`, and *defining*
`httpHookAllowedEnvVars` restricts interpolation for every http hook at every
settings level. Writing it would change the behaviour of hooks the user
installed themselves, which the installer rules forbid.

**C. Drop authentication for the Claude Code route.** Then any local process can
inject events with no token at all: strictly worse than a readable one, and it
would undo a reviewed part of step 03.

**D. Tighten `settings.json` to `0600` during install.** Available as a
mitigation for A, but it changes the permissions of a file the user owns, as a
side effect of an unrelated action.

## Decision

**Option A.** The token is written literally into `~/.claude/settings.json`.

The installer:

- **preserves the file's existing permissions** and never widens or narrows
  them (rejecting D);
- creates the file `0600` when there is none, because a file AgentBar made is
  read by nothing but this user's own tools;
- **reports** `settingsReadableByOthers` whenever the file is group- or
  other-readable, so the trade is stated rather than hidden;
- never writes `httpHookAllowedEnvVars` at all.

## Consequences

Every event path works with no environment configuration, and a user who never
opens a terminal is not a user with a broken integration. The failure mode B
would have produced — a silently empty header, a transcript full of hook errors
— cannot occur.

The cost is real and bounded: another account on the same Mac can read the token
and post fabricated session events to a menu-bar app. It cannot read anything,
because the endpoint answers `200` with an empty body and nothing else.

The backups the installer takes would inherit the same exposure, because a copy
of a file containing the token contains the token. They do not, because a backup
is AgentBar's own artefact rather than the user's file: it is written `0600`
whatever the original's mode, and the backups are pruned to the most recent few
so a token rotation does not leave an unbounded trail of superseded ones. The
same reasoning does not extend to the settings file itself — that one the user
owns, and option D stays rejected.

That bound is exactly what changes if the **Approve/Deny** backlog item ships. A
token that can answer a permission prompt is a token that can approve a tool
call, and this decision does not survive that: the synchronous decision path
needs a credential that is not sitting in a `0644` file — the Keychain, or a
peer-credential check on the Unix socket. This ADR is to be revisited in the
same change, not after it.

## References

- [ADR-0002](ADR-0002-tos-boundary.md) — the loopback-only boundary
- [docs/dev/platform-integration.md §1.5](../dev/platform-integration.md) — the
  two interpolation allow-lists and what defining them does
- `Sources/ClaudeCodeAdapter/ClaudeCodeInstaller.swift`
