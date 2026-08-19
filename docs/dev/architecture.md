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
    case waitingInput(question: String?)            // one bounded display line
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

`waitingInput`'s line is the one exception to "no content above the adapter", and
it is a narrow one ([ADR-0005](../adr/ADR-0005-waiting-input-carries-a-question-line.md)):
the question an agent asked, bounded and redacted by the adapter that produced
it, carried through to `SessionState.waitingInput` so the row and the
notification can render it. It is a display value — nothing branches on it, no
transition depends on it, and no watchdog allowance moves with it. Only the
`AskUserQuestion` path fills it; a permission prompt's own `message` deliberately
does not, because it is provider boilerplate present on one waiting path and not
the other.

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
waitingInput                    → waitingInput (carrying its question line)
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
one. **Both providers do carry one.** An earlier version of this file said Codex
documented no `tool_use_id`; the hooks reference lists it on `PreToolUse` and
`PostToolUse`, and `CodexEventDecoder` reads it, so no synthesised identifier is
needed. If a capture ever contradicts the documentation the field simply goes
absent, and the generous tier is what a Codex session gets by accident — the
direction that keeps the Mac awake under a build rather than asleep.

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

## The Claude Code adapter

The first adapter, and the shape the Codex one follows. It owns two jobs that
look unrelated and are not: the payloads Claude Code sends, and the file that
makes it send them.

### The one edge that does not point straight at the core

`ClaudeCodeAdapter` depends on **AgentBarIngest** as well as AgentBarCore.
`EventDecoding` is the seam the ingest layer publishes for adapters, and
implementing it where the payload knowledge already lives is what keeps the
stronger invariant true — that raw provider JSON stops at the adapter. The
alternative, a pure function in the adapter and a conformance in the app target,
spreads one seam across three modules to preserve a rule written before the seam
existed, and puts the glue somewhere `swift test` does not reach.

`ModuleBoundaryTests` records the edge explicitly. No adapter depends on another
adapter, and nothing imports `Network` outside AgentBarIngest.

### What the decoder decides

The mapping is in `ClaudeCodeEventDecoder`. Four decisions in it are not
mechanical:

- **`PostToolUseFailure` closes a tool call, exactly like `PostToolUse`.**
  `PostToolUse` fires only on success, so subscribing to it alone leaves a failed
  call open for the rest of the turn and the row showing a tool that stopped
  running.
- **`PreToolUse` for `AskUserQuestion` is `waitingInput`, not `toolStarted`.**
  That tool exists to block on a person, and nothing else in Claude Code
  announces it: `Notification` covers permission prompts, and `Stop` has not
  happened. Without the special case, "an agent asked you a question" — one of
  the three things AgentBar exists to say — reads as ordinary work until the
  watchdog gives up. The set of such tools is injectable rather than hard-coded.
- **`Notification/idle_prompt` is ignored.** It fires a minute after `Stop`
  already moved the session to idle, and only if nobody has typed since. It
  describes the human, not the agent.
- **Every event is stamped on receipt.** No Claude Code payload carries a
  timestamp and `prompt_id` is a UUID, so there is nothing better available —
  and a stamp a caller chose is a stamp that can freeze a session in `working`
  for ever.

The invocation line a row shows is built per tool from the identifying argument —
a command, a path, a pattern — and never from content. `Write` and `Edit` arrive
with the whole file in `tool_input`; only the path survives. The diagnostic
summary that goes into `RawPayload` is narrower still: an event name and a
discriminator, nothing a person typed, because a diagnostic is the thing most
likely to be pasted into a bug report.

### The installer, and the file it does not own

`~/.claude/settings.json` belongs to the user, so the installer holds three rules
everywhere:

1. **Never rewrite what it could not read.** A settings file that fails to parse
   is left exactly as it is, and the error says so.
2. **Never write when nothing would change.** Install builds the document it
   wants and compares it with the one it read; equal means no write, no backup,
   no mtime change. That is what makes a second install a genuine no-op rather
   than an idempotent-looking one.
3. **Never rewrite what it would have to guess at.** `hooks` and
   `allowedHttpHookUrls` are read through optional casts, so a value of an
   unexpected type would be silently replaced rather than merged into. Both are
   refused instead.
4. **Never lose a foreign entry.** AgentBar appends its own matcher group rather
   than joining somebody else's, so a foreign group survives install and
   uninstall without a byte changing — verified against the developer's real
   settings file, where install produced a purely additive diff and uninstall
   returned the file to the same SHA-256 it started with.

