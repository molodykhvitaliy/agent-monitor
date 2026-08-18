---
id: ADR-0001
title: Lifecycle hooks as the integration foundation
status: accepted
date: 2026-08-18
supersedes: null
superseded_by: null
tags: [architecture, integration, claude-code, codex]
---

## Context

AgentBar must know when a Claude Code or Codex session starts, works, waits and
finishes. The developer's primary environment is the **VSCode extension**, not
the CLI. Several observation mechanisms exist with very different properties.

## Decision drivers

- Must work identically in the CLI, the IDE extension, the desktop app and the web.
- Must not degrade the tools or change their behaviour.
- Must not depend on undocumented formats.
- Per-tool-call overhead must be negligible.

## Considered options

1. **Lifecycle hooks** — documented on both platforms.
2. **Transcript file watching** — `~/.claude/projects/**/*.jsonl`,
   `~/.codex/sessions/**/rollout-*.jsonl`.
3. **`statusLine`** (Claude Code) — receives rich state including `rate_limits`.
4. **Process/TTY inspection** — infer state from the running process.
5. **Codex `notify`** — fire-and-forget turn completion.

## Decision

**Lifecycle hooks are the foundation.** Claude Code uses an `http` handler;
Codex uses `command` handlers bridged by a compiled helper.

Transcripts are permitted for history and diagnostics only, behind a versioned
adapter. `notify` is not used at all.

## Consequences

**Positive.** Hooks are executed by the harness itself, so coverage is uniform
across every environment — this is precisely why `statusLine` fails, being a CLI
TUI feature and therefore invisible to a VSCode-extension user. Both platforms
document the payloads. The `http` handler spawns no process. Absent AgentBar,
hooks resolve to "no opinion" and both tools behave normally.

**Negative.** Installation must edit user configuration files, which requires a
careful merging installer. Codex additionally requires explicit user trust of the
hook definition, keyed to its SHA — an onboarding step and a re-trust prompt on
any change to the hook command.

**Rejected and why.** Transcript formats are undocumented for Claude Code and
**explicitly declared unstable** for Codex. `statusLine` does not exist outside
the CLI TUI. Process inspection cannot distinguish "waiting for permission" from
"thinking". `notify` is fire-and-forget, cannot carry lifecycle state, and its
single config slot is already occupied on the developer's machine.

## References

- [docs/dev/platform-integration.md](../dev/platform-integration.md)
- <https://code.claude.com/docs/en/hooks>
- <https://learn.chatgpt.com/docs/hooks>
