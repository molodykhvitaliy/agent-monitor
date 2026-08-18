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

The module graph in `Package.swift` expresses this, and `Tests/ArchitectureTests`
enforces the part the graph cannot: a system framework needs no package
dependency, so nothing but a source-level check stops `import AppKit` appearing
inside AgentBarCore. See [build.md](build.md).

```swift
struct AgentEvent: Sendable {
    let provider: Provider          // .claudeCode | .codex
    let sessionId: SessionID
    let turnId: TurnID?
    let cwd: URL
    let project: ProjectRef         // resolved from cwd, worktree-aware
    let model: String?
    let kind: EventKind
    let tool: ToolRef?
    let toolUseId: ToolUseID?
    let agent: AgentRef             // .main, or a subagent
    let timestamp: Date
    let raw: RawPayload             // opaque, bounded, diagnostics only
}

enum EventKind: Sendable {
    case sessionStarted
    case turnStarted                               // a prompt was submitted
    case toolStarted
    case toolFinished
    case subagentStarted
    case subagentStopped
    case waitingInput
    case waitingPermission(PermissionRequestRef)   // reserved, backlog
    case turnFinished
    case failed(reason: String)
    case sessionEnded
}
```

The names describe what happened, not the state it produces: `turnStarted` is a
prompt being submitted, and it is `SessionStore` that decides this means the
session is now working. `RawPayload` is deliberately opaque — a bounded summary
line readable in a log, and nothing a caller can branch on, because raw provider
JSON stopping at the adapter is only true if the domain cannot read it.

### Project identity

`ProjectRef` is resolved from `cwd` through `ProjectResolving`. That protocol is
a seam, not decoration: deciding that `~/code/app/src` belongs to `~/code/app`
means finding a repository root, which is filesystem work the domain must not
do. `PathProjectResolver` is the answer available without touching the disk — it
normalises a trailing slash, an embedded `..` and the letter case a
case-insensitive volume ignores, and it treats a subdirectory as its own
project. A layer that owns I/O can inject a resolver that knows better and fill
in `worktree`; two worktrees of one repository stay two groups either way,
because they are two places to work.

### Time

`TimeSource` supplies both readings the domain needs, and keeping them apart is
the point. Every duration and every staleness decision comes from `now`, a
`MonotonicInstant`; `wallTime` is only for display and for stamping when
something was observed.

The production implementation is backed by **`ContinuousClock`**, which keeps
counting while the Mac is asleep. That is the property the watchdog needs: a
session that fell silent before a three-hour sleep must read as three hours
stale on wake. `SuspendingClock` stops during sleep and would resurrect every
stale session the moment the lid opens, and `Date` moves with NTP corrections
and manual clock changes.

## Session state machine

Keyed by `sessionId`, grouped for display by `project`.

```
sessionStarted (new session)    → idle
sessionStarted (known session)  → heartbeat only
turnStarted                     → working
toolStarted / toolFinished      → working  (heartbeat, current tool)
subagentStarted / subagentStopped → working, adjust subagent count
waitingInput                    → waitingInput
waitingPermission               → waitingPermission
turnFinished                    → idle, close open tools and subagents
failed                          → failed
sessionEnded                    → remove, record in history
silence beyond the allowance    → unknown, then evicted
```

A session first seen mid-flight is **adopted** rather than dropped: AgentBar is
usually launched while agents are already running. Only a farewell for an
unknown session is refused.

`sessionStarted` for a session already known is a heartbeat and nothing more. It
fires again on resume, clear, compact and fork, and compaction happens mid-turn
— resetting to `idle` would report every compaction as the agent having stopped.

### The two problems that must be solved explicitly

**Return from waiting.** After the user answers a permission prompt there may be
no "resumed" event. Recovery happens on the next `PreToolUse`, `PostToolUse` or
`UserPromptSubmit`. Do not wait for a dedicated signal that does not exist.

**Watchdog is mandatory.** A session that goes quiet becomes `unknown`, never a
permanent `working`. It must survive agent process death, helper failure,
machine sleep/wake, and sessions that never emit `SessionEnd`. Caffeine
correctness depends directly on this: a session stuck in `working` would keep
the Mac awake indefinitely.

How long silence is tolerated depends on what the session was doing, because
silence means something different in each state:

| State | Allowance | Why |
|---|---|---|
| working, no tool open | 15 min | a model can think and stream for minutes without touching a tool |
| working, tool open | 60 min | one `Bash` running a test suite or a full `xcodebuild` emits nothing for tens of minutes; calling that dead would drop the power assertion mid-build |
| waiting | 2 h | a human may be away, and the state stays true meanwhile |
| idle or failed | 8 h | nothing more is expected; this only decides when to stop claiming the session is there |
| unknown | 1 h | then the session is retired, or every agent that died without a farewell accumulates forever |