Its own entries are recognised by **URL**: `type: "http"` with our path on a
loopback host. A marker key would be a cleaner signature and buys nothing —
Claude Code validates handler objects, and no other tool posts to
`/v1/hooks/claude-code` on 127.0.0.1. Matching ignores the port, because the
ladder moving the port is precisely the case that has to be recognised in order
to be repaired.

`allowedHttpHookUrls` is the trap in this file, and the installer's answer is to
refuse to spring it: **it extends the list and never creates it.** An absent key
permits every http hook, so AgentBar's handlers run without one. Defining it
switches allow-listing on at every settings level at once — including for an
http hook in a project's settings AgentBar cannot see — and an uninstaller
cannot afterwards tell an entry it copied in from one the user added, so the
switch would stay flipped for ever. That is the safe-superset rule failing in
the one way that outlives the app.

Because the lists merge across levels, the installer reads
`settings.local.json` too: a list defined next door governs the handlers written
here, and an entry written here satisfies it. A list in a project's own settings
stays invisible, so the report carries a warning whenever any visible list is in
effect. Uninstall removes AgentBar's entry and leaves the key, for the symmetric
reason: switching allow-listing off on the way out is the same unasked-for
policy change in the other direction.

### Why the JSON goes through a hand-written reader

It lives in **`AgentBarJSON`**, a module of its own that knows neither provider
and imports nothing but Foundation. It started inside `ClaudeCodeAdapter` and
moved out in step 09, when the Codex installer needed the same guarantees about
a different file the user owns: no adapter may import another, and two copies of
a parser is two places for the next overflow-class bug to live.

`JSONSerialization` returns a dictionary that has forgotten the order its keys
arrived in and a `Double` that has forgotten whether `5` was written `5` or
`5.0`. Writing that back reformats every line of a file AgentBar is supposed to
add two entries to. `JSONValue` keeps key order and keeps each number as the text
it was written as, and `JSONWriter` renders what `JSON.stringify(value, null, 2)`
renders — which is what these files already look like.

The reader is also the payload reader, which is the part that matters for safety:
it parses bytes from a socket any local process can reach, so its recursion is
depth-capped. A parser that follows the input's own nesting is an unbounded
stack, and a stack overflow is a process kill past every `catch` — the same class
of defect as the arithmetic overflow found in step 03.

The files it creates are its own to bound. A backup holds a live bearer token,
so it is written `0600` even when the file it copies is not — the user's
permissions on their own file are their decision (ADR-0004); a backup is not
their file. Backups are pruned to the most recent few, the temporary file is
created private and widened to the destination's mode rather than the other way
round, and a temporary left behind by a killed process is swept on the next
write.

### Install status without a probe

`ClaudeCodeInstaller.report(for:)` takes the endpoint AgentBar has bound right
now, or `nil`. Everything the panel needs — installed, not installed, repairable
drift, or configured-but-unreachable — is derived from that plus one read of the
file. AgentBar originates no HTTP request, not even to itself.

## The Codex adapter

The same two jobs as the Claude Code adapter — the payloads, and the file that
makes them arrive — plus two Codex only has: a process that has to exist, and a
trust decision that is not AgentBar's to make.

### The helper is a dumb pipe, and its logic is not in the helper

`Apps/agentbar-helper/main.swift` is twenty lines. Everything it does lives in
`CodexAdapter`, which the tool target links, because the alternative is the one
piece of AgentBar that runs inside somebody else's process tree being the one
piece `swift test` cannot reach. `CodexHelperRelay` is exercised against a live
endpoint with a real store behind it; the entry point is what is left over.

It reads one JSON object from stdin and posts the bytes **unread** — no parsing,
no interpretation, no retry. Everything about what an event means happens in the
app, on the far side of the socket.

Four rules, each of which is a rule rather than a preference:

- **It exits 0, always.** Codex reads a non-zero exit from `PreToolUse`,
  `PostToolUse` or `UserPromptSubmit` as a *block*. A monitor that could block a
  tool call is the failure this project exists to avoid, so no path here returns
  anything else, and both streams stay empty unless `AGENTBAR_HELPER_DEBUG` is
  set.
