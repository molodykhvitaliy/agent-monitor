# Platform Integration Reference

Verified facts about the extension surfaces AgentBar builds on.

**Verification date:** 2026-08-18
**Verified against:** Claude Code `2.1.233`, Codex CLI `0.147.0`, macOS `27.0`

> **Precedence rule.** Official platform documentation wins over this file, and
> this file wins over the original `.scratch/notes/INITIAL_SPEC.md`. Every claim
> below was checked against primary sources or reproduced locally on the
> verification date. Re-verify with the `platform-docs` skill before starting any
> step that touches an adapter.

---

## 1. Claude Code hooks

Source: <https://code.claude.com/docs/en/hooks>

### 1.1 Handler types

`command`, `http`, `mcp_tool`, `prompt`, `agent`.

AgentBar uses **`http` exclusively**. The engine performs the POST itself, so no
process is spawned per event — this matters because `PreToolUse` fires on every
single tool call.

### 1.2 Events AgentBar subscribes to

| Event | Purpose | Handler config |
|---|---|---|
| `SessionStart` | register session | `async: true` |
| `UserPromptSubmit` | → `working` | `async: true`, timeout ≤ 30s |
| `PreToolUse` | heartbeat + current tool | `async: true` |
| `PostToolUse` | heartbeat + clear pending approval | `async: true` |
| `Notification` | → `waitingInput` | `async: true`, matcher `idle_prompt\|permission_prompt` |
| `SubagentStart` / `SubagentStop` | subagent counter | `async: true` |
| `Stop` | turn finished → `idle` | `async: true` |
| `StopFailure` | turn died on API error → `failed` | `async: true` |
| `SessionEnd` | remove session | `async: true`, **see budget note** |

Reserved for the Approve/Deny backlog item, not installed in MVP:
`PermissionRequest` (synchronous).

### 1.3 Payload fields

Common to every event:

```
session_id, prompt_id, transcript_path, cwd, permission_mode,
effort { level }, hook_event_name, agent_id, agent_type
```

`permission_mode` ∈ `default | plan | acceptEdits | auto | dontAsk | bypassPermissions`.

Tool events add `tool_name`, `tool_input`, `tool_use_id`; `PostToolUse` adds
`tool_result`. `Stop` / `SubagentStop` add `last_assistant_message` and
`stop_reason`.

`agent_id` / `agent_type` are present **only in subagent context** — this is how
the subagent counter is driven, together with `SubagentStart` / `SubagentStop`.

> The spec draft claimed a top-level `worktree` field. It is **not** in the
> documented common payload. Worktree awareness must come from the
> `WorktreeCreate` / `WorktreeRemove` / `CwdChanged` events instead, or be
> derived from `cwd`. Treat `worktree` as absent until proven otherwise.

### 1.4 PermissionRequest decision format — corrected

