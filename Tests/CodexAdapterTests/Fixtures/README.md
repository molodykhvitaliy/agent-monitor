# Codex hook payloads

**Status: documented shape, not yet captured.** Unlike the Claude Code fixtures
next door, these were written from the field lists in Codex's own hooks
reference — read in full on 2026-08-19 against Codex CLI `0.147.0`, and cited
with its URL in `docs/dev/platform-integration.md` §2 — rather than recorded
from a live session. Every field name, its type and its presence-per-event come
from that page; the values are invented.

The reason is Codex's trust model, and it is the same reason step 09 exists. A
`command` hook does not run until the user has reviewed and trusted the exact
hook definition in `/hooks`, which is an interactive step: a payload cannot be
captured from a scripted run, and the documented flag that skips the review is
not a tool this project uses, even in a sandbox (ADR-0008).

## Capturing the real ones

Install a recorder hook on each of the eight events AgentBar subscribes to —
merged into `~/.codex/hooks.json`, never into `config.toml` — trust it in
`/hooks`, and run one session that uses a tool and a subagent. Replace these
files with what it records, keep field order and nesting untouched, and rewrite
only identity: the home directory and the working directory become `/Users/dev`
and `/Users/dev/projects/probe`, as in the Claude Code fixtures.

Anything in these files the capture contradicts is a bug in AgentBar's reading
of the documentation, and the decoder is deliberately written so that a
contradiction degrades one field rather than failing a payload.

## What each file is

| File | Event |
|---|---|
| `session-start.json` | `SessionStart`, `source: startup` |
| `user-prompt-submit.json` | `UserPromptSubmit` |
| `pre-tool-use-shell.json` | `PreToolUse`, the shell tool with an argv `command` |
| `post-tool-use-shell.json` | `PostToolUse` closing the same `tool_use_id` |
| `pre-tool-use-apply-patch.json` | `PreToolUse` for a tool whose arguments carry a whole patch |
| `subagent-start.json` / `subagent-stop.json` | subagent context, with `agent_id` |
| `stop.json` | `Stop` |
| `session-end.json` | `SessionEnd` — no `turn_id`, no `permission_mode` |
| `pre-compact.json` | an event AgentBar decodes and deliberately ignores |
| `session-*.json` | whole sessions in delivery order, for the replay suites |
