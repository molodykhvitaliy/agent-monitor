# Platform Integration Reference

Verified facts about the extension surfaces AgentBar builds on.

**Verification date:** 2026-08-18 (§1 re-verified in full while building step 04;
`AskUserQuestion`'s `tool_input` shape added 2026-08-19 for step 06)
**Verified against:** Claude Code `2.1.233`, Codex CLI `0.147.0`, macOS `27.0`

> **Precedence rule.** Official platform documentation wins over this file, and
> this file wins over the original `.scratch/notes/INITIAL_SPEC.md`. Every claim
> below was checked against primary sources or reproduced locally on the
> verification date. Re-verify with the `platform-docs` skill before starting any
> step that touches an adapter.

---

## 1. Claude Code hooks

Source: <https://code.claude.com/docs/en/hooks> — re-read in full on 2026-08-18
while building the adapter. Several claims in the previous version of this
section were wrong; they are corrected below and the wrong ones are named so
they do not come back.

### 1.1 Handler types

`command`, `http`, `mcp_tool`, `prompt`, `agent`.

AgentBar uses **`http` exclusively**. The engine performs the POST itself, so no
process is spawned per event — this matters because `PreToolUse` fires on every
single tool call.

> **Two events do not accept an `http` handler at all.** `SessionStart` and
> `Setup` support **only** `command` and `mcp_tool`: *"SessionStart runs on every
> session, so keep these hooks fast. Only `type: "command"` and
> `type: "mcp_tool"` hooks are supported."* Every other event accepts `http`.

> **`async` does not exist for `http` handlers.** *"Add `"async": true` to a
> command hook's configuration to run it in the background without blocking
> Claude. This field is only available on `type: "command"` hooks."* An `http`
> hook therefore **blocks the agent until the endpoint answers or the timeout
> fires**. The plan's "every hook is `async: true`" was not achievable; see
> §1.6 for what upholds the guarantee instead.

### 1.2 Events AgentBar subscribes to

Every handler is `type: "http"` with an explicit `timeout`.

| Event | Matcher | Timeout | Becomes |
|---|---|---|---|
| `UserPromptSubmit` | — | 2 s | `turnStarted` |
| `PreToolUse` | — | 2 s | `toolStarted`, or `waitingInput` for a tool that asks |
| `PostToolUse` | — | 2 s | `toolFinished` |
| `PostToolUseFailure` | — | 2 s | `toolFinished` |
| `Notification` | `permission_prompt\|elicitation_dialog\|elicitation_url_dialog` | 2 s | `waitingInput` |
| `SubagentStart` / `SubagentStop` | — | 2 s | subagent counter |
| `Stop` | — | 2 s | `turnFinished` |
| `StopFailure` | — | 2 s | `failed` |
| `SessionEnd` | — | 1 s | `sessionEnded` |

Three deliberate differences from the original plan, each with a reason:

- **No `SessionStart`.** It takes no `http` handler (§1.1). Nothing is lost
  except `model`, which no other event carries: `SessionStore` adopts a session
  on whatever event reaches it first, so a session still appears the moment it
  does anything.
- **`PostToolUseFailure` added.** *"PostToolUse — Runs immediately after a tool
  completes successfully."* A tool that throws fires `PostToolUseFailure`
  instead, so without it a failed call is never closed and the row keeps showing
  a tool that stopped running.
- **No `idle_prompt`.** See §1.7 for why it does not mean "waiting for input".

Reserved for the Approve/Deny backlog item, not installed in the MVP:
`PermissionRequest` (synchronous).

**`WorktreeCreate` must never be installed.** Configuring it *replaces* Claude
Code's own worktree creation — *"Because the hook replaces the default behavior
entirely… The hook must return the path to the created worktree directory"* —
which would make AgentBar responsible for a feature it only wants to watch, and
a failure of ours would fail the user's worktree. This is the safe-superset rule
in its sharpest form.

### 1.3 Payload fields

Common to every event:

```
session_id, prompt_id, transcript_path, cwd, permission_mode, hook_event_name
```

`permission_mode` ∈ `default | plan | acceptEdits | auto | dontAsk |
bypassPermissions`, and *"Not all events receive this field"* — `StopFailure`
and `SessionEnd` were observed without it.

`effort { level }` is **not** universal despite the previous version of this
file: *"Present for events that fire within a tool-use context, such as
`PreToolUse`, `PostToolUse`, `Stop`, and `SubagentStop`, when the current model
supports the effort parameter."* A Haiku capture carried none; a live VS Code
session on `xhigh` carried it on every tool event.

`agent_id` / `agent_type` appear **only in subagent context**, which is exactly
how a main-thread event is recognised. A subagent's own tool events carry the
parent's `session_id` and the subagent's `agent_id` — verified in a recorded
session.

Per-event fields, all verified against recorded payloads unless marked:

| Event | Extra fields |
|---|---|
| `SessionStart` | `source`, `model` (optional), `agent_type`, `session_title` |
| `UserPromptSubmit` | `prompt` |
| `PreToolUse` | `tool_name`, `tool_input`, `tool_use_id` |
| `PostToolUse` | the above plus `tool_response`, `duration_ms` |
| `PostToolUseFailure` | `tool_name`, `tool_input`, `tool_use_id`, `error`, `is_interrupt`, `duration_ms` |
| `Notification` | `notification_type`, `message`, `title` |
| `SubagentStart` | `agent_id`, `agent_type` |
| `SubagentStop` | the above plus `agent_transcript_path`, `last_assistant_message`, `stop_hook_active` |
| `Stop` | `last_assistant_message`, `stop_hook_active`, `background_tasks`, `session_crons` |
| `StopFailure` | `error`, `error_details`, `last_assistant_message` |
| `SessionEnd` | `reason` |

> **Names the previous version of this file got wrong**: `tool_result` (it is
> `tool_response`), `session_start_type` (it is `source`), `session_end_reason`
> (it is `reason`), `error_type` (it is `error`). Paraphrase is how these enter.

> **No payload carries a timestamp.** `prompt_id` is a UUID and orders nothing.
> Receipt time is not merely the safe stamp, it is the only one available.

`tool_input` is the tool's own arguments, verbatim. One shape inside it is
load-bearing, because ADR-0005 reads a display line out of it:

```json
"tool_input": { "questions": [
  { "question": "…", "header": "…", "multiSelect": false,
    "options": [ { "label": "…", "description": "…" } ] } ] }
```

Verified 2026-08-19 against seven `AskUserQuestion` calls recorded by Claude Code
`2.1.233` in `~/.claude/projects/*.jsonl`; `questions` is always an array and
always carries `question` and `header`. `ToolInvocation` reads
`questions[0].question`, falls back to `header`, and degrades to no line at all —
a shape change makes the row less informative, never broken.

> **There is no `worktree` field anywhere.** `WorktreeCreate` cannot be used to
> observe one (see §1.2), `WorktreeRemove` fires only for worktrees a hook
> created, and `CwdChanged` carries only `old_cwd` and `new_cwd`. `cwd` is the
> whole signal; attributing a worktree to its repository needs git metadata and
> therefore a `ProjectResolving` that is allowed to read the disk.

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

Also documented, and re-read on 2026-08-18:

- **All matching hooks run in parallel**, and *"If you define the same handler in
  more than one settings file, it runs once."*
- **There is no retry.** A hook that fails is not re-sent, which is why a body
  AgentBar cannot decode is still answered 200 and recorded as a diagnostic.
- **A 2xx JSON body that fails schema validation is a non-blocking error**, and
  HTTP hooks cannot signal a blocking error through status codes at all.

Configuration keys:

- `allowedHttpHookUrls` — *"When defined at any settings level, Claude Code only
  runs an HTTP hook handler if its `url` matches the merged allowlist… Matching
  is exact string comparison."* Three consequences.

  **AgentBar extends this list and never creates it.** An absent key permits
  every http hook, so AgentBar's handlers run without one. *Defining* the key
  switches allow-listing on at every settings level at once, which would stop an
  http hook in a project's own settings that AgentBar cannot see — and would go
  on stopping it after AgentBar was uninstalled, because an uninstaller cannot
  tell an entry it copied in from one the user added. Creating it is a policy
  change, and the installer does not make policy changes.

  **A list next door still counts.** The lists merge across levels, so
  `~/.claude/settings.local.json` defining one governs the handlers written to
  `settings.json` — and an entry written to `settings.json` satisfies it. The
  installer reads the sibling for exactly this reason. A list defined in a
  *project's* or a managed policy's settings is invisible from here, which is
  the one case where AgentBar can be installed and receive nothing; the install
  report warns whenever any visible list is in effect.

  **Matching is exact**, so a moved port means the entry has to be repaired
  rather than pattern-matched.
- `httpHookAllowedEnvVars` — a second allow-list for header interpolation; only
  variables in **both** it and a handler's own `allowedEnvVars` are substituted.
  **AgentBar does not write it.** Defining it would restrict interpolation for
  the user's other http hooks, which is a change to somebody else's behaviour.
- per-handler `headers`, with `$VAR` interpolation gated by `allowedEnvVars`.
  *"References to unlisted variables are replaced with empty strings."*

> **How the token reaches the header — decided in step 04.** Written literally
> into `settings.json`. The environment route was rejected: a GUI app cannot
> guarantee the variable is exported into whatever launches the agent, and a
> missing variable interpolates to an empty string, turning every hook into a
> visible non-blocking error. See [ADR-0004](../adr/ADR-0004-hook-token-in-settings-file.md).

### 1.6 Timeouts

Default 600 s for `command` / `http` / `mcp_tool`; `UserPromptSubmit` lowers it
to 30 s, `MessageDisplay` to 10 s. AgentBar sets an explicit `timeout` on every
handler and never inherits a default.

`SessionEnd` handlers **share a 1.5-second budget**, raised to the largest
explicit per-hook timeout in the settings files, up to 60 s. AgentBar sets 1 s
there: explicit, and too small to lengthen the budget for the user's own
`SessionEnd` hooks.

**What upholds "AgentBar never delays an agent", now that `async` is
unavailable:** the endpoint answers in 1.6 ms at p99, a connection to a loopback
port nobody is listening on is refused immediately, and every handler carries a
2-second ceiling. The only case that can actually stall is another process
holding the port, accepting the connection and never answering — bounded to two
seconds, once per event, and reported by `IngestDiagnostic.portMoved` the moment
the ladder notices.

A timed-out hook is cancelled and renders no decision. On `PreToolUse`
specifically, *"A timed-out `command`, `http`, or `mcp_tool` hook doesn't block
the tool call."*

### 1.7 Matchers

Matchers are exact strings, `|`/`,` lists, or unanchored JavaScript regex if any
other character is present. Per-event matcher domains that matter to us:

- tool events → tool name
- `SessionStart` → `startup | resume | clear | compact | fork`
- `SessionEnd` → `clear | resume | logout | prompt_input_exit | other`
- `SubagentStart` / `SubagentStop` → agent type, plugin-scoped as
  `plugin-name:agent-name` — a colon puts the value on the regex path, so an
  exact match needs `^` and `$`
- `StopFailure` → `rate_limit | overloaded | authentication_failed |
  oauth_org_not_allowed | billing_error | invalid_request | model_not_found |
  server_error | max_output_tokens | unknown`
- `Notification` → see below

**Notification timing, which decides what each type actually means:**

| Type | Fires |
|---|---|
| `permission_prompt` | about six seconds after a permission request nobody has answered |
| `idle_prompt` | about sixty seconds after Claude finished responding, and only if nobody has typed since |
| `elicitation_dialog` / `elicitation_url_dialog` | six seconds after an MCP server opens a form |
| `agent_needs_input` / `agent_completed` | background sessions, **only while agent view is open in a terminal** |
| `auth_success` | authentication completes |

Every type name above is quoted from the documented matcher table. Only
`permission_prompt` and `idle_prompt` have been observed on this machine; the two
`elicitation_*` names AgentBar installs are documented and unobserved, so if they
are ever wrong the handler is registered and simply never fires — a silent
degradation rather than a fault, and worth re-checking the first time an MCP
server raises one.

> **Answering the step's research question:** `idle_prompt` does **not** mean
> "waiting for input". It describes a human who walked away from a session that
> `Stop` already moved to idle a minute earlier, so mapping it to `waitingInput`
> would relabel every idle session. AgentBar does not install it.
>
> `permission_prompt` is the one that means blocked-on-a-human, and in the VS
> Code extension it behaves *differently* from the terminal: the extension hosts
> Claude Code through the Agent SDK's `canUseTool` callback, where the
> notification fires about six seconds after the ask and is **not** deferred by
> typing. *"Before v2.1.233, `permission_prompt` didn't fire in these
> sessions."* We verified against exactly 2.1.233, so this is the first version
> where a VS Code user gets it at all — and a user on an older build will see no
> waiting state from this source.
>
> The gap that leaves is a tool that blocks on a person without going through
> permissions: `AskUserQuestion`. Nothing notifies for it, so the adapter maps
> `PreToolUse` for that tool to `waitingInput` directly. The user's own
> `claude-notifier-on-question.js` hook is on the same event for the same
> reason.

`PermissionDenied` fires **only in auto mode** — not on a manual denial, a
`PreToolUse` block, or a deny rule — so it cannot be used to close a tool call
that was refused. A refused call stays open until the turn ends, where
`finishTurn()` clears everything.

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