- **It drains stdin before it exits.** Codex writes the payload into a pipe. A
  reader that leaves early hands the writer `EPIPE` — a visible effect on the
  agent, from a tool that is supposed to leave no trace. What is *kept* is
  bounded; what is *consumed* is not.
- **It is bounded by one clock, not by three timeouts.** A budget of 500 ms is
  taken once and every stage is clamped to what is left of it: connect 100 ms,
  send 200 ms, reply 150 ms are what a *syscall* gets, and syscall timeouts do
  not compose. A partial write restarts `SO_SNDTIMEO`, a read loop restarts it
  per chunk, and the socket-then-port ladder would otherwise pay for both rungs —
  three ways for "bounded" to quietly mean "twice as long as it says".
- **POSIX sockets, never Network.framework**, and the destination is pinned to
  `127.0.0.0/8` at the point where text becomes an address. The host is read from
  a file, and a file can say anything; ADR-0002's guarantee is that AgentBar
  talks to loopback and to nothing else, so this is where that is enforced rather
  than assumed. The token file is pinned the same way — it has to sit in the
  directory the description itself sits in, or a planted description could point
  the helper at a credential store. `ModuleBoundaryTests` now polices both
  `import Darwin` and the connect-shaped syscalls, so the guarantee is a failing
  test rather than a promise.

Measured on the developer's machine, Release build, 40 runs against a live
endpoint, spawn to exit: **p50 6.5 ms with the machine idle and 11 ms with
several builds running**, against a `/bin/cat` baseline of 1.0 ms and 1.8 ms
through the same harness. The helper's own share is therefore five to ten
milliseconds, nearly all of it dynamic linking, inside a budget of a thousand.
`HelperTimingProof` is the gated suite that measures it, and it compares against
that baseline rather than a fixed number — otherwise it fails for the machine's
reasons rather than the code's.

### No secret crosses the disk

`hooks.json` holds a path and a timeout. The token is read from the endpoint's
own file at the moment the helper runs, so a rotated token and a moved port
change nothing on disk — which matters more here than it would anywhere else,
because a changed hook definition costs the user a trust prompt.

### Trust, and the two files behind it

Codex will not run a `command` hook until the user has reviewed and trusted the
exact definition, and it records that decision as a hash keyed to the entry's
position: `<source path>:<event_in_snake_case>:<group>:<hook>`, under
`[hooks.state]` in `config.toml`. So the adapter **reads** that file — for trust,
and for the user's own hooks, which on this machine live there rather than in
`hooks.json` — and never writes it. `TOMLTables` reads tables and scalars and
skips everything else, which is what keeps a provider credential elsewhere in
that file from ever becoming a value AgentBar holds.

The reading is evidence, not proof: the format is observed rather than
documented. What is proof is a delivery — a Codex event cannot arrive from a hook
that did not run — so `report(for:hasDelivered:trustPending:)` takes that fact
from the app and lets it outrank the table. Everything else resolves to *not
trusted*, which asks the user to look rather than claiming that silence is
success.

The trap in the middle is worth naming, because a review found it and no test
had: a trust record is keyed to a hook's **position**, so a repair that rewrites
the command leaves the record standing at the same key, looking exactly like
consent for a definition Codex will now refuse to run. Reading the table alone
would put `Connected` under an integration that is inert — the one outcome this
design exists to prevent. So AgentBar remembers, in its own directory, what was
recorded at the moment it wrote: a record that has *changed since* is consent for
what is there now, and one that has not is not. ADR-0008.

## The menu bar

`AgentBarUI` may import only `AgentBarCore`, which decides most of its shape.

**Liveness is driven, and mostly by push.** `StoreSnapshot` is an immutable
reading and `SessionStore` owns no timer, so nothing re-reads it by itself.

| Signal | Carries | Latency |
|---|---|---|
| `StateChangeSink`, from `EventIngestHandler` | every move an applied event caused | immediate, coalesced over 150 ms |
| Timer, panel open, 1 s | `snapshot()` — the durations ticking | 1 s |
| Timer, panel closed, 45 s | `sweep()` then `snapshot()` | up to a minute |

Push is not an optimisation. Without it a waiting agent — the one signal the
product exists for — would sit unannounced behind the closed-panel poll. The
handler already held the `[ApplyOutcome]` that `apply()` returns; the sink is
what stops it discarding them. It is deliberately not a callback the store owns:
the domain must not know anything is listening, so the observation belongs to the
boundary that applied the event.