The two-tier treatment of `working` is the answer to "no events at all" versus
"no events but a long-running call is known to be open". Getting it wrong in the
generous direction costs a stale row and some extra wakefulness; getting it
wrong in the strict direction puts the Mac to sleep under a running build.

The generous tier is reached by having an open tool call, so a provider whose
tool events carry no identifier can reach it by accident: nothing can recognise
a repeated `toolStarted`, and the extra entry keeps `hasOpenTool` true until the
turn ends. A dead agent is then believed for an hour rather than a quarter of
one. Codex documents no `tool_use_id`, so its adapter should synthesise a stable
per-call id if the payload allows, and say so explicitly if it cannot.

### Reading and sweeping

**`unknown` is derived, never stored.** A record holds only states an event
produced; whether a session reads as `unknown` is decided from its silence every
time anyone asks. That is what makes a sign of life sufficient to undo the decay
— there is no stored state to climb back out of — and it is why the reading
handed to the UI and the sweep that acts on it cannot drift: both ask
`WatchdogPolicy.verdict` the same question about the same fact.

`SessionStore` owns no timer. `sweep()` reports what moved and retires the
sessions the watchdog has given up on, and whoever holds the run loop must call
it. What a missed sweep costs is the transitions and the retiring; every
session's state stays correct meanwhile, which the suite pins with a test
asserting a reading taken before a sweep equals the one taken after.

A session past the point of retirement still reads as `unknown` until a sweep
removes it, rather than quietly vanishing from an unswept store: a session that
disappeared without reaching the history would be one nothing can account for.

The `finished` list doubles as the guard against a late event reviving a session
that ended, which is why it has a floor of 32 entries. It is still bounded, so a
straggler for a session that has since been trimmed out of the history would be
admitted as a new one — accepted, because the alternative is a list of dead
session ids that grows for ever.

### Redelivery and reordering

Both are ordinary. Hooks are asynchronous and may be retried, and AgentBar
coexists with hooks the user already had, so a handler registered twice delivers
every event twice.

- **Duplicates** are recognised for tool calls, keyed on
  `sessionId + kind + toolUseId`. Nothing else is fingerprinted: subagents are
  counted in a set and transitions are idempotent, so the handling is already
  repeat-proof, while fingerprinting an id that can legitimately recur would
  swallow the second occurrence. What the ledger buys is the diagnostic — a
  stream of `duplicate` outcomes is how a doubly-installed hook makes itself
  visible.
- **Out-of-order** events do not move the state: a slow `PreToolUse` landing
  after the `Stop` that followed it would otherwise put a finished turn back to
  work. `sessionEnded` is the exception — terminal and idempotent, honoured late
  rather than leaving a ghost, unless it predates the session it would end.
- **An ignored delivery leaves no trace.** It proves a process is still
  posting, but it says nothing new, and the event it repeats or predates has
  already fed the watchdog. Letting it renew the clock would mean a session that
  refuses every delivery could be believed for ever — which is exactly what one
  badly stamped event would cause. Silence is measured in information, not in
  packets: the watchdog counts from the last event **applied**.
- **A timestamp from the future is refused.** Both providers run on this machine
  and the adapters stamp on receipt, so `AgentEvent.timestamp` must never be
  more than a few minutes ahead of the store's own clock. It is a high-water
  mark, and one bad value would make every genuine event after it look stale.
  Adapters owe the domain a per-session non-decreasing stamp taken from the
  receiving clock.
- **A finished session cannot be revived by a straggler.** The barrier is the
  newest event the session ever produced, not the farewell's own timestamp —
  a farewell honoured late is stamped below events already applied, and dating
  the end from it would leave exactly those events able to re-admit the session.
  Claude Code reuses a session id on resume, so anything stamped after the
  barrier is the session having come back, and starts a new record.

## Ingest

One loopback endpoint serves both providers. Claude Code posts to it directly;
the Codex helper relays to it over a Unix socket, falling back to the port.

### Addressing

The endpoint binds **`127.0.0.1` and nothing else** — never a name. A listener on
`127.0.0.1` does not answer on `::1`: that connection is refused outright,
verified on macOS 27. A client that resolves `localhost` to IPv6 first therefore
pays a failed round trip, or fails altogether if it does not fall back, so every
URL AgentBar writes into a hook configuration carries the literal address.

**A fixed preferred port with a short ladder, not an ephemeral one.** The Claude
Code hook URL lives in the user's `settings.json` beside an `allowedHttpHookUrls`
entry that has to match it, so a port drawn fresh on every launch means rewriting
a file the user owns on every launch. The preferred port is **47821** — below the
ephemeral floor of 49152 (`net.inet.ip.portrange.first`), so an unrelated
outbound connection cannot already be holding it — and the endpoint climbs to
47828 if something else is there. A move is reported, and the installer repairs
the URL once rather than continuously.

`endpoint.json` in the app support directory records the port actually taken, the
socket path and the *path* of the token file — never the token itself, because a
discovery file is the first thing anybody pastes into a bug report.

### Authentication

