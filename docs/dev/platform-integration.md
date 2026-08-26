# Platform Integration Reference

Verified facts about the extension surfaces AgentBar builds on.

**Verification date:** 2026-08-26 (§1 re-verified in full while building step 04;
`AskUserQuestion`'s `tool_input` shape added 2026-08-19 for step 06; §2
re-verified against the hook reference and local payloads on 2026-08-26; **§3
re-verified in full on 2026-08-19 while building step 10**)
**Verified against:** Claude Code `2.1.233`, Codex CLI `0.148.0`, macOS `27.0`

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
Session- and subagent-start: `SessionStart`, `SubagentStart`.
Main thread only: `SessionEnd` — *"It won't run for subagents."*

AgentBar installs nine of them: `SessionStart`, `UserPromptSubmit`,
`PreToolUse`, `PostToolUse`, `PermissionRequest`, `SubagentStart`,
`SubagentStop`, `Stop`, `SessionEnd`.

`PostToolUseFailure` is not in the 0.148 lifecycle list and is therefore not a
tenth installed handler. The decoder accepts that exact spelling defensively if
a client emits it, treating it as a completed tool call so an observed wait can
recover without exposing the provider name above the adapter.

Two absences, each a decision rather than an oversight:

- **`PreCompact` / `PostCompact` are not installed.** Compaction is not a state
  the panel shows, and every extra entry is another hook the user must review
  before *any* of them run.
- **`notify` is never written** — §2.7.

`SessionEnd` not firing for subagents is not a gap: a subagent is closed by
`SubagentStop`, and session removal is a main-thread event by definition.

### 2.2 Config discovery

Resolution order, **additive — higher layers do not replace lower ones**:

1. `~/.codex/hooks.json`  ← AgentBar writes only here
2. `~/.codex/config.toml` `[hooks]`
3. `<repo>/.codex/hooks.json`
4. `<repo>/.codex/config.toml` `[hooks]`
5. plugin-bundled `hooks/hooks.json`

*"If more than one hook source exists, Codex loads all matching hooks. Higher-
precedence config layers don't replace lower-precedence hooks."* And *"Multiple
matching command hooks for the same event are launched concurrently, so one hook
can't prevent another matching hook from starting."*

AgentBar **never writes `config.toml`.** This avoids TOML comment loss, avoids
the merge warning Codex emits when a layer has both representations, and — see
§2.7 — avoids destroying the user's existing `notify` entry. It is *read*, for
the two tables in §2.5.

Structure:

```json
{
  "description": "…",
  "hooks": {
    "EventName": [
      { "matcher": "…",
        "hooks": [ { "type": "command", "command": "…", "timeout": 600,
                     "statusMessage": "…", "async": false,
                     "additionalContextLimit": 2500 } ] }
    ]
  }
}
```

Only `type: "command"` is executable today. Commands run **through a shell**,
with the session `cwd` as their working directory — the entry already on this
machine relies on `"$HOME"` expanding — so AgentBar single-quotes the helper's
path rather than passing argv.

`async: true` runs a hook in the background, on every event except `SessionEnd`,
which *"always run[s] synchronously, even when `async` is `true`"*, and Codex
runs at most eight background hooks per session concurrently. **AgentBar does not
set it.** With a helper measured in milliseconds it buys nothing, and running
synchronously is what keeps `Stop` and `SessionEnd` in the order they happened.

`statusMessage` is shown to the user while the hook runs, and AgentBar does not
write one either: a monitor that announces itself on every tool call is not a
monitor.

**Matchers** are supported on `PreToolUse`, `PostToolUse`, `PermissionRequest`
(tool name), `PreCompact` / `PostCompact` (trigger), `SessionStart` (source),
`SubagentStart` / `SubagentStop` (subagent type) and `SessionEnd` (reason,
currently only `other`). They are **ignored** on `UserPromptSubmit` and `Stop`.
Every handler AgentBar installs is matcher-less.

### 2.3 Payload

A single JSON object on **stdin** (not argv — that is `notify`, §2.7).

Common to every event: `session_id`, `transcript_path` (nullable), `cwd`,
`hook_event_name`, `model`. Turn-scoped events add `turn_id`, and everything but
`SessionEnd` carries `permission_mode`.