The documented Claude Code format is a **string** decision:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": "allow",
    "reason": "approved from AgentBar"
  }
}
```

`decision` ∈ `allow | deny | escalate`.

> **The spec draft was wrong here.** It documented
> `"decision": { "behavior": "allow", "updatedInput": {...} }` — that is the
> **Codex** shape (§2.4), not Claude Code's. Do not mix them up.

Also documented and important for the backlog item:

- `PermissionRequest` **cannot block**. Exit code 2 is ignored for this event; it
  is decision-only.
- `PreToolUse` uses a different key entirely:
  `hookSpecificOutput.permissionDecision` ∈ `allow | deny | escalate`, plus
  `permissionDecisionReason`.

### 1.5 HTTP handler semantics

| Response | Effect |
|---|---|
| 2xx, empty body | success, no decision |
| 2xx, JSON object | parsed as decision |
| 2xx, other body | non-blocking error |
| non-2xx | non-blocking error |
| connection failure / timeout | non-blocking error, no decision rendered |

**This is the safe-degradation guarantee.** If AgentBar is not running, every
hook resolves to "no opinion" and Claude Code proceeds with its normal flow.

Configuration keys:

- `allowedHttpHookUrls` — once defined at any settings level, only matching URLs
  run. The installer **must** add AgentBar's URL here.
- `httpHookAllowedEnvVars` — restricts which env vars interpolate into headers.
- per-handler `headers` with `$VAR` interpolation and `allowedEnvVars`.

### 1.6 Timeouts

Default 600s for `command` / `http` / `mcp_tool`; `UserPromptSubmit` lowers it to
30s, `MessageDisplay` to 10s.

**`SessionEnd` hooks share a 1.5-second budget** across all handlers, raised to
match an explicit `timeout` up to 60s. AgentBar sets a small explicit timeout on
`SessionEnd` and must not rely on it for anything slow.

AgentBar sets an explicit `timeout` on every handler. Never inherit 600s.

### 1.7 Matchers

Matchers are exact strings, `|`/`,` lists, or unanchored JavaScript regex if any
other character is present. Per-event matcher domains that matter to us:

- tool events → tool name
- `SessionStart` → `startup | resume | clear | compact | fork`
- `SessionEnd` → `clear | resume | logout | prompt_input_exit | other`
- `Notification` → `permission_prompt | idle_prompt | auth_success | elicitation_* | agent_*`
- `SubagentStart` / `SubagentStop` → agent type

---

## 2. Codex hooks

Source: <https://learn.chatgpt.com/docs/hooks>

> **The documentation moved.** `developers.openai.com/codex/*` now 308-redirects
> to `learn.chatgpt.com/docs/*`. The URLs in the original spec draft are stale;
> use the `learn.chatgpt.com` host.

### 2.1 Events

Turn-scoped: `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PreCompact`,
`PostCompact`, `UserPromptSubmit`, `SubagentStop`, `Stop`.
Session-scoped: `SessionStart`, `SessionEnd`.
Subagent-scoped: `SubagentStart`, `SubagentStop`.

### 2.2 Config discovery

Resolution order, **additive — higher layers do not replace lower ones**:

1. `~/.codex/hooks.json`  ← AgentBar writes only here
2. `~/.codex/config.toml` `[hooks]`
3. `<repo>/.codex/hooks.json`
4. `<repo>/.codex/config.toml` `[hooks]`
5. plugin-bundled `hooks/hooks.json`

AgentBar **never writes `config.toml`.** This avoids TOML comment loss, avoids
the merge warning Codex emits when a layer has both representations, and — see
§5 — avoids destroying the user's existing `notify` entry.

Structure:

```json
{
  "description": "…",
  "hooks": {
    "EventName": [
      { "matcher": "…",
        "hooks": [ { "type": "command", "command": "…", "timeout": 600,
                     "statusMessage": "…", "async": false } ] }
    ]
  }
}
```

Only `type: "command"` is executable today.

### 2.3 Payload

Single JSON object on **stdin** (not argv — that is `notify`, §2.6):

```
session_id, transcript_path (nullable), cwd, hook_event_name,
model, permission_mode, turn_id (turn-scoped events)
```

### 2.4 PermissionRequest decision format

Codex uses a **nested object**:

```json
{ "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": { "behavior": "allow" } } }
```

```json
{ "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": { "behavior": "deny", "message": "…" } } }
```

Parsed but **not supported** — do not emit:
`PermissionRequest`: `updatedInput`, `updatedPermissions`, `interrupt`;
`PreToolUse`: `permissionDecision: "ask"`, `continue`, `stopReason`, `suppressOutput`;
`PostToolUse`: `updatedMCPToolOutput`, `suppressOutput`.

### 2.5 Trust — a product requirement, not a detail

> "Before a non-managed command hook can run, Codex requires you to review and
> trust the exact hook definition."

**Trust is recorded against the hook definition's SHA hash.** Two consequences:

1. Writing `hooks.json` is not enough — onboarding must walk the user through
   trusting it, and the UI must show an explicit "installed but not yet trusted"
   state. Otherwise the user gets a silently dead integration.
2. **Any change to the hook command invalidates trust.** App updates that alter
   the helper invocation re-trigger the trust prompt. The installer must detect
   this and tell the user, and the helper path/argv should be kept stable across
   updates wherever possible.

`--dangerously-bypass-hook-trust` exists. AgentBar never suggests it.

### 2.6 Timeouts

Default 600s. **`SessionEnd` is capped at 1 second (3s maximum).** The Codex
helper must be a compiled binary that completes in single-digit milliseconds —
this alone rules out a Python or shell bridge.

### 2.7 notify — unavailable in practice

`notify` passes JSON as **argv[1]**, not stdin. It is a single-slot config key.

On this machine it is already occupied by *Codex Computer Use*. AgentBar treats
`notify` as **permanently unavailable** and must never write it. Hooks are the
only Codex event source.

---

## 3. Codex App Server — limits

Source: <https://learn.chatgpt.com/docs/app-server> plus locally generated schema.

### 3.1 The schema is machine-readable — use it

```
codex app-server generate-json-schema --out <DIR>
```

This emits the authoritative protocol schema shipped with the installed binary,
including `v2/GetAccountRateLimitsResponse.json`. Swift models are generated
from it, and `make schema-sync` diffs the installed binary's schema against the
checked-in copy to catch upstream drift. This is far more reliable than
transcribing docs by hand.

Note that this cannot run in CI as designed: the `codex` binary is not present on
GitHub runners. Drift is therefore caught locally by `make schema-sync` and
prompted weekly by the `version-watch` workflow. Wiring a CI-side check is part
of step 10.

`codex app-server generate-ts` produces TypeScript bindings from the same source.

### 3.2 Account methods (verified present in 0.147.0)

```
account/read
account/rateLimits/read
account/usage/read
account/rateLimitResetCredit/consume
account/login/start, account/login/cancel, account/logout
account/workspaceMessages/read
```

95 methods total. Transports: stdio (default),
`--listen ws://127.0.0.1:PORT`, `--listen unix://`.

### 3.3 Handshake

`initialize` request → `initialized` notification → other methods. Requests
before initialization fail with "Not initialized". `capabilities.experimentalApi`
gates `process/*`, thread backgrounding and some filtering — **not** needed for
account methods.

### 3.4 Response shape — corrected and expanded

Verified live. `RateLimitSnapshot`:

| Field | Type | Note |
|---|---|---|
| `limitId` | string? | e.g. `"codex"` |
| `limitName` | string? | **was `null` in live response** — never render raw |
| `primary` | `RateLimitWindow`? | |
| `secondary` | `RateLimitWindow`? | **was `null` in live response** |
| `credits` | `CreditsSnapshot`? | `{ balance: string?, hasCredits: bool, unlimited: bool }` |
| `individualLimit` | `SpendControlLimitSnapshot`? | **not in the spec draft** |
| `spendControlReached` | bool? | **not in the spec draft**; `null` = unavailable |
| `planType` | enum? | `free go plus pro prolite team self_serve_business_* business ent26 enterprise_cbp_* enterprise edu unknown` |
| `rateLimitReachedType` | enum? | |

`RateLimitWindow`: `usedPercent` (int32, **required**), `windowDurationMins`
(int64?), `resetsAt` (int64? — **Unix seconds**).

Top level: `rateLimits` (required, single-bucket back-compat view),
`rateLimitsByLimitId` (map?), `rateLimitResetCredits`
(`{ availableCount, credits: [...]? }` — `null` means "count only", `[]` means
"fetched, none available").

> `credits` is an **object**, not a scalar. The spec draft implied a scalar.

### 3.5 Live measurement, 2026-08-18

ChatGPT Plus account, stdio transport:

```
initialize response            ~0.35 s
account/read                   ~1.2 s
account/rateLimits/read        ~3.2 s   (network round trip)
```

Response contained exactly **one** bucket (`codex`), `primary` only, window
`10080` minutes (weekly), `secondary: null`.

**Rendering rule confirmed by observation:** never hardcode "two windows",
never assume a 5-hour bucket exists, never label from position. Render whatever
buckets came back, keyed by `limitId`, labelled from `limitName` with a
`limitId` fallback, and sized from `windowDurationMins`.

**Reliability rule:** `account/rateLimits/read` took over 3 seconds. Every RPC
needs a hard deadline, and on timeout the child process must be **killed** —
otherwise the reader blocks forever.

### 3.6 Stability

`codex app-server` is labelled `[experimental]` in `--help`. Isolate it behind a
version-aware adapter, detect the Codex version, degrade to "limits unavailable"
rather than failing.

---

## 4. Claude Code limits — what is actually possible

There is **no** legal source for remaining Claude subscription quota:

| Source | Gives | Verdict |
|---|---|---|
| OpenTelemetry | tokens, sessions, cost, active time | ✅ legal, optional, **not** remaining quota |
| `statusLine` stdin `rate_limits` | quota | ⚠️ CLI TUI only — unavailable to a VSCode-extension user |
| `~/.claude/projects/**/*.jsonl` | tokens, cost | ⚠️ undocumented format |
| undocumented OAuth endpoints | quota | ❌ prohibited, see [tos-boundary.md](tos-boundary.md) |

The UI states plainly that remaining quota is unavailable for Claude Code. It
does not invent an estimate or draw a pseudo progress bar.

---

## 5. Local environment constraints

Observed on the developer's machine — the installer must handle these.

- **`~/.claude/settings.json` already carries five `claude-notifier-*.js` hooks**
  on `Stop`, `PermissionRequest`, `PreToolUse(AskUserQuestion)`,
  `UserPromptSubmit`, `SubagentStop`, plus `caffeine.sh` on `UserPromptSubmit`
  and `SessionEnd`. Decision: **peaceful coexistence** — AgentBar appends its own
  entries and never modifies or removes foreign ones. The installer *detects* and
  *reports* the overlap so duplicate notifications and competing power assertions
  are explainable rather than mysterious.
- **`~/.codex/config.toml` `notify` is taken** by Codex Computer Use (§2.7).
- **`~/.codex/hooks.json` does not exist yet** — the installer creates it and
  must handle both the create and the merge-into-existing case.
- `~/.codex/hooks/caffeine.sh` exists; same coexistence rule applies.