`Authorization: Bearer <token>` on every route, health included: an
unauthenticated 401 already proves something is listening, so exempting health
buys nothing and costs a probe. Authentication runs **before** the route table is
consulted, so the difference between 404 and 405 cannot be used to map what
exists. The token is 32 bytes from the system CSPRNG, base64url, stored `0600`
inside a `0700` directory, and compared in constant time.

The directory's permission does more work than the file's. A Unix socket is
created by the networking stack with the process umask applied — `0755` on a
default account — and the `chmod` that tightens it lands a moment later. A `0700`
directory is what makes that window harmless.

### What the endpoint answers

| Situation | Answer |
|---|---|
| accepted, decoded, applied | 200, empty |
| body that cannot be decoded | 200, empty |
| handler overran its deadline | 200, empty |
| missing or wrong token | 401 |
| unknown path | 404 |
| known path, wrong method | 405 |
| body past the limit | 413 |
| framing that cannot be read | 400 / 414 / 431 |

`IngestStatus` has no 5xx case at all, and the omission is the design. Claude
Code treats every non-2xx as a non-blocking error, so a 500 would not break an
agent — it would report our bug inside the user's transcript, on a path where
nothing we do should be visible. Anything unexpected degrades to the empty 200
that reads as "the hook had nothing to say".

### The reserved synchronous path

A handler returns a response *value* rather than the transport deciding one, and
`Deadline` bounds how long it may take — 750 ms by default, because Codex caps
`SessionEnd` at one second and Claude Code gives every `SessionEnd` handler a
1.5-second shared budget.

Two things about it were wrong on the first attempt, and both are worth keeping
written down because both look correct.

**The slot the answer lands in has to carry the answer.** The work and the timer
are unstructured tasks started before the caller waits, so an answer routinely
arrives before there is anybody waiting for it — a handler that returns without
suspending won that race about one time in five, measured. A slot that only
recorded *that* it had been filled turned every one of those into a reported
timeout. Today every handler answers `noOpinion` so nothing downstream noticed;
on the reserved path it would have meant discarding a decision a human had
already given and reporting that none was given.

**The deadline is deliberately not a task group.** A group waits for every child
before it returns, so a handler that ignored cancellation would delay the answer
exactly as long as if there were no deadline at all. `Deadline` hands back an
answer on the timer's own schedule and abandons the overrunning work. The
distinction is the entire point: this path exists for the Approve/Deny backlog
item, where the work being raced is a human deciding, and where the timeout has
to resolve to *no decision*. A deadline that could be outlasted would eventually
resolve to whatever the handler said late — which for a permission prompt is the
one outcome this project forbids.

### Transport facts worth not rediscovering

Each was established by experiment, and each would otherwise be a silent failure.

- `NWListener.newConnectionHandler` must be set **before** `start(queue:)`.
  Without it the bind fails with `EINVAL`, which reads like a bad address.
- A Unix listener does not remove its socket file when cancelled, and binding
  over a leftover one fails with `EADDRINUSE` exactly as if the endpoint were
  live. The two are told apart by connecting: a socket nobody is listening on
  refuses with `ECONNREFUSED`. AgentBar clears a dead one and refuses to take
  over a live one.
- `allowLocalEndpointReuse` stays off. Two AgentBars sharing one port would split
  an agent's events between them at random, and `EADDRINUSE` is the signal the
  ladder is built on.
- A Unix socket path is capped at 103 bytes (`sun_path`). Past that the endpoint
  serves TCP only and says so; the helper reads the port from the discovery file.

### Arithmetic on numbers a caller chose

A chunk size is a hexadecimal number the peer wrote, and it can be `Int.max`. The
natural way to check it against the body limit — `body.count + size <= limit` —
overflows on that input, and an overflow in Swift is a **trap, not an error**: it
aborts the process, past every `catch`, from a request that has not been
authenticated yet. It reached a live endpoint as a two-line kill switch before a
review found it.

The rule that falls out is worth more than the fix: **compare by subtracting from
the limit, never by adding to it**, wherever the number came from outside. The
same shape existed in `ByteBuffer.discard`. Both are covered by tests that trap
the process if the arithmetic is put back the other way round.

The same reasoning applies to text. Diagnostics are logged `.public` on purpose,
but a request target reaches the log *before* the token is checked, splitting the
head on CRLF leaves a bare newline inside a path intact, and a request line may be
kilobytes long — so caller-derived text is length-bounded and stripped of control
characters on its way into a message.

### Degradation

The Unix socket is allowed to fail on its own. It is the helper's shortcut rather
than the endpoint, and taking the whole endpoint down over a socket file in a bad
state would lose Claude Code's events with it.

Measured on the developer's machine over 300 requests: p50 0.21 ms, p95 0.55 ms,
p99 1.6 ms on a kept-alive connection, and p99 1.6 ms including connection setup.
Every one of those is three orders of magnitude inside the smallest budget either
agent gives a hook.

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