| Event | Extra fields |
|---|---|
| `SessionStart` | `source` ∈ `startup \| resume \| clear \| compact` |
| `UserPromptSubmit` | `prompt` |
| `PreToolUse` | `tool_name`, `tool_use_id`, `tool_input` |
| `PostToolUse` | the above plus `tool_response` |
| `PermissionRequest` | `tool_name`, `tool_input`; `turn_id` when turn-scoped; optional `description` |
| `SubagentStart` | `agent_id`, `agent_type` |
| `SubagentStop` | the above plus `agent_transcript_path`, `stop_hook_active`, `last_assistant_message` |
| `Stop` | `stop_hook_active`, `last_assistant_message` |
| `SessionEnd` | `reason` — and **no** `turn_id`, **no** `permission_mode` |

> **Correction.** An earlier version of this file, and `architecture.md` with it,
> said Codex documented no `tool_use_id`. It documents one on both tool events,
> and the adapter reads it, so no synthesised identifier is needed.

`model` arriving on **every** event is the one place Codex is more generous than
Claude Code, where it comes only on `SessionStart` — an event that takes no
`http` handler and which AgentBar therefore cannot subscribe to.

Exit codes: `0` is success. **Exit code `2` blocks** on `PreToolUse`,
`PostToolUse` and `UserPromptSubmit`, with the reason read from stderr. The
helper therefore exits `0` on every path it has, including every failure.

Current local clients call the function tool `request_user_input` through the
already-installed `PreToolUse` hook. Its `tool_input.questions` is an array;
AgentBar reads the first non-empty `question`, falls back to `header`, and adds
the count of further questions. The exact provider tool name and nested JSON
remain inside `CodexAdapter`.

> **Not yet captured.** These shapes come from the documentation, not from
> recordings: a `command` hook does not run until a human trusts it, so a
> payload cannot be captured from a scripted run. `Tests/CodexAdapterTests/
> Fixtures/README.md` says so in the files themselves and describes the capture.

### 2.4 PermissionRequest decision format

AgentBar observes this hook immediately before Codex shows its normal approval
surface. It maps the payload to `waitingPermission`, with a local fingerprint
derived from `turn_id`, `tool_name` and canonical `tool_input`. That fingerprint
is state identity only; it is not a Codex request id and can never be used to
reply.

The notification summary prefers a non-credential-shaped `description`. Its
fallback is deliberately lock-screen-safe: only the executable and an
allowlisted harmless subcommand, or the final component of a path, may leave the
adapter. Opaque arguments, full paths and credential-shaped values fall back to
the tool name.

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

The helper emits **no stdout at all** for this event and exits `0`, exactly as
for every other event. With no hook decision Codex continues its normal approval
flow. AgentBar cannot approve, deny, rewrite or interrupt the request.

### 2.5 Trust — a product requirement, and where it is written down

> "Before a non-managed command hook can run, Codex requires you to review and
> trust the exact hook definition."

Trust is recorded against *"the hook's current hash, so new or changed hooks are
marked for review and skipped until trusted"*, and the user reviews them with
**`/hooks`**, which *"Codex prints a warning"* about at startup when anything is
pending. Managed hooks — system, MDM, cloud, `requirements.toml` — are trusted by
policy instead.

**Where the record lives — observed locally on 2026-08-19, not documented.**
`~/.codex/config.toml` gains a `[hooks.state]` table keyed by the entry's
position:

```toml
[hooks.state."/Users/dev/.codex/config.toml:user_prompt_submit:0:0"]
trusted_hash = "sha256:85fedc8a…"
```

The key is `<source file path>:<event in snake_case>:<group index>:<hook index>`.
An `enabled = false` may sit beside the hash: Codex lets a user switch an
individual non-managed hook off, which is trusted-and-still-inert, and a
different sentence from "not trusted". The installed `codex` binary carries the
matching strings — `hooks.state."`, `HookStateToml`, `trusted_hash`, `enabled`,
and "config/batchWrite failed while updating hook trust in TUI" — which is
consistent with the whole trust table being written through the config layer
regardless of which file the hook itself came from. **The key format for a hook
declared in `hooks.json` has not been observed** and is the first thing a capture
session should confirm.

