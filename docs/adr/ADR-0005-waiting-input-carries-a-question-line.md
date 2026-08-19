---
id: ADR-0005
title: waitingInput carries one adapter-redacted question line
status: accepted
date: 2026-08-18
supersedes: null
superseded_by: null
tags: [domain, notifications, claude-code, design]
---

# ADR-0005 — `waitingInput` carries one adapter-redacted question line

## Context

Step 05 specified the interface and found one place where the design needs data
the domain cannot supply. The `Question` notification — the product's headline
event, "an agent asked you something" — is specified to carry the question as its
body, and nothing in AgentBar can produce that string.

Four independent reasons, each sufficient on its own:

- `SessionState.waitingInput` and `EventKind.waitingInput` carry no payload.
- `ClaudeCodeEventDecoder` never returns `.waitingPermission`, so no adapter
  produces a `PermissionRequestRef` — and `PermissionRequestRef.summary` is the
  only text field in the domain that could hold such a line. The slot is
  reachable (`NativeEventDecoder` decodes one off the wire) but nothing fills it.
- `ToolInvocation.summarise` returns `nil` for `AskUserQuestion`, by name and on
  purpose.
- `SessionStore.reading` clears `currentTool` outside `.working`, so even a tool
  reference attached to the waiting event would not reach the reading.

There is a second consequence that only surfaced under review. Both waiting paths
— `PreToolUse(AskUserQuestion)` and `Notification(permission_prompt |
elicitation_*)` — decode to the same `EventKind.waitingInput`, and the push signal
the UI observes, `StateChange`, carries only session, provider, project, from, to
and time. So the design's four notification verbs are not all selectable: without
a line, **`Question` cannot be distinguished from `Waiting` at all** by anything
above the adapter. The only available hint is `tool?.name == "AskUserQuestion"`, a
provider tool name that CLAUDE.md forbids anything above the adapter from
branching on.

## Decision drivers

- **The notification body is the product.** A notification whose body is empty on
  the one event AgentBar exists to report loses the last term of the design's
  *what → which agent → where → one line of detail* hierarchy.
- **The domain must stay provider-neutral.** Whatever carries the line must not
  let anything above the adapter branch on provider vocabulary.
- **Content must stay bounded.** A payload can carry an entire file;
  `RawPayload.summaryLimit` and `ToolInvocation.limit` exist because events are
  held for as long as their session is.
- **The panel is not a content-free surface** — `ToolRef.invocation` already
  renders the agent's own shell command verbatim — so "no user text in the UI" is
  not the constraint. The constraint is *bounded and redacted by the adapter*.
- Step 02 is complete. Reopening it needs a reason and a boundary.

## Considered options

### 1. Ship without a line

The Waiting row shows state and duration, the `Question` notification is
title-only, and every waiting event is titled `Waiting`.

Correct and honest, and it is what the design does until this ADR is
implemented — the row in particular is complete without a second line, since the
full-row tint is what makes it unmissable. But it permanently collapses two verbs
into one and leaves the notification saying only that *something* wants
attention, which is the state the status-bar icon already communicates.

### 2. Fill the line from Claude Code's `Notification.message`

The payload does carry `message` and `title`; the adapter currently reads
neither. Rejected on two grounds:

- It is **provider boilerplate** — "Claude needs your permission to use Bash" —
  and adds nothing the `Waiting` label does not already say.
- It exists on **only one of the two waiting paths**. The `Notification` route
  carries a message; `PreToolUse(AskUserQuestion)` carries none. A line that
  appears on one kind of waiting and not the other reads as a defect rather than
  as information.

### 3. Reach the line through `waitingPermission`

`PermissionRequestRef.summary` already exists for exactly this. But
`waitingPermission` is reserved for the Approve/Deny backlog item, and having the
MVP emit it would mean emitting a permission request AgentBar cannot answer —
which is the state the reserved case exists to *avoid* modelling prematurely.

### 4. One optional line on `waitingInput`

`EventKind.waitingInput` and `SessionState.waitingInput` gain a single optional
string, bounded and redacted by the adapter, produced by the same
`ToolInvocation` machinery and capped the same way as `ToolRef.invocation`.

## Decision

**Option 4.** `waitingInput` gains one optional, bounded, adapter-redacted line.

- `ToolInvocation` gains a rule for `AskUserQuestion`, reading the question out of
  `tool_input`. Today it returns `nil` for that tool by name, and that rule is
  precisely what changes.
- The `AskUserQuestion` path is the only path that gets a line. The permission and
  elicitation paths stay bare, and `Notification.message` is **not** read — see
  option 2.
- It is a **display** line. Not a second source of truth; nothing above the
  adapter may branch on it, and no state transition may depend on its presence or
  absence.
- The notification verb is chosen by the line's presence: a waiting notification
  with a line is titled `Question`, one without is titled `Waiting`.

Implemented in step 06. `ToolInvocation` reads
`tool_input.questions[0].question`, falling back to `header` — the shape Claude
Code `2.1.233` sends, confirmed against seven recorded local calls and against
`Tests/ClaudeCodeAdapterTests/Fixtures/pre-tool-use-ask-user-question.json`.

## Consequences

- `SessionState` gains an associated value on a case that had none, so every
  exhaustive switch over it is touched. `SessionStateKind` is unaffected, which is
  what the row and the icon key off.
- `docs/dev/architecture.md` documents `EventKind` and `SessionState` verbatim and
  must be updated when this lands.
- `WatchdogPolicy.silenceAllowance` switches over `SessionState`; a payload change
  must not alter its allowances.
- `SessionRecord.enter` compares whole states, so a session whose question line
  changed while already waiting would reset its state timer. That is acceptable —
  a new question is a new wait — but it is a behaviour change and needs a test.
- The line is unbounded at the source: it must be capped by the adapter, not by
  the view. The notification body clamps to about 60 characters besides.
- One more string joins the set that must never be logged.

## References

- `docs/dev/design-spec.md` § Obligations on later steps — the question line
- `docs/dev/design-brief.md` §4.3 — notification content hierarchy
- ADR-0001 — hooks as the integration foundation
- `Sources/AgentBarCore/SessionState.swift`, `Sources/AgentBarCore/AgentEvent.swift`
- `Sources/ClaudeCodeAdapter/ToolInvocation.swift`,
  `Sources/ClaudeCodeAdapter/ClaudeCodeEventDecoder.swift`
