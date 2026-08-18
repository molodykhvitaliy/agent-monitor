# Architecture

## Shape

```
┌── Claude Code ──────────────────────────────────────┐
│  hooks type:"http" → POST direct, no process spawn  │
└──────────────────────────┬──────────────────────────┘
                           │
┌── Codex ──────────────────┼──────────────────────────┐
│  hooks type:"command" → agentbar-helper → loopback   │
│  codex app-server ◄── JSON-RPC/stdio ── QuotaService │
└──────────────────────────┬──────────────────────────┘
                           ▼
              ┌─────────────────────────────┐
              │  AgentBarIngest             │  loopback + bearer token
              └──────────────┬──────────────┘
                             ▼
              ┌─────────────────────────────┐
              │  AgentBarCore               │  domain, provider-neutral
              │  SessionStore · Watchdog    │
              └──┬────────┬────────┬────────┘
                 ▼        ▼        ▼
               UI    Notifications  Power
```

## Why two transports

**Claude Code uses an `http` handler.** The engine performs the POST itself, so
no process is spawned. `PreToolUse` fires on every tool call — a per-event
process spawn would cost latency and battery for nothing.

**Codex needs a helper.** Only `command` handlers execute today, so a process
bridge is unavoidable. It must be a **compiled binary** completing in single-digit
milliseconds: Codex caps `SessionEnd` hooks at 1 second. An interpreter start-up
per event is disqualifying.

## Domain model

Provider-neutral. Adapters translate inbound platform events; above the adapter
layer nothing knows which tool produced an event.

```swift
struct AgentEvent {
    let provider: Provider          // .claudeCode | .codex
    let sessionId: SessionID
    let turnId: TurnID?
    let cwd: URL
    let project: ProjectRef         // derived from cwd, worktree-aware
    let model: String?
    let kind: EventKind
    let tool: ToolRef?
    let toolUseId: ToolUseID?
    let agent: AgentRef?            // main thread or a named subagent
    let timestamp: Date
    let raw: RawPayload             // retained for diagnostics only
}

enum EventKind {
    case sessionStarted
    case working
    case waitingPermission(PermissionRequestRef)   // reserved, backlog
    case waitingInput
    case toolStarted, toolFinished
    case subagentStarted, subagentStopped
    case turnFinished
    case sessionEnded
    case failed(reason: String)
}
```

## Session state machine

Keyed by `sessionId`, grouped for display by `project`.

```
sessionStarted                  → idle
UserPromptSubmit                → working
PreToolUse / PostToolUse        → working  (heartbeat, refresh lastSeen)
Notification(idle_prompt)       → waitingInput
SubagentStart / SubagentStop    → working, adjust subagent count
Stop                            → idle
StopFailure                     → failed
SessionEnd                      → remove
no event for N minutes          → unknown
```

### The two problems that must be solved explicitly

**Return from waiting.** After the user answers a permission prompt there may be
no "resumed" event. Recovery happens on the next `PreToolUse`, `PostToolUse` or
`UserPromptSubmit`. Do not wait for a dedicated signal that does not exist.

**Watchdog is mandatory.** A session with no events for N minutes becomes
`unknown`, never a permanent `working`. It must survive agent process death,
helper failure, machine sleep/wake, and sessions that never emit `SessionEnd`.
Caffeine correctness depends directly on this: a session stuck in `working`
would keep the Mac awake indefinitely.

## Ingest

One loopback endpoint serves both providers. Claude Code posts to it directly;
the Codex helper relays to it.

- bound to `127.0.0.1` only, plus a Unix socket for the helper;
- bearer token generated at install time, stored in the app's support directory
  with `0600`, injected into the hook config;
- port written to a discovery file so the helper finds a moved endpoint, while
  the Claude Code hook URL is rewritten by the installer if the port changes;
- request handling reserves a **synchronous response path** so the Approve/Deny
  backlog item can be added without reshaping the transport.

## Concurrency

Swift 6 strict concurrency. `SessionStore` is an actor and the single source of
truth. UI observes projected immutable snapshots. Adapters are `Sendable` value
transformers with no shared state.

## Degradation

Every external format sits behind an adapter, is covered by tests against
recorded real payloads, and degrades rather than crashes on an unknown schema.
A parse failure produces a diagnostic and a dropped event — never a lost session
list and never a crash.

## Reserved for the backlog

Deliberately shaped for, but not implemented in, the MVP:

- **Approve/Deny from a notification** — synchronous `PermissionRequest`, an
  `ApprovalBroker` with explicit timeout, dedup by `sessionId + toolUseId`, and
  cancellation on the matching `PostToolUse`. The ingest layer keeps the
  synchronous path; the domain keeps `waitingPermission`.
- **Full dashboard window** — the store already exposes history-shaped
  projections; only a window is missing.
- **Claude Code usage via OpenTelemetry** — optional, opt-in, never quota.
- **Additional providers** (Cursor and others) behind the same adapter protocol.