**The hash is not reproducible from outside.** Four candidate pre-images were
tried against three live records — the raw command, the command with a newline,
the handler object as compact JSON, and several field orderings — and none
matched. AgentBar therefore never computes one; it reads the record's presence
and its `enabled` flag, and treats everything it cannot read as *not trusted*.

Two consequences for the product:

1. Writing `hooks.json` is not enough. Onboarding has to walk the user through
   `/hooks`, and the UI needs an explicit "installed but not yet trusted" state —
   otherwise the user gets a silently dead integration.
2. **Any change to the hook command invalidates trust.** Every AgentBar entry
   therefore names `~/Library/Application Support/AgentBar/bin/agentbar-helper`.
   The app atomically refreshes that AgentBar-owned copy from its signed bundle,
   so Debug, distribution and installed app copies share one command. The first
   migration from an app-bundle or DerivedData path needs one explicit Repair
   and `/hooks` review; subsequent app moves do not create drift.

`--dangerously-bypass-hook-trust` exists. AgentBar never uses it and never
suggests it; ADR-0008 records the decision. The flag is named only in prose —
here, in that ADR, and in `tos-boundary.md`'s checklist — and `make tos-check`
fails the moment it appears in code.

### 2.6 Timeouts

Default 600s — *"If `timeout` is omitted, Codex uses `600` seconds for most
hooks"* — and **`SessionEnd` uses 1 second by default and supports up to 3**. The
Codex helper must therefore be a compiled binary completing in single-digit
milliseconds, which alone rules out a Python or shell bridge.

AgentBar sets an explicit timeout on every handler it installs: 2 seconds
everywhere, 1 second on `SessionEnd`. Measured for the compiled helper on
2026-08-19, Release build, 40 runs against a live endpoint, spawn to exit:
**p50 6.5 ms on an idle machine and 11 ms under load**, against a `/bin/cat`
baseline of 1.0 ms and 1.8 ms through the same harness.

CI re-measures it on every code change through `make timing-proofs`, which runs
the helper against that same baseline in an otherwise idle process and asserts
both halves: the helper's own share stays inside 25 ms, and no single run passes
the one second above. Before that target existed the proof needed a built binary
nobody handed it, so it skipped itself and reported green — see
[build.md](build.md).

> **A hook's timeout is Codex's business, not the helper's.** Codex may or may
> not kill a command that overruns, and the helper is a grandchild of Codex
> behind the shell that runs it — so a helper that can wait indefinitely is a
> process that outlives the agent, is reparented to `launchd`, and keeps the
> session's working directory as its own. Verified on 2026-08-20: a writer that
> held the payload pipe open held the shipped helper open for exactly as long,
> with no upper bound. Every wait inside the helper is therefore bounded by the
> helper itself. The drain gives up after **150 ms of silence** and never runs
> longer than **400 ms** whatever the writer does; the relay carries its own
> 500 ms. Nine hundred milliseconds in the worst case, inside the one second
> Codex gives a `SessionEnd` hook. The drain's bounds are the ones that had to be
> added, and they measure silence rather than elapsed time because the worst
> legitimate payload — 4 MB through a 64 KB pipe — takes 93–105 ms on a loaded
> machine and would have sat too close to a total budget
> ([ADR-0013](../adr/ADR-0013-the-codex-helper-waits-on-a-deadline.md)).

### 2.7 notify — unavailable in practice

`notify` passes JSON as **argv[1]**, not stdin. It is a single-slot config key.

On this machine it is already occupied by *Codex Computer Use*. AgentBar treats
`notify` as **permanently unavailable** and must never write it. Hooks are the
only Codex event source.

This supports local Codex App, CLI and IDE sessions only where that client runs
the global lifecycle hooks. Codex Cloud does not execute a helper on this Mac and
is outside AgentBar's monitoring scope.

---

## 3. Codex App Server — limits

Source: <https://learn.chatgpt.com/docs/app-server> plus locally generated schema.

The protocol also contains approval and user-input **server requests**, but they
belong to threads driven through that client connection. A second App Server
process cannot passively observe Codex App, CLI or IDE sessions managed by other
connections. Making AgentBar the proxy that owns those sessions would violate
the safe-superset boundary, so lifecycle hooks remain the monitoring source;
App Server is used only for account limits.

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
prompted weekly by the `version-watch` workflow.