The status item is redrawn only when `mostUrgentState` or `waitingSessionCount`
actually moved. Everything else a snapshot changes is the panel's business.

**Install status is a UI-owned value type.** `IntegrationStatus` is declared in
`AgentBarUI` and populated by the app target, which is the only place that links
both a provider's installer and the views. The switch over
`ClaudeCodeInstallState` lives next to that installer. A view model holding a
`ClaudeCodeInstallReport` would fail `ModuleBoundaryTests`, and would break the
rule that nothing above the adapter knows the providers exist.

**The panel is an `NSPanel`, not an `NSPopover`.** Two requirements are in
tension — never steal focus, and be keyboard-navigable — and the resolution is
that the input method which opened the panel decides: a click orders it front
without activating the app, a shortcut opens it as key window.
`.nonactivatingPanel` is the style mask that can do both; a popover cannot.
No shortcut is registered yet, so the capability exists and the trigger is a
seam.

## Notifications

`AgentBarNotifications` consumes `StateChange` and nothing else. It does not know
that hooks exist, that Claude Code exists, or how an event reached the store; its
only intra-package edge is `AgentBarCore`, and `ModuleBoundaryTests` fails the
build if that changes.

**The push leg fans out.** `Apps/AgentBar` hands `IngestService` one
`StateChangeSink` that forwards each batch to two observers: the menu bar, which
re-reads the store and redraws, and the router, which decides whether anything is
worth interrupting the user for. Neither knows the other exists, and the sink
still returns immediately — a sink that waits is a hook handler that waits.

The module is a pipeline of pure decisions with one stateful object at the end:

| Piece | Decides | Pure |
|---|---|---|
| `NotificationPolicy` | which verb a `StateChange` deserves, and what its body says | ✅ |
| `NotificationCoalescer` | how many of a burst a person should hear about | ✅ value type |
| `NotificationGate` | whether this one is delivered at all, and why not | ✅ |
| `SoundLibrary` | whether the chosen sound still exists and is usable | filesystem |
| `NotificationRouter` | joins them, holds the settings and the authorisation | `@MainActor` |
| `UserNotificationCentre` | the only file that imports `UserNotifications` | — |

Keeping the first three pure is what lets the verb table be tested case by case
without a notification centre, an entitlement, or a user who has to click Allow.
`NotificationPresenting` is the seam; the tests drive a recording double.

**Three mechanisms stop a storm**, and they solve different problems. Within a
1.5 s window only the newest draft per session survives, so a session that went
waiting and then failed produces one notification saying it failed. Across
windows an identical draft — same verb, same body — is dropped for twenty
seconds, while a *different* question gets through, because that is genuinely new
information. And every notification carries the session id as its notification
identifier, so the notification centre itself replaces a session's previous
banner rather than stacking a second one beside it. The thread identifier is the
project, which is what groups a project's notifications together.

The repeat window starts when a notification is **delivered**, not when one is
considered: `drain()` hands the router one draft per session and the router
records the delivery only after the gate has passed it. Otherwise a draft
suppressed by quiet hours would begin a twenty-second window during which the
same news is refused for a second reason. A repeat is the one suppression the
user could not observe anywhere, so it is reported through the same path as every
other — and `notAuthorized` is reported **once at error level**, because it means
AgentBar is running and doing nothing at all.

**One category per verb, registered from the first release**, because a category
identifier is baked into every notification already delivered and renaming one
orphans them. They carry no actions. Approve/Deny will add a category of its
own rather than hanging buttons on `waiting`: the verb is chosen by the presence
of a question line, so `waiting` is shared by a permission prompt and by an
ordinary blocked-on-a-human event, and actions there would put permission buttons
on notifications that are not permission requests.

**Two `StateChange` shapes fire nothing**, and both are reachable: `from == nil`
is the store adopting a session it had not seen, which would otherwise announce a
turn that never happened here, and `to == nil` is the session leaving. `working`
and `unknown` fire nothing either. The predicates are written as conditions on
`from` and `to` rather than as a feeling about the event, and every one of them
has a test.

**Sounds are names, not paths**, because that is what `UNNotificationSound` takes
— and it resolves them in only two directories, neither of which is
`/System/Library/Sounds`. [ADR-0006](../adr/ADR-0006-notification-sounds-are-files-agentbar-can-resolve.md)
records what follows from that. The practical consequence for this file is that
the sound is validated twice, once when the picker is built and once at send
time, and that a selection which has become unusable falls back to the default
rather than to silence.