**The CI-side half exists now.** `scripts/generate-appserver-models.py` emits
`Sources/CodexAppServer/Generated` from the *checked-in* schema, and
`make check-generated` regenerates and asks git whether anything moved. That
needs neither Codex nor a network, so it runs on every change: the binary→schema
gap is caught locally, the schema→Swift gap is caught in CI, and a protocol
change cannot reach a release with stale models behind it.

Only three roots are generated — `GetAccountResponse`,
`GetAccountRateLimitsResponse`, `GetAccountTokenUsageResponse`. The v2 schema
carries 248 definitions and the rest have no owner here.

**`schema-sync.sh` was broken until 2026-08-19** and had been since it was
written: it ran `diff -ruq`, and BSD `diff` rejects `-u` together with `-q`
("conflicting output format options"), so the script reported drift on every run
whatever the schema said. Fixed to `diff -rq`, with the unified diff a separate
invocation. The schema itself had **not** drifted.

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

### 3.3 Handshake and wire format

`initialize` request → `initialized` notification → other methods.
`capabilities.experimentalApi` gates `process/*`, thread backgrounding and some
filtering — **not** needed for account methods.

Reproduced on 2026-08-19 against `0.147.0`:

| Fact | Evidence |
|---|---|
| **`"jsonrpc": "2.0"` is omitted on the wire.** Requests carry `id`/`method`/`params`; replies carry `id` plus `result` or `error` | documented — *"with the `"jsonrpc":"2.0"` header omitted on the wire"* — and confirmed by the binary |
| The handshake is enforced | a call before it answers `{"error":{"code":-32600,"message":"Not initialized"},"id":1}` |
| **`account/read` requires `params`** | omitting it answers `-32600 "Invalid request: missing field \`params\`"`; `{}` is accepted |
| `account/rateLimits/read` and `account/usage/read` take **no** `params` | schema declares `"params": {"type": "null"}` |
| An **unknown method** is `-32600`, not `-32601`, and **still carries the id** | the envelope fails against a closed enum of method names: `"unknown variant \`account/thisDoesNotExist\`, expected one of …"` |
| Replies arrive **out of order** | id 4 answered before id 3; id 79 before id 78. Correlation by id is mandatory |
| Notifications interleave from the first moment | `configWarning` and `remoteControl/status/changed` arrive before anything is asked for |
| A **garbage line does not kill the server** | a non-JSON line was ignored and the next request was answered normally |
| **Escaped forward slashes are accepted** | `account\/rateLimits\/read` — the form Foundation's `JSONEncoder` writes by default — was answered normally. AgentBar sets `withoutEscapingSlashes` anyway, to send what every other client sends |
| The Codex version is in the handshake | `initialize` replies with `userAgent: "AgentBar/0.147.0 (Mac OS 27.0.0; arm64) unknown (AgentBar; 0.1.0)"`, so no second process is needed to learn it |

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

### 3.5.1 Re-measured 2026-08-19

Same account, same transport, without the artificial pauses of the first run:

```
spawn → initialize reply       0.30 s
whole exchange to rateLimits   1.39 s
```

The 3.2 s figure stands as the pessimistic case; the budget is 20 s, which has to
cover a bad connection without ever becoming unbounded.

The reading itself: **one** bucket (`codex`), `limitName: null`, `primary` only,
`windowDurationMins: 10080`, `secondary: null`, `credits` an object
(`{hasCredits: false, unlimited: false, balance: "0"}`), `planType: "plus"`,
`rateLimitResetCredits: {availableCount: 0, credits: []}`.

### 3.5.2 Shutting the child down

Measured four ways, and the answer is not the obvious one:

| Method | Result |
|---|---|
| close stdin, idle | exits 0 in **0.04 s** |
| close stdin, RPC in flight | exits 0 in **2.74 s** — it finishes answering first |
| `SIGTERM`, idle | dies in **0.00 s** |
| `SIGTERM`, RPC in flight | dies in **0.01 s** |

So `Process.terminate()` is the shutdown and closing stdin is the courtesy before
it, not the other way round: waiting politely for an in-flight request to finish
would leave a child alive across a quit. `SIGTERM` is enough, which means no
`SIGKILL`, which means **no `import Darwin`** in `CodexAppServer` and no widening
of the socket guard in `ModuleBoundaryTests`.

Closing stdin also covers the case AgentBar cannot: if the app is force-quit
mid-exchange, the pipe's write end closes with the process and the child exits on
its own within those 2.74 s.

**The reverse direction raises `SIGPIPE`.** `Process` closes the parent's copy of
the stdin pipe's *read* end at spawn — which is what makes closing the write end
give the child EOF — so a write after the child has exited goes into a pipe with
no reader. That raises `SIGPIPE`, and a signal is not something a `catch` can
answer: reproduced by removing the guard, where the test process died with
signal 13. The window is real rather than theoretical, because a child that fails
on a bad `config.toml` writes to stderr and exits, and the very next thing the
exchange does is send `initialize`. `CodexProcessTransport` marks stdin
unwritable the moment the child's output ends.

### 3.5.3 Finding the binary

`codex` is at `~/.local/bin/codex` on the developer's machine (a symlink into
`~/.codex/packages/standalone/current/bin`). `launchctl getenv PATH` is **empty**,
so an app launched from the Finder or at login comes up with
`/usr/bin:/bin:/usr/sbin:/sbin` and `codex` is on none of it.

A build that trusted `PATH` would work perfectly from a terminal and find nothing
once installed — the worst way for this to fail. Discovery is therefore: a
defaults override, then the directories Codex installs into, then `PATH`.

### 3.6 Stability

`codex app-server` is labelled `[experimental]` in `--help`. Isolate it behind a
version-aware adapter, detect the Codex version, degrade to "limits unavailable"
rather than failing.

**Version-aware is not the same as a version floor.** The only floor anybody
could name is the version this was verified against, and refusing to try below it
would break users on a Codex that works while buying nothing. The server answers
the question exactly, in one round trip, by rejecting a method it does not
implement — so AgentBar asks, remembers the answer **against the version string
from the handshake**, and forgets it the moment the user updates.

The account methods are **not in the prose documentation** at all
(<https://learn.chatgpt.com/docs/app-server> describes the transport, the
handshake and the thread API, and mentions none of `account/*`). The schema
shipped with the binary is the only contract there is, which is the whole
argument for generating the models from it.

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

---

## 6. macOS notifications

Verified by experiment on macOS 27.0 (build 26A5416b), 2026-08-19, against the
real AgentBar bundle. Every one of these fails **silently** when it is got
wrong, which is why they are recorded rather than left to be rediscovered.

### 6.1 Where a notification sound may live

`UNNotificationSound(named:)` resolves a **file name**, not a path, and it looks
in exactly two places:

| Location | For AgentBar |
|---|---|
| The app bundle's own resources | `AgentBar.app/Contents/Resources/*.aiff`, at the **top level** — not a `Sounds/` subfolder |
| `Library/Sounds` of the app's container | `~/Library/Sounds` — an unsandboxed app has no container, so this is the real one |

**`/System/Library/Sounds` is not one of them.** A selection named `Glass.aiff`
therefore resolves to nothing, and the initialiser reports nothing: it returns a
sound object whatever it is handed, and the system substitutes the default at
play time. There is no error, no log line and no API to ask.

That single fact shapes the whole sound matrix. AgentBar does not offer a system
sound as a choice it cannot honour; it offers to **copy** one into
`~/Library/Sounds`, where it works — see
[ADR-0006](../adr/ADR-0006-notification-sounds-are-files-agentbar-can-resolve.md).

Container formats: `aiff`, `wav`, `caf`. Encoding: Linear PCM or IMA4. Length:
**strictly under 30 seconds** — at exactly thirty the system already substitutes
the default. All four are checked with `AudioFileGetProperty` before a sound is
offered and again before it is sent, because `~/Library/Sounds` is the user's own
folder and can be emptied between the two.

`make verify-bundle` asserts the four bundled sounds are at the top of
`Contents/Resources`. Without that assertion a resource phase that quietly
stopped copying them would ship a matrix whose every default silently plays the
system sound.

### 6.2 `.timeSensitive` needs a provisioning profile

`com.apple.developer.usernotifications.time-sensitive` needs no approval from
Apple — but it does need a **provisioning profile**. Adding it to
`AgentBar.entitlements` makes `xcodebuild` fail outright:

```
error: "AgentBar" requires a provisioning profile. Enable development signing
and select a provisioning profile in the Signing & Capabilities editor.
```

That would cost a clean checkout its ability to build with no Apple Developer
account, which is what `CODE_SIGN_IDENTITY = "-"` exists to protect (ADR-0003).
The entitlement is therefore **deliberately absent** and belongs to step 12,
which introduces Developer ID signing.

The notifications still set `interruptionLevel = .timeSensitive`. An unentitled
app has the level silently downgraded to `.active`, so nothing is lost but the
privilege of breaking through Focus. `.critical` is never requested at all: it is
for health and safety, and it does need Apple's approval.

### 6.3 The first-launch authorisation trap

**Requesting authorisation from a bundle in `DerivedData` fails, and the failure
is recorded permanently against the bundle identifier.**

```
UNErrorDomain Code=1 "Notifications are not allowed for this application"
```

Afterwards `authorizationStatus()` returns `denied` for that identifier for ever
— re-signing, `lsregister -f`, reinstalling to `/Applications`, deleting the
DerivedData copy and restarting `usernoted` all leave it denied. The only route
back is System Settings › Notifications, where the app now appears switched off.

An ad-hoc signature is **not** the problem. The same bundle built with a fresh
identifier (`com.molodykhvitalii.AgentBarProbe`), copied to `/Applications`,
ad-hoc signed and registered with `lsregister -f`, showed the ordinary system
prompt on first launch. What matters is where the app is when it first asks.

Consequences, all of them acted on:

- **Never run AgentBar straight out of `DerivedData`** if it will ever need
  notifications. `make build && cp -R … /Applications/` first.
- The settings window shows the authorisation state and offers **Open System
  Settings** when the answer is `denied`, because a refusal cannot be re-prompted
  from inside the app.
- `NotificationRouter.start()` logs the status it found on every launch, whether
  or not it asked. A launch that silently decides not to ask is otherwise
  indistinguishable from one that failed to start.

---

## 7. macOS power assertions

Verified by experiment on macOS 27, 2026-08-19, step 08. The header is
`IOKit/pwr_mgt/IOPMLib.h`; every claim below was checked against a running
process and `pmset -g assertions`, not read off it.

### 7.1 What imports, and how

`kIOPMAssertionTypePreventUserIdleSystemSleep` and the other assertion-type
macros arrive in Swift as **`String`**, so every call site needs `as CFString`.
`kIOPMAssertionLevelOn` and the `IOReturn` constants import as integers.

**`IOPMAssertionSetTimeout` does not exist in the SDK**, whatever an older
example may suggest. A lease is set through the properties dictionary at
creation and re-armed with `IOPMAssertionSetProperty`.

Releasing an assertion twice returns `kIOReturnBadArgument` (`0xE00002C2`,
`-536870206` as `Int32`). It does not trap, but it is worth not doing: the
holder in `IOKitPowerAssertion` drops its id before checking the result, so a
failed release cannot leave it refusing to take a new assertion for ever.

### 7.2 The lease, and why `TurnOff`

`IOPMAssertionCreateWithProperties` accepts `kIOPMAssertionTimeoutKey` (seconds,
as a `CFNumber`) with `kIOPMAssertionTimeoutActionKey`. AgentBar uses
**`kIOPMAssertionTimeoutActionTurnOff`**, and `pmset -g assertions` then reports
the countdown alongside the assertion:

```
pid 84906(AgentBar): [0x0000431a000199de] 00:00:01 PreventUserIdleSystemSleep named: "AgentBar"
	Details: 1 agent session working in agent-monitor
	Timeout will fire in 149 secs Action=TimeoutActionTurnOff
```

Observed, in order:

- Re-arming **before** expiry, with `IOPMAssertionSetProperty(id,
  kIOPMAssertionTimeoutKey, n)`, resets the countdown and returns
  `kIOReturnSuccess`.
- On expiry the assertion stops holding and **disappears from `pmset -g
  assertions`** entirely — it is not listed as an inactive entry.
- Re-arming **after** expiry turns it back on, with the same id still valid.
  This is why `TurnOff` is preferred to `TimeoutActionRelease`: a recovery needs
  no bookkeeping about whether the id is still real.