**The settings window is a second UI seam.** `SettingsServices` is declared in
`AgentBarUI` and implemented in `Apps/AgentBar`, exactly as `PanelServices` and
`IntegrationStatus` are, because `AgentBarUI` and `AgentBarNotifications` are
siblings and neither may import the other. The four verbs are therefore declared
twice — `NotificationEvent` in the notifications module, `NotificationVerb` in
the UI — and mapped one for one in the bridge. That duplication is the price of
the boundary, and it is what stops a view importing a sound library.

Unlike the panel, the settings window **does** activate the app: it is asked for
by name with a click, and a window the user cannot type in would be worse than
the focus rule it would be honouring. Closing it hides AgentBar again, so an
accessory app is never left active with nothing on screen.

## Caffeine

`AgentBarPower` consumes `StoreSnapshot` and nothing else. Like the notifications
module it is a sibling below `AgentBarCore`, may import nothing but the core, and
`ModuleBoundaryTests` fails the build if that changes — with one addition:
**`IOKit` is restricted to this module**, exactly as `Network` is restricted to
`AgentBarIngest`. One owner is what makes "released when the process dies" a
guarantee rather than a hope.

| Piece | Decides | Pure |
|---|---|---|
| `CaffeineMode` | the three settings — never, while working, always | ✅ |
| `CaffeineSettings` | the mode, and which one a toggle restores | ✅ value |
| `CaffeineDemand` | mode × snapshot → hold or release, and the reason | ✅ |
| `PowerAsserting` | the seam over IOKit | — |
| `IOKitPowerAssertion` | the only file that imports IOKit | — |
| `CaffeineController` | joins them, holds the assertion, renews the lease | `@MainActor` |

**Three mechanisms release the assertion, and they fail independently.** A
session stuck in `working` is answered by the watchdog: `StoreSnapshot` applies it
on every read, so a missed `sweep()` cannot leave the assertion held, and the
decision needs no timer of the domain's. A killed or force-quit AgentBar is
answered by the kernel, because the assertion is process-owned — which is the
whole argument against shelling out to `caffeinate`, whose child survives its
parent. And an AgentBar that is alive but no longer deciding is answered by the
**lease**: the assertion is created with a 150-second timeout and re-armed every
30 seconds, so a controller that stops asking stops holding.
[ADR-0007](../adr/ADR-0007-caffeine-is-a-leased-process-owned-assertion.md)
records the alternatives and the numbers.

**What drives it.** `start(reading:)` takes one reading immediately, because
AgentBar is usually launched while agents are already running and a session
halfway through a long `Bash` call may not speak again for half an hour. After
that the push leg wakes it — a third observer on the same `StateChangeSink`
fan-out the menu bar and the router hang off, coalesced over 150 ms like the menu
bar's — and the renewal task re-reads while a hold is wanted. Nothing polls when
none is.

That renewal task is load-bearing, not housekeeping. **Once the assertion is
held it is the only thing re-reading the store**: a session stuck in `working`
emits nothing by definition, and the menu bar's clock does not reach this module.
It is therefore what carries the watchdog's verdict to the assertion, and it runs
while a hold is *wanted* rather than only while one was granted — so a refused
assertion is tried again rather than waiting for an event a silent session will
not send. `renewalInterval` and `lease` are injectable so the loop can be driven
in a test instead of stood in for.

Evaluations are **serialised**. Two overlapping ones would otherwise be free to
apply their demands in the order they finished reading the store rather than the
order they started, and the loser would leave the assertion describing a store
that had already moved on.

**The interface is a third seam of the familiar shape.** `AgentBarUI` may not
import `AgentBarPower`, so `CaffeineIndicator` and `CaffeineSetting` are declared
in the UI and populated by `Apps/AgentBar` through `CaffeineBridge` — the same
arrangement as `IntegrationStatus` and `NotificationVerb`, and the same price for
the same boundary. One bridge serves both the footer button and the settings
picker, so the two cannot disagree about what Caffeine is doing. Both read an
`@Observable` controller from inside a view body, which is what makes them live
without a clock of their own.

**A refused assertion is drawn as a fault, never as a hold.** It is the one
failure a user cannot diagnose: the only other symptom is a Mac that fell asleep
during a build, hours later, with nothing connecting the two.

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