- A timeout of `0` means *no* timeout. `IOKitPowerAssertion` clamps to one
  second so a rounding accident cannot turn the safety net into a permanent
  assertion.

`kIOPMAssertionDetailsKey` can be set at creation and updated later through the
same `IOPMAssertionSetProperty`. It is what makes the state diagnosable from
outside the app, so it carries a plain-English reason rather than a code.

### 7.3 What the assertion does and does not do

`PreventUserIdleSystemSleep` stops the **idle** timer putting the system to
sleep. It does not keep the display awake — that is
`PreventUserIdleDisplaySleep`, which AgentBar deliberately does not take — and
**no assertion type survives the lid closing**. macOS also sleeps on low battery
regardless. All three limits are stated in the settings window's `Caffeine`
section, because a keep-awake feature that quietly does less than the user
believes is worse than none.

Killing the process with `SIGKILL` releases the assertion immediately: verified
by `kill -9` against a running AgentBar holding one. That property is the whole
argument against shelling out to `/usr/bin/caffeinate`, whose subprocess can be
orphaned instead — see
[ADR-0007](../adr/ADR-0007-caffeine-is-a-leased-process-owned-assertion.md).

---

## 8. The app icon — Icon Composer documents

Verified 2026-08-19 against Xcode 26.6 / macOS 27.0, by rendering with
`ictool` and by compiling with `actool` through `make build`.

macOS 26 draws an app icon in more appearances than a bitmap can answer for:
light, dark, a tinted menu bar and a clear treatment, each with the system's own
depth, shadow and specular pass. A flat `.icns` gets pasted into all of them. The
format that answers is a **layered Icon Composer document** — `AgentBar.icon`,
committed at `Apps/AgentBar/AgentBar.icon` and compiled by `actool` into
`Assets.car` alongside a generated `AgentBar.icns` for anything that still wants
one.

### 8.1 The document is a package with a fixed layout

```
AgentBar.icon/
├── icon.json        the document
└── Assets/          the layer artwork, SVG
```

**`Assets` is case-sensitive, on a case-insensitive filesystem.** Renaming it to
`assets` makes `ictool` render the tile with no mark on it at all — background,
shadow and specular, and nothing else — and `actool` throw
`attempt to insert nil object from objects[0]` rather than say what is wrong.
This is the trap the layout has: everything else about the document is still
valid, so nothing points at the folder. `make verify-bundle` asserts every layer
by name in the compiled `Assets.car` for that reason.

### 8.2 `icon.json`

```json
{
  "fill" : { "linear-gradient" : [ "extended-srgb:R,G,B,A", "extended-srgb:R,G,B,A" ] },
  "groups" : [ { "layers" : [ { "image-name" : "apex.svg", "name" : "apex" } ] } ]
}
```

- `image-name` carries the **extension**. Without it the layer is silently absent.
- **Layers are front to back.** The first entry in `layers` is the topmost one —
  the opposite of how a painter's algorithm reads, and the difference between the
  design's accent node sitting on the edges and hiding behind them.
- A linear gradient takes **exactly two** colours; the framework says so.
- `supported-platforms` is `{"circles": [], "squares": ["macOS"]}` here. AgentBar
  is macOS-only and the document should not claim otherwise.

### 8.3 Rendering it without opening the app

`ictool` ships inside Icon Composer and exports any rendition to a PNG, which is
the whole verification loop for a document authored by hand:

```bash
ictool Apps/AgentBar/AgentBar.icon --export-image \
  --output-file /tmp/icon.png --platform macOS \
  --rendition Default --width 512 --height 512 --scale 1
```

Valid renditions, from the tool's own error text: `Default`, `Dark`, `Light`,
`TintedLight`, `TintedDark`, `ClearLight`, `ClearDark`, `Mono`. `Tinted` and
`Clear` on their own are not names. The binary is at
`/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool`.

### 8.4 `LSUIElement` does not mean the icon is unused

AgentBar has no Dock icon, and the icon still appears in Finder and Get Info, in
Spotlight, in the login-items list, in System Settings › Notifications, and in
the leading slot of every banner AgentBar posts — which is also why step 07 could
drop the notification attachment's corner badge: the system was already showing
this icon three centimetres away.
