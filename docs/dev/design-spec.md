# Interface specification

Every surface AgentBar renders, the geometry it renders at, the English copy it
renders, and the domain value each element comes from.

The token set is in [design-system.md](design-system.md); this file is what
those tokens are assembled into. Together they are meant to be complete enough
that step 06 makes no visual decisions of its own.

Derived from the Claude Design canvas against
[design-brief.md](design-brief.md), 2026-08-18, step 05. The canvas disagrees
with its own design-system document in several places; each resolution is
recorded inline under **Deviation**, and the type-scale one — the largest — is in
[design-system.md](design-system.md#typography). Where the canvas mocks a value
the domain cannot produce, that is said in place so nobody implements against it.

The canvas itself is not committed. Everything it carries is transcribed here and
in the token document; nothing in either file cites a path that is not in the
repository.

---

## Vocabulary

Fixed by the brief and by `AgentBarCore`. These words appear verbatim in the UI
and in code:

**Provider · Session · Project · Subagent · Working · Waiting · Idle · Failed ·
Unknown.**

The provider is "Claude Code" or "Codex" — never "OpenAI Codex" inside the
panel, never abbreviated, never localised.

There are five state words and no sixth. [design-brief.md](design-brief.md) §4.2
writes `finished` in its session-row table where its own §8 vocabulary and
`SessionStateKind` both say **Idle** — the brief's §8 definition of Idle is
literally "Finished its turn, nothing pending". The brief is left as the input it
was; this is the correction. Do not introduce a `finished` state.

The notification verbs are a separate, smaller set and may say `Finished`: they
name an event, not a state.

Copy conventions: buttons and menu items in title case; labels, statuses and
notification bodies in sentence case with no terminal period, except the two
full-sentence explanations which keep theirs. The separator between a state and
its context is U+00B7 MIDDLE DOT with ordinary spaces around it, from one shared
constant so it cannot drift to a hyphen.

---

## Status item

The most important element: it answers "does anything need me?" before the panel
is opened. Monochrome template images (`isTemplate = true`) so AppKit tints them
for light, dark and a tinted menu bar.

**The figure is three agent nodes** — two at the base, one at the apex, joined by
hairline links — which is the app mark reduced to its skeleton. It replaces the
filled disc v1 shipped: a disc is clean and invisible at 18 pt among a dozen
system items, has no identity, and tells a first-time user nothing.
[design-system.md](design-system.md#status-item-glyph) has the reasoning; the
geometry below is normative and lives in `GlyphFigure`.

**Priority — the icon shows the single most urgent state present:**
Waiting → Failed → Working → Unknown → Idle. This is
`StoreSnapshot.mostUrgentState`, and `SessionStateKind.attentionRank` already
encodes exactly this order.

| State | Glyph |
|---|---|
| Idle | all three nodes as rings, whole figure at 40 % coverage — nearly invisible |
| Working | all three nodes filled, full coverage |
| Waiting | apex filled at 2.50 pt **plus** a ring leaving it; base nodes filled |
| Failed | apex is a rounded square; base nodes filled |
| Unknown | everything dashed — nodes and links — at 60 % coverage |

Geometry, on an 18 pt menu-bar canvas with **y measured up from the bottom**
(AppKit's convention, ready for `NSBezierPath`):

| Element | Value |
|---|---|
| Canvas | 18 × 18 pt |
| Apex centre | (9.0, 13.0), radius 2.40 — 2.50 when filled for Waiting |
| Base left centre | (4.5, 5.0), radius 1.90 |
| Base right centre | (13.5, 5.0), radius 1.90 |
| Node stroke, when hollow | 0.90 pt |
| Link stroke | 0.80 pt, round caps, trimmed to each node's edge |
| Link coverage | 0.45 **of the state's own coverage**, so links stay subordinate in every state |
| Failed apex | 4.60 pt square, 1.20 pt corners |
| Waiting pulse | ring at 1.20 pt stroke, travelling 0.70 → 2.10 of the apex radius |
| Node dash | 1.2 on / 1.3 off · link dash 1.3 on / 1.7 off |

The optical bounding box is 12.8 × 12.8 pt — **71 %** of the canvas, deliberately
wider than the old disc's 67 %. An outlined, mostly empty figure reads lighter
than a solid one of the same diameter and needs the width to hold equal weight
beside a battery glyph. Verify optically against the system items, not against
the number.

All of this is normative in `GlyphFigure`, which every renderer reads from —
the AppKit template image, the SwiftUI canvas the panel header and the
onboarding draw, and the notification attachment art. One set of numbers, three
renderers.

Draw with `NSBezierPath` rather than shipping five PDFs. That settles the
light/dark asset-pair question by construction, and it removes the reachability
question that hung over the old `"AB"` text fallback: an SF Symbol name can be
withdrawn between macOS releases, a path cannot.

> **A template image has one channel of alpha, and that governs everything
> here.** No colour survives tinting, so the pulse ring is a *shape* — an
> even-odd annulus — and not a coloured stroke. Colour lives in the notification
> attachment, the panel row and the footer indicator. Never in the status item.

### Animation

The status item is three cached static images and one cached frame array.

| Cycle | Duration | Behaviour |
|---|---|---|
| Waiting pulse | 2200 ms, 18 frames at 8 fps | the ring leaves the apex and fades |
| Working chase | 1500 ms, 12 frames | computed, and **not shipped** |

Four rules, and each one is a defect if broken:

1. **One timer**, invalidated whenever the aggregate state has nothing to
   animate. Idle, Failed and Unknown are static.
2. **8 fps**, not 12 and not 60 — enough for a 2.2 s ease, half the wake-ups.
3. **No timer at all under Reduce Motion.** The resting frame is shown, and
   `AccessibilityPreferences` is the one place that setting is read.
4. **The resting frame is frame 0**, so the static image and the animation
   cannot disagree about what a state looks like.

> **The resting frame is not phase zero, and this matters.** At phase zero the
> pulse ring is still inside the filled apex, so Waiting draws as a filled
> triangle — which is *Working*. Reduce Motion, a sleeping timer, an offscreen
> render and a profiler run all produce that frame, so the cycle is phase-shifted
> to start at the earliest phase where the ring has cleared the apex. It is
> searched at build time rather than written down, so moving the curve, the
> travel or the apex radius moves it too.

**Working does not animate in the menu bar.** Its information is already carried
by the panel, the working row's hairline and the fact that the user just started
the agent, and it would run for most of a working day as a permanently moving
thing in peripheral vision. The chase is computed either way; turning it on is
`GlyphFigure.animatesWorking` and nothing else.

**Optional waiting count.** When `StoreSnapshot.waitingSessionCount > 1`, a
numeral may sit to the right of the glyph, battery-percentage style. Only above
one — the common case is a single waiting session and a permanent "1" is noise.
Implemented as a composited image or an attributed title on the status item;
status items have no native badge.

**Accessibility label** — a full sentence, set on the status item, recomputed on
every state change. VoiceOver gets nothing from the silhouette.

| Aggregate state | Label |
|---|---|
| One waiting | `AgentBar: 1 session waiting in agentbar-web` |
| Several waiting | `AgentBar: 2 sessions waiting` |
| Failed | `AgentBar: 1 session failed in growth-scripts` |
| Working | `AgentBar: 3 sessions working` |
| Unknown | `AgentBar: 1 session unknown in infra-scripts` |
| Idle / empty | `AgentBar: nothing running` |

The project name is named only when exactly one session is in the leading state;
otherwise the count carries it.

---

## Panel

**380 pt** wide, height intrinsic to content. It is a live list, not an
`NSMenu`: rows appear, change and leave while it is open.

> **An `NSPanel`, not an `NSPopover`.** This section originally said popover, and
> step 06 found that a popover cannot express the key-status rule below: it has
> no way to take key status when opened by a keyboard shortcut and refuse it when
> opened by a click. `NSPanel` with `.nonactivatingPanel` is exactly that
> capability, so it is what ships — `.borderless`, `becomesKeyOnlyIfNeeded`,
> `.floating`, dismissed by a global mouse monitor and by `resignKey`. Nothing
> else in this document changes.

**It must not steal focus.** Do not call `NSApp.activate` when showing it. The
whole product is worthless if opening the panel pulls the user out of their
editor.

**Liveness has to be driven, and mostly by push.** `StoreSnapshot` is an immutable
reading; the store owns no timer and is forbidden one by the module boundaries.
Nothing today re-reads it, and — more importantly — `EventIngestHandler` counts
the `[ApplyOutcome]` that `apply()` returns for a diagnostic and then throws it
away. There is nothing to subscribe to.

| Signal | Carries | Latency |
|---|---|---|
| **Push** — the ingest boundary forwards `apply()`'s `.changed(StateChange)` outcomes to an app-level observer | every state move an event caused, including a session becoming `waiting` | immediate |
| Timer, panel open, 1 s | `sweep()`, `snapshot()`, republish — the durations tick | 1 s |
| Timer, panel closed, 30–60 s | `sweep()`, then `snapshot()`; the status item is redrawn **only when `mostUrgentState` or `waitingSessionCount` actually changed** | up to a minute |

Push is not an optimisation. Without it a waiting agent — the one signal the
product exists for — would sit unannounced behind the closed-panel poll.

The timers cover only what time alone changes. `unknown` is not among them: it is
derived on every read, so a reading taken before a sweep already shows it. What a
missing `sweep()` actually costs is retirement and the went-quiet transitions;
what a missing re-read costs is a panel frozen at the moment it opened. And the
closed-panel interval is not the watchdog's: the tightest allowance is fifteen
*minutes*, so 30–60 s is ample once push exists.

Container: panel radius 18, glass material, 1 pt hairline, contents clipped.

**Structure, top to bottom:** header → project groups → Limits → footer. The
onboarding card replaces the project groups entirely; it does not sit above them.

### Header

**Added in v2.** The panel used to start at the first project group, which left
it a floating list of rows that could have belonged to anything, and no answer to
"is anything urgent?" short of reading every row.

```
height        41 pt  (11 top / 10 bottom padding + 20 pt of content)
padding       15 pt sides
divider       1 pt hairline at the bottom, ColorToken.hairline
```

Left: the 16 pt three-node figure — drawn as a SwiftUI view rather than a
template image here, so it *may* carry the state accent — then `AgentBar` in
`rowTitle`.

Right: the urgency pill, or nothing.

| Condition | Summary | Shape | Colour |
|---|---|---|---|
| Any session waiting | `%lld waiting for you` | waiting | `stateWaiting` |
| Else any failed | `%lld failed` | failed | `stateFailed` |
| Else | *absent* | — | — |

The pill is 3 pt vertical / 9 pt horizontal padding at radius 7, filled with the
accent at 0.16 in light and 0.24 in dark, with an inset hairline at accent 0.30
and a semibold `caption` label. Composed by `PanelHeaderSummary.summarise` —
ordered rules, first match wins, the same shape as `FooterStatus.summarise`.
Waiting outranks failed because a waiting agent is blocked on this person *right
now* and a failed one has already stopped; that is `attentionRank`, not a
decision the header makes.

**When nothing is waiting and nothing has failed the pill is absent, not
reassuring.** A permanent `0 waiting` is a thing the eye learns to stop reading,
which costs it its meaning on the day it matters.

**The height is stated, not derived**, and that is the point of the number: a
header that grew when the pill appeared would push every row down at the exact
moment something started waiting — the worst possible moment for the list to move
under a pointer reaching for it.

Note the division of labour: the **header** says how many need you, the
**footer** says whether the plumbing is healthy. Neither is derived from the
other's source, and they never duplicate each other.

### The waiting wash

**Added in v2.** While any session is waiting, the panel takes a warm gradient at
its **top edge only**: `stateWaiting` at 0.20 (light) / 0.18 (dark) over 72 pt,
fading to transparent. It sits above the material and below the content, so the
header and the first rows read through it.

Two rules:

- **It is state, not decoration.** It appears for `waiting` and never for
  `failed` — a failure is already carried by a row tint and a footer line, and
  two washes at once would say nothing.
- **It costs no height.** It is a background, so a session starting to wait must
  not resize the window. A test asserts that.

It does not replace the row wash: a waiting row still takes its own tint, and the
top wash is a separate, larger signal about the panel as a whole. Under Reduce
Transparency the panel is a flat `surface` fill and the wash stays — it is an
opacity over a fill, not a material effect.

### Project group

Header, then that project's sessions. A hairline divider between groups; no card
border — the divider is enough.

| Element | Value |
|---|---|
| Block padding | 12 top / 16 sides / 8 bottom |
| Header bottom margin | 6 |
| Folder glyph | 11 × 9, 1.3 pt stroke, `ink400`, corner radii 1 / 3 / 2 / 2 |
| Glyph → name gap | 6 |
| Name | Row title (13 / 590), `ink900` — `ProjectRef.name`, the folder name. `PathProjectResolver` falls back to the full path only for a session rooted at `/`, where there is no component to show |
| Session count | Caption, `ink400`, right-aligned — `1 session` / `N sessions` |
| Divider between groups | 1 pt, inset 16 each side, 6 above and below |

Groups are ordered by project name, sessions inside them oldest first. That is
`StoreSnapshot`'s own ordering and it is deliberate: a list sorted by urgency
would reshuffle under the cursor. Urgency is the status item's job.

**Two groups can share a name.** `ProjectRef.name` is the last path component, so
`~/code/app` and `~/worktrees/feature-x/app` both render as `app` — adjacent,
identical headers with nothing to tell them apart, which is exactly the case a
developer using worktrees hits.

The disambiguator comes from `root`, never from `worktree`. When two or more
visible groups share a case-insensitive name, append the shortest trailing path
components of `root` that make the colliding set distinct — start at the parent
component and walk one further up while the suffixes still tie, since `~/a/x/app`
and `~/b/x/app` both yield `x` and the rule has to be able to reach `a` and `b`.
The suffix is muted, Caption / `ink400`: `app · feature-x`.

`worktree.repositoryName` is the wrong disambiguator in precisely the case that
triggers the rule: a linked worktree whose leaf equals the repository's own name
gives `app · app`, which distinguishes nothing. Once a git-aware resolver fills
`worktree` it is worth showing as extra context when it differs from the computed
name — never as the primary disambiguator. Today it is always `nil`, so the
`root` rule is the one that runs.

Two things follow, or the ambiguity merely moves:

- The disambiguated label is **one computed presentation value**, reused
  everywhere the project is named: the group header, the row's
  `Open {project} in your editor` tooltip, and the `{Project}` slot of the row's
  accessibility label. Rendering it only in the header leaves a VoiceOver user
  with two identical `app`s.
- A notification cannot use a snapshot-relative rule — it is emitted per event,
  with no view of what else is on screen. Notification titles keep the bare name
  and accept the ambiguity; see [Notifications](#notifications).

Every header carries `root.path` as its tooltip and accessibility hint,
unconditionally and whether or not it is ambiguous.

> **Deviation.** The canvas has a second, compact group header
> (`agentbar-web · 3 sessions`, no glyph) in its scrolling mock. Only the full
> header ships. One row design and one header design, at every list length —
> the panel scrolls instead of densifying, and step 06 gets no branch.

### Session row

One row per `Session`. Radius 10, padding 9 vertical / 4 horizontal, badge and
text column with a 10 pt gap, badge top-aligned.

| Element | Source | Rendering |
|---|---|---|
| Provider badge | `Session.provider` | 26 × 26, radius 7, provider colour and glyph |
| State shape | `Session.state.kind` | the shape from the state-shape table, 6 pt gap to the label |
| State label | `Session.state.kind` | Row title — `Working` · `Waiting` · `Idle` · `Failed` · `Unknown` |
| Subagent pill | `Session.activeSubagentCount` | `+2`, Caption on `fillQuiet`, full pill, 1 / 6 padding, 2 pt after the label. **Only when > 0** |
| Duration | `Session.timeInState` | Caption, `ink400`, tabular, right end of the top line |
| Detail line | per state, below | 3 pt under the top line, single line, truncated with an ellipsis |

**Row tint** per the design system: waiting, failed and unknown rows take a
full-row wash of their accent; working and idle rows take none.

**The working hairline** — added in v2, and the only progress indicator in the
app. Under a working row's command line:

```
height     2 pt, radius 2 · margin 7 pt above
track      ColorToken.meterTrack
fill       a 40 %-wide sweep, transparent → stateWorking → transparent
motion     2400 ms, linear (Motion.traverse), indeterminate
travel     from fully off the left edge to fully off the right
```

**Deliberately not a spinner.** A spinner claims a duration AgentBar does not
know; a sweep claims only that something is happening, which is the whole of what
a hook payload says. There is no percentage available and none is implied. The
sweep's ends are transparent so it has no edge to catch the eye — an edge would
read as a boundary between "done" and "not done", which is a claim this cannot
make.

Under Reduce Motion — and behind a dismissed panel — it renders as a **static
40 % fill at the left**: not hidden and not frozen mid-sweep, because a working
row still has to look different from an idle one.

> **It stuttered, and the cause was the shape of the loop rather than its speed.**
> The first build travelled from the track's left edge to its right on the `cycle`
> curve, repeating without autoreverse. Both halves are wrong for a loop that
> wraps. The travel began *inside* the track, so every cycle ended with a
> 40 %-wide bar appearing out of nothing at the left edge; and ease-in-out spends
> its slowest moments at both ends of the travel, putting a near-stop on each side
> of that seam. What the eye saw was pop, crawl, race, crawl, pop. The fix is the
> two lines above — linear, and off the track at both ends — and the rule behind
> it is in [design-system.md](design-system.md#motion): `cycle` is for a loop that
> returns, `traverse` for a loop that wraps.
>
> The moving sweep and the parked one are also **two views, not one offset with a
> conditional animation.** A `repeatForever` animation is started by a value
> *change*, so re-entering the moving state — a user turning Reduce Motion off
> with the panel open, or the panel coming back on screen — finds a single shared
> flag already at its end value, fires nothing, and leaves the row with an empty
> track for as long as it lives. That defect has now been fixed twice from
> opposite directions; giving the moving bar its own view gives it a fresh state
> and a fresh `onAppear` every time, so it cannot fail to re-arm.

**Inline row actions are not shipped.** The mock draws `Reply` and `Open` inside
a waiting row. The panel is a status surface — clicking a row already opens the
session — and with no reply channel possible ([Notifications](#notifications)) a
`Reply` button could only duplicate that gesture. Rows would also grow taller and
the 340 pt list would hold fewer of them. Revisit only if reaching a waiting
session turns out to be slow in real use.

**The detail line, per state** — one line, and the typeface is itself a signal:
**monospace is text a machine produced**, proportional is text AgentBar composed
or a person wrote.

| State | Detail line | Type | From |
|---|---|---|---|
| Working | the tool call | Mono | `currentTool.invocation`, falling back to `currentTool.name` |
| Waiting | the question, when the agent asked one | Caption | `SessionState.waitingInput(question:)` — ADR-0005, landed in step 06 |
| Failed | the failure reason | Mono | `SessionState.failed(reason:)` |
| Unknown | `Stopped reporting · last seen 18m ago` | Caption | `Session.timeSinceLastEvent` |
| Idle | none | — | — |

The failure reason is monospace because the design system assigns "error text" to
the Mono token, and because the reason really can be a machine string:
`NativeEventDecoder` passes an arbitrary caller-supplied `failureReason` straight
through, and Codex's shape is not written yet. What it will *not* usually be for
Claude Code is `ModuleNotFoundError: pandas`, as the canvas mocks. A tool's own
stderr never reaches the domain — `PostToolUseFailure` is decoded as
`toolFinished` on purpose — so what arrives is
`ClaudeCodeEventDecoder.failureReason`'s taxonomy: `Rate limit reached`,
`The API is overloaded`, `Server error`. Short English sentences, set in mono. The
example copy in the canvas should not be implemented against.

**But the reason is not bounded by the taxonomy.** `failureReason`'s `default`
branch passes an unrecognised provider error type through with nothing but
underscores replaced and the first letter capitalised — deliberately, so a value
Claude Code adds later still reads as something. `NativeEventDecoder` now bounds
every display string it carries to 120 characters (step 06), which is a cap on
the wire, not a sentence. The row truncates to one line, so it is safe. **The
notification body is not safe and must clamp**: take the first 60 characters on a
word boundary and drop the rest. Step 07 must not assume a short sentence
arrives.

`ToolRef.invocation` is `nil` more often than the canvas suggests:
`ToolInvocation.summarise` has no rule for `TodoWrite`, `AskUserQuestion`,
`ExitPlanMode` or any tool it does not recognise, and `TodoWrite` is among the
most frequently called. Fall back to the bare tool name rather than dropping the
line.

**And a working row often has no tool at all.** `currentTool` is
`openTools.last?.tool`, so it is `nil` from `turnStarted` until the first tool
call opens, and again between every `toolFinished` and the next `toolStarted` —
which on a busy turn is many times a second. There is no string for those
moments and none may be invented.

The rule: **a working row reserves the detail line's height for as long as it is
working**, and shows the tool when one is open and nothing when none is. Not a
placeholder, not "Thinking" — the line is simply empty. Reserving it is what
stops the row jumping every time a tool call ends, which is the real failure
here; a row that changes height twice a second is worse than one that carries a
blank line. Idle rows, which never have a detail line, are one line tall.

`Session.currentTool` is `nil` in every state but `working` by construction
(`SessionStore.reading`), so "only while Working" is enforced by the domain and
not by the view.

**The Waiting row carries the question when there is one, and is complete
without it.** Claude Code's `AskUserQuestion` and Codex's exact
`request_user_input` path produce a line; a permission or elicitation prompt
renders as tint, state and duration with nothing beneath, and
that is not a degraded row — the canvas's own dense variant draws it that way,
and its closing note credits the full-row wash, not a detail line, with making
the row catch the eye. The wash is what makes it unmissable; the question is
what makes the *notification* worth reading. Landed in step 06 (ADR-0005); see
[Obligations](#step-06-or-07--the-question-line).

**Idle and Failed rows are ordinary rows.** They persist for as long as the store
holds them — ten minutes of silence, after which the session is retired outright
rather than turning `Unknown` ([ADR-0012](../adr/ADR-0012-a-finished-session-is-retired-not-doubted.md))
— and the panel never hides a session the store still has, nor offers a per-row
dismiss. An ordinary working day is mostly Idle rows, and the design has to be
calm at that, not just at the hero case: an Idle row is badge, hollow ring,
`Idle`, duration, no tint, no second line. A Failed row keeps its wash for as long
as it is listed.

For an unknown session the two numbers mean different things and must not be
swapped. The corner shows `timeInState`, which `SessionStore.reading` redefines
for a derived `unknown` as `silence − allowance` — *how long it has read as
unknown*, an overdue-by figure. The detail line shows `timeSinceLastEvent`, the
full silence. The second is always the larger, by exactly the watchdog's
allowance for that state.

The canvas mock has them the other way round (`14m` in the corner, "last seen 6m
ago"), and both numbers are unreachable besides: the shortest silence that can
produce `unknown` is `workingTimeout`, fifteen minutes. A reachable pair is `3m`
in the corner and `last seen 18m ago`.

**Row action** — exactly one, and the whole row is the click target.

The mechanism is not free. `ProjectRef.root` is a directory, and
`NSWorkspace.shared.open(root)` opens **Finder**, not an editor — so the obvious
implementation would make the copy a lie. AgentBar does not know which editor the
user is in, and the setting that would say is deferred.

The MVP therefore does the honest thing: it opens the project with whatever
application is registered for the directory, and says so. Copy is
`Open agentbar-web`, tooltip `Open agentbar-web in the default application` —
neither promises an editor. Prefer
`NSWorkspace.shared.open(configuration:)` with the frontmost known editor when one
can be identified without configuration; otherwise fall through to the default
handler. When the settings screen lands and can name an editor, the copy becomes
`Open agentbar-web in Visual Studio Code` and the promise becomes true.

**Hover and focus.** Both composite *over* the state tint; neither replaces it. A
focused Waiting row must still read as waiting, which is exactly the row a
keyboard user is most likely to be reaching for.

- Hover: `hoverOverlay` at the row radius — translucent by construction. Not
  `fillQuiet`, which is opaque in light and would erase a failed row's 7 % wash
  and punch through the glass with it.
- Focus: a 2 pt `focusRing` inset on the row bounds, shaped to the 10 pt row
  radius. That is the macOS system accent, not one of ours — `stateWorking` is
  the same blue as the Working dot, so using it would put a Working-coloured ring
  around a focused Waiting row.

**The row's other numbers.** `Session` carries `uptime`, `startedAt` and
`lastEventAt` as well, and none of them earns a place in a resting row. They go in
the tooltip and the long accessibility description:
`Started 14:02, running 41m`. That absorbs all three without adding a pixel.

**Accessibility label**, composed per row:
`{Provider}, {State}, {Project}, {duration}[, {n} subagents]` →
`Claude Code, Waiting, agentbar-web, 38 seconds, 2 subagents`. The duration is
spelled out for VoiceOver; `4m 12s` is read as letters.

**Keyboard**: arrow keys move between rows, Return triggers the row action,
Escape closes the popover.

**How the panel gets to receive those keys.** It cannot, by default: a popover
shown without activating the app has no key window, so arrow keys go to whatever
the user was editing. The two requirements — *never steal focus* and *fully
keyboard-navigable* — are in direct tension, and the resolution is to let the
input method that opened the panel decide:

| Opened by | Key status |
|---|---|
| Clicking the status item | not key. Focus stays in the editor, which is the whole point. There is nothing to navigate with, and nothing was asked for |
| A keyboard shortcut | key. Reaching for the keyboard *is* the request for keyboard focus |

Escape closes and returns focus wherever it came from. This is a real constraint,
not a compromise: a panel that took key status on a mouse click would break the
one rule the product cannot break.

**The shortcut itself is not specified here, and no default is picked.** Nothing
in the repository registers a global hotkey, there is no dependency that would,
and the settings screen that should configure it is deferred — choosing a
system-wide key combination on the user's behalf is not a decision to bury in a
design document. What step 06 owes is the *capability*: the panel must be able to
open as key window, with the trigger left as a seam. Until a shortcut exists the
panel is mouse-only, and the row list is reachable by VoiceOver rather than by
arrow keys.

### Durations

`DateComponentsFormatter`, `.abbreviated`, `.dropLeading`, at most two units.

| Range | Form |
|---|---|
| < 1 min | `38s` |
| 1–10 min | `4m 12s` — never zero-padded; `1m 3s`, not `1m 03s` |
| > 10 min | `14m` |
| > 1 h | `1h 20m` |

Tabular figures throughout, so a ticking row does not jitter. Reset times take
the same units with a preposition: `resets in 2h 10m`, `resets in 3d`.

### Limits

Section label `Limits`, then one **group per provider**: Codex's windows, then
the Claude Code note. Section padding 0 top / 16 sides / 10 bottom, label margin
8 below, 12 between one provider's group and the next.

**Every group is headed by its provider.** A 16 pt provider badge, a 6 pt gap,
then the provider's `displayName` in Row title / `ink900`; what sits under the
heading is indented 22 to line up with the heading's text rather than its badge.
Header to first row, 6.

> **Why the heading exists.** Step 11. The section rendered a bare `Weekly` with
> a bar under it and nothing saying whose week it was — a question the panel
> simply refused to answer once both providers were installed, and the one that
> matters most in the case the section exists for: a bar close to full tells you
> nothing until you know which subscription is nearly spent.

Order is fixed at **Codex, then Claude Code** — the half with numbers first, and
the note about the other half last, where a note belongs. It is a presentation
order and deliberately not `Provider.allCases`, which is alphabetical by
accident.

**Codex** — a **repeating** component. Render one row per window the App Server
returned: one, two, or more. Never a fixed two-slot layout.

| Element | Value |
|---|---|
| Bucket spacing | 10 between buckets |
| Name | Caption, medium, left — the server's own name, verbatim |
| Meta | Caption, `ink400`, right — `34% · resets in 2h 10m` |
| Bar | 4 pt tall, fully rounded, `meterTrack` groove, `meterFill` fill |
| Bar spacing | 4 under the top line |

Every field is optional and degrades by **omission**, never by a placeholder:

- percent missing → no bar at all, and the meta line becomes a standalone
  `Resets in 2h 10m`;
- reset missing → meta is a bare `34%`, with the separator dropped too;
- name missing → `Usage`;
- no windows at all → the Codex group is absent, **heading included**. It is not
  an error and gets no error styling, and a heading over nothing would be a
  fault report the section is not making.

Readings are taken at launch, when a turn finishes, on a ten-minute interval, and
**while the panel is open** — the last spaced to a minute and stopping after
five, because a window left up is not the same thing as a person watching it.
Every read is the user's own `codex` making a request against their own account,
so the cadence is a decision rather than a setting:
[ADR-0011](../adr/ADR-0011-limits-are-read-when-someone-is-looking.md) holds it,
and none of it tightens without going back through
[tos-boundary.md](tos-boundary.md).

**Claude Code** — the heading, then one quiet row. The whole group, heading
included, at 70 % opacity: it is the lowest-emphasis thing in the panel, and a
full-emphasis heading over a permanent "nothing here" would give the half with
no numbers more weight than the half with them. A 13 pt `ⓘ` outline glyph, an
8 pt gap, then Caption in `ink400`:

> Not supported — remaining quota isn't reported

The `ⓘ` reveals one sentence:

> Claude Code provides no supported way to read remaining usage, and AgentBar
> never contacts Anthropic to find out.

Accessibility label on the glyph: `About Claude Code limits`.

The Claude Code group is the one that never disappears — it has no windows and
never will, and the note is part of the section rather than a fault — which is
why *All quiet* still has a Limits section.

No bar, no zero, no error colour, no retry, and **no log line** — this is
permanent correct behaviour, not a fault (ADR-0002). Present tense throughout;
nothing in the copy may read as a transient outage. **`Not supported`, never
`not supported yet`**: there is no version of Claude Code this is waiting for.
`Unknown` in particular is reserved for session state and must not be reused
here. The provider's name is carried by the heading and not repeated in the
sentence under it.

### Opening and closing

The status item is a **toggle**: the first click opens the panel, the second
closes it. That needs saying because it is not what falls out of the obvious
implementation. Two handlers see a click on the status item — the global mouse
monitor that dismisses the panel when the user clicks away, and the button's own
action — and the monitor runs first, on mouse-down. Left alone it closes the
panel, the action then finds it closed, and opens it again: a toggle that only
ever opens. The rule is that **a click on the status item belongs to the status
item**, and the monitor ignores it.

Everything else closes the panel: a click anywhere outside it and, **on the
keyboard path only**, Escape or losing key status. Both of those reach the panel
through the key window's responder chain, and a panel opened by a click is
deliberately never key — so on the mouse path a click away is the whole of it.

One exception on the keyboard path, for the same reason as above: a resignation
that happens while the pointer is over the status item is ignored, or clicking
the icon to close a panel opened from a notification would hide it and let the
button reopen it. The cost is that ⌘-Tab with the pointer parked on the icon
leaves the panel up, which one more click closes.

### Footer

Padding 9 vertical / 16 horizontal, 1 pt divider above, install status on the
left, buttons on the right.

- Indicator in a 6 pt box, 6 pt gap, Caption in `ink400`. The indicator carries
  the **state shape**, not only the colour — a filled circle for healthy, the
  waiting triangle, the failed rounded square. Colour never carries state alone,
  in the footer as anywhere else. 6 pt is the bounding box, so the shapes are
  scaled down from their row sizes to fit it: circle 6 pt, triangle 6 × 5, square
  5 pt with 1.5 pt corners.
- Healthy reads `2 of 2 connected`. **Both numbers are computed from the
  integrations the app assembly actually registers**, never from the constant 2 —
  only Claude Code exists today, so the honest reading is `1 of 1 connected` until
  step 09 lands. A hardcoded denominator would show a permanent `1 of 2` and
  report an unbuilt feature as a broken install. That is also why rule 6 says
  "of several": with one integration, rule 1 already covers it.
- A problem **replaces** the count rather than appending to it. The footer has
  room for one of the two, and the problem is the actionable half. Several
  conditions can hold at once, so this is ordered and **the first match wins**:

  | # | Condition | Indicator | Text |
  |---|---|---|---|
  | 1 | No provider is set up at all | `stateWaiting` triangle | `Not connected` |
  | 2 | `boundEndpoint` is nil, the bind failed, or any report is `endpointUnavailable` | `stateFailed` square | `Not receiving events` |
  | 3 | Any report is `settingsUnreadable` | `stateFailed` square | `Can't read settings` |
  | 4 | Any report is `needsRepair` | `stateWaiting` triangle | `Repair needed` |
  | 5 | A provider is installed but not trusted | `stateWaiting` triangle | `Codex not trusted` |
  | 6 | One provider of several is not set up | `stateWaiting` triangle | `Claude Code not connected` |
  | 7 | Everything healthy | `connected` circle | `N of N connected` |

  Rule 1 comes first deliberately: a user who has installed nothing needs to be
  told that before being told the endpoint is not receiving events they were never
  going to send. Rules 2 and 3 are both faults rather than warnings — a file
  AgentBar cannot read is not a repair it can offer.

  `endpointUnavailable` is *defined* as "hooks configured, no endpoint bound", so
  it is the nil-`boundEndpoint` case and belongs on the red rung with it, not on
  the amber one. `settingsUnreadable` is a third broken state that is neither of
  the others, and `isInstalled` returns `false` for it — without a rung of its
  own it would silently deflate the connected count with no explanation
  anywhere.

  This is the whole diagnostics surface, and deliberately so — the restraint
  requirement rules out a diagnostics panel. Pressing the status opens the
  integration card, whose per-provider drift list explains why in prose the
  adapter already wrote.
- **The drift only resurfaces if the report is re-read.** Nothing re-reads it
  today. The footer refreshes every provider's report on panel open and after
  every successful `IngestService.start()` — the two moments at which
  `endpointChanged` and `tokenChanged` become true.
- The status text is itself a button: pressing it opens the integration status
  card in place. That is the answer to "why is nothing appearing?" being one
  click from the thing that says something is wrong.
- Buttons: 22 × 22, radius 6, 2 pt apart — `Caffeine` (cup), `Settings` (gear)
  and `Quit AgentBar` (power). None has a visible text label, so all three need
  tooltips and accessibility labels.

Settings is the entry point reserved for the deferred settings screen, and the
footer is where a future dashboard entry point goes. Nothing more: the brief's
restraint requirement is a hard one.

> **Deviation, step 08.** "Nothing more" was written about *entry points*, and
> Caffeine is not one — it is a control whose state has to be readable at a
> glance, and the panel is the only surface a user looks at without going
> looking. It sits leftmost of the three so `Quit AgentBar` stays last. The full
> three-state setting and the honest limitation live in the settings window's
> `Caffeine` section; this button is the indicator and the off switch.

### The Caffeine indicator

One 22 × 22 icon button, and the whole of Caffeine's presence in the panel. Four
appearances, each with its own silhouette — colour never carries the state alone,
in the footer as anywhere else:

| State | Symbol | Ink |
|---|---|---|
| Holding an assertion | `cup.and.heat.waves.fill` | `connected` |
| On, nothing is working | `cup.and.heat.waves` | `ink400` |
| Off | `cup.and.saucer` | `ink400` |
| The system refused | `exclamationmark.triangle.fill` | `stateFailed` |

*On and holding* and *on and nothing needs it* are different facts and must not
share a face: an indicator that conflated them would tell a user the Mac is being
kept awake when it is not. A **refusal is drawn as a fault and never as a hold** —
the only other symptom is a Mac that fell asleep during a build, hours later,
with nothing to connect the two.

Pressing it turns Caffeine off, or back on to whatever the settings window last
chose — so switching off and on again never silently demotes `Always` to `While
an agent is working`. Two sentences carry it: the tooltip says what is happening
now (`Keeping your Mac awake · 2 working`), and the accessibility hint says what
pressing it will do (`Turn Caffeine Off`). A control that only describes its state
leaves a user guessing whether it is a button.

---

## Panel states

### Empty

The resting state, and it must feel calm rather than broken.

Content padding 44 top / 24 sides / 36 bottom, centred. Two concentric rings —
40 pt outer, 22 pt inner, both 1.6 pt in `ringQuiet` — 16 pt above the text.

> **All quiet**
> No sessions are running

Then the ordinary footer, and the Limits section as always — the Claude Code
caveat row is permanent, so Limits never disappears entirely.

### Many sessions

Rows scroll: a `ScrollView` capped at **340 pt**, with a 36 pt fade at the bottom
edge hinting at more below. The footer never scrolls.

It has to be a real **mask**, not an overlay:
`.mask(LinearGradient(colors: [.black, .clear], …))` plus
`.allowsHitTesting(false)`. An overlay would need a colour to fade *to*, and on
glass there is none — fading to an opaque neutral would band against the material,
the same mistake `hoverOverlay` exists to avoid. The canvas's `pointer-events`
is a CSS artefact of the mock.

> **Deviation.** The canvas mock caps at 280; its screens document says ~340 in
> prose. The prose wins — 340 shows one more group without making the panel
> unwieldy.

### Unknown session

An ordinary row, dashed-ring shape, unknown tint, and a prose detail line rather
than a bare duration:

> Stopped reporting · last seen 18m ago

This is a real state, not an error path: AgentBar genuinely has no opinion. The
row stays until the watchdog evicts it.

### Integration status and onboarding

The card that answers "why is nothing appearing?". Its content is one row per
provider, built from that provider's install report — `ClaudeCodeInstallReport`
and, since step 09, `CodexInstallReport`.

**When it is shown.** Empty list and "not installed" are different facts, and
conflating them turns a quiet morning into a broken app. The precedence, in
order — the first matching rule wins:

1. **The snapshot is not empty** → the session list, always. Never the card. Any
   degraded integration is carried by the footer instead; a user with sessions
   running does not need to be told to install anything.
2. **The snapshot is empty and any integration is in a state that guarantees no
   event can arrive** — `notInstalled`, `endpointUnavailable`,
   `settingsUnreadable`, or `needsRepair` carrying `urlNotAllowed` → the card.
   These are the states where "nothing is running" would be a lie.
3. **The snapshot is empty and every integration is `installed`** → *All quiet*.

Neither half of that decision is in `StoreSnapshot`: `isEmpty` answers only the
first clause, and the rest lives in each provider's install report, which is disk
I/O and is called by nothing in the app today. That is a step 06 obligation — see
[Obligations](#step-06--menu-bar-ui).

The footer status is itself a button: pressing it opens this same card in place,
so the surface is reachable at any time and not only on first run.

Card padding 20 top / 18 sides / 6 bottom.

> **Get Started**
> Sessions and notifications appear once every step below is done

("both" would be wrong the moment the number of integrations is not two — and it
is one today.)

Then one row per provider — 26 pt badge, name in Row title, status in Caption, a
button on the right — separated by 1 pt dividers, 10 pt of vertical padding
each. Buttons: padding 6 / 12, radius 7, Body medium, no wrapping.

| Install state | Status line | Action |
|---|---|---|
| `.notInstalled` | `Not connected` | `Connect`, filled `stateWorking` |
| `.installed` | `Connected`, filled circle in `connected` | none |
| `.needsRepair([drift])` | `Needs repair`, in `stateWaiting`, with the first drift's own sentence on a second line | `Repair` |
| `.endpointUnavailable` | `Installed, not receiving` | `Retry` |
| `.settingsUnreadable(reason)` | `Can't read its configuration`, in `stateFailed`, with `reason` on a second line | `Reveal in Finder` |
| Installed, not trusted — **Codex only** | `Installed, not trusted`, in `stateWaiting`, preceded by the waiting triangle | `Trust`, filled `stateWaiting` |

Every drift case already carries a finished English sentence in its
`description`; the card renders it and formats nothing itself. When several
drifts are present, show the first and append `and N more`.

`.settingsUnreadable` gets **no write action of any kind**. AgentBar refuses to
write over a file it could not read, and the UI must not offer to.

The line names no file, and that is a step-09 correction: the Codex row reaches
this rung through `hooks.json`, and a status line reading `Can't read
settings.json` under it would name a file Codex does not have. The reason line
under it comes from the report and names the real one.

#### What an action leaves behind

An action that writes has three outcomes and all three need a face. `install`
throws six `ClaudeCodeInstallerError` cases, and one of them —
`claudeDirectoryMissing` — is reachable from the `.notInstalled` row's own
`Connect` button, because a machine with no `~/.claude` at all reads as
"not installed" and then fails at the write.

| Result | Row becomes |
|---|---|
| `ClaudeCodeInstallOutcome.changed == true` | the state its next report gives, normally `Connected` |
| `changed == false` — the file already said what AgentBar wanted | `Connected`, with `Nothing to change` as a transient second line. A no-op must not look like a failure |
| a thrown `ClaudeCodeInstallerError` | the row keeps its previous state and gains the error's own text as a second line in `stateFailed`. The action stays available |

`Retry` on `.endpointUnavailable` is **not** a bare `IngestService.start()`: that
throws `alreadyRunning` when an endpoint is already bound. It means "bind if not
bound, then re-read every report" — and if an endpoint *is* bound, re-reading the
report is the whole of the work, because the state was stale.

`backupURL` is not shown. A backup is AgentBar's own artefact, and telling the
user about a file they did not ask for is noise; the installer's own log has it.

`Installed, not trusted` is a hard requirement, not a nicety: writing Codex's
config is not enough, and without this row the user gets an app that silently
shows nothing.

Footnote below the card, Caption, `ink400`, 1.5 line height:

> Codex only runs hooks you've explicitly trusted — until then it stays silent.

#### Warnings

`ClaudeCodeInstallWarning` values are not faults and must not take a fault's
colour. They render as Caption lines in `ink400` beneath their provider row,
each prefixed by the `ⓘ` glyph, using the warning's own `description`. There are
at most two.

#### Coexistence

`ClaudeCodeInstallReport.overlaps` is the "detect and report, change nothing"
rule made visible. When the list is non-empty the card gains one Caption line:

> Other hooks are installed here: 2 notifiers, 1 keep-awake, 3 others

with the individual `ForeignHookOverlap.summary` lines revealed on click. The
three nouns map to `ForeignHookOverlap.Family`: `notifier` → "notifier",
`caffeine` → "keep-awake", `other` → "other". `.other` is the *common* case, not
the rare one — any foreign handler on an event AgentBar watches is reported — so
it needs a real noun rather than being folded into the first two. Each is
pluralised through a `.stringsdict` entry, including its zero case, and a family
with no members is simply absent from the line. It is
informational, in `ink400`, and offers no action — AgentBar does not touch a
foreign entry, and the UI must not imply that it might. Its value is explaining
a doubled notification or a competing power assertion before the user files it
as a bug.

#### What is deliberately not surfaced

`IngestDiagnostic` has seventeen cases across three severities and gets no panel
of its own in the MVP; it goes to the log. The two a user must act on already
reach them through the install report, which is the right place because the fix
is a write to their settings file:

| Diagnostic | Reaches the user as |
|---|---|
| `portMoved` | `.needsRepair([.endpointChanged])` → `Repair` |
| `credentialReplaced` | `.needsRepair([.tokenChanged])` → `Repair` |

A failure to start ingest at all surfaces as `.endpointUnavailable` on every
installed provider. That is the honest reading: the hooks are fine, AgentBar is
not listening.

### The first-run flow

**Added in v2, and it does not replace the card above.** The two surfaces answer
different questions and both stay.

| | First-run flow | `Get Started` card |
|---|---|---|
| When | once, on first launch | any time the snapshot is empty and an integration blocks events; also on demand from the footer |
| Shape | five sequential steps | one card, one row per provider |
| Teaches | where the app lives; what it will do | why nothing is appearing right now |
| State | derived, transient | derived, permanent |

**The whole design rests on one decision: the flow hangs from the status item.**
AgentBar has no Dock icon and no window, so the single most important thing a
first launch has to teach is a *location*, not a feature. A centred window
explaining notifications teaches the wrong thing — the user reads it, closes it,
and then cannot find the app. Presented through `PanelController` at **420 pt**
with the status item highlighted, the eye goes to the menu bar within the first
second.

| # | Step | Purpose | Advances by |
|---|---|---|---|
| 1 | Welcome | teach the location; three one-line capability bullets | button, or skip |
| 2 | Claude Code | install the hook, honestly | button, or skip |
| 3 | Codex | install **and** trust, as two visible stages | button, or skip |
| 4 | Notifications | request authorisation, showing a real banner first | button, or skip |
| 5 | Done | confirm state, hand off to the panel | button closes |

Below the step: a five-segment progress rail, 3 pt tall with 5 pt gaps, and
`Step %lld of %lld · %@` centred beneath it. Segments rather than dots — dots do
not communicate remaining length, and five steps is enough that a user wants to
know how much is left.

**State comes from the real reports, never from a local flag.** The flow
persists exactly one boolean: whether the first run has happened. Everything else
is derived from `IntegrationStatus` and the notification authorisation, re-read
on entry to every step and on a three-second poll while an install step is
showing — a user who runs the installer in a terminal, or answers Codex's own
trust prompt, has to see the step flip without pressing anything here. An early
draft also kept a set of skipped steps; it was deleted, because a step is skipped
exactly when its provider is still not connected, and a second answer to that
question is the failure mode this design exists to avoid.

**Steps 2 and 3 owe three facts in the step itself**, not in a footnote and not
behind a link, because they write into a file the user owns: what is read
(*status events only — never your code or your conversation*), where it lives
(*~/.claude/settings.json*, *~/.codex/hooks.json*), and that it is reversible.
Step 3 draws Codex's two stages as a progression, because "I installed it, why is
nothing happening" is what that requirement produces when it is only explained.

**Step 4 shows before it asks.** A real banner built from the real attachment art
sits above the permission button, so *no surprises* is true rather than a claim.
Three authorisation outcomes need a face, and the third has a rule: `.denied`
offers **Open System Settings** and **never re-prompts** — macOS shows its prompt
once per app and silently ignores a second request, so a button that re-asked
would visibly do nothing.

**A skip is never punished.** Nothing is written and nothing is logged as an
error; skipping step 1 jumps to the summary, which then reports honestly what is
and is not set up, in secondary ink. No red, no warning glyph, no "incomplete".
The copy table anticipated two outcomes, `connected` and `skipped`; a provider
that is installed and not yet trusted is neither, so every rung of
`IntegrationCondition` gets a phrase and all of them read as quietly as
`skipped`. The tone carries "recoverable"; the wording carries the fact.

**`PanelContent.decide` is untouched.** The flow sits *before* that decision
rather than inside it — the controller chooses between "show the flow" and "show
the panel", and only in the second branch does `PanelContent` apply. Folding it
in would have made a tested pure function depend on a persisted flag.

> **The status item is not made to lie.** The design asks for the menu-bar glyph
> to come alive on the last step. A status item pulsing *waiting* while nothing
> is waiting would be the app's first act being false, so the live figure is
> drawn inside the card instead — the highlight already does the pointing.

Under Reduce Motion the whole flow cross-fades at 150 ms: no drop, no rise, no
glow, no stagger.

---

## Notifications

`UNMutableNotificationContent`. macOS owns the chrome; the design owns content
and hierarchy: **what needs me → which agent → where →** one line of detail.

| Field | Content |
|---|---|
| `title` | `{What} · {project}` |
| `subtitle` | the provider's display name |
| `body` | the one relevant detail line |
| attachment | the **event**'s art, pre-rendered per event |
| `categoryIdentifier` | one per event type |

> **Revised in v2: the attachment says what happened, not which app it is.** It
> used to be one square per *provider*, which spent the only graphic surface the
> app controls on a word the `subtitle` — then unused — can carry for free, three
> centimetres from a leading icon slot that is always AgentBar's own and cannot
> be replaced. The square now carries the event, and there are exactly four
> decisions in a banner that are ours: this image, the three text slots, the
> actions, and the grouping.

The five verbs: **Question · Approval · Waiting · Finished · Failed**. Each is
the first word, so a banner truncated at ~30 characters still delivers the meaning. The
longest realistic title, `Finished · agentbar-web`, is 23.

**`Question` is selected only when the question line exists.** Question paths —
Claude Code's `PreToolUse(AskUserQuestion)` and Codex's
`PreToolUse(request_user_input)` — decode to `EventKind.waitingInput`. The push
signal carries the domain question line, never either provider-specific tool
name.

So Question is chosen by **the presence of the question line, not by a provider
tool name**: a `waitingInput` notification that has a line is titled `Question`,
one without is titled `Waiting`. `waitingPermission` is independently titled
`Approval`, with its bounded safe summary when one exists.

Each verb is a predicate on the `StateChange`, not a vibe. `from` and `to` are
both optional and both nils are reachable, so they are named explicitly:

| Verb | Fires when | Body |
|---|---|---|
| `Question` | `to.kind == .waiting` **and** a question line is present | the question line |
| `Waiting` | `to.kind == .waiting` and no line | none — the title is the whole message |
| `Approval` | `to` is `.waitingPermission` | the safe permission summary |
| `Finished` | `from != nil` **and** `to == .idle` | none — nothing counts what a turn changed |
| `Failed` | `to` is `.failed` | the reason |

Question, Approval, Waiting and Failed are urgent: the presenter is called on
the next main-actor turn, with no 1.5-second timer. The first fingerprint is
delivered immediately and an exact repeat within 1.5 seconds is suppressed.
Finished remains deferred through the existing 1.5-second coalescing window.
A newer urgent state cancels an older pending Finished draft for the same
session, preventing stale completion news from replacing the actionable banner.
The implementation budget from accepted hook event to queuing an urgent banner
is 100 ms on an otherwise local machine; macOS banner presentation is outside it.

Two `StateChange` shapes fire **nothing**, and both are reachable:

- **`from == nil`** means the store adopted a session it had not seen — AgentBar
  launching beside an agent already running, or a bare session announcement. It
  produces `nil → idle`, which would otherwise fire `Finished` for a turn that
  never happened here.
- **`to == nil`** means the session left the store, by `sessionEnded` or by the
  watchdog evicting it. Neither is news: nothing needs the user.

`unknown` also gets no notification. It is the absence of information, and waking
someone to tell them you have stopped knowing is not worth an interruption; the
row and the status glyph carry it.

The canvas's `3 files changed` example has no source and is not implementable —
see [Obligations](#step-07--notifications). macOS renders a title-only
notification cleanly, so an absent body costs nothing but an invented one would
cost the product its honesty.

Provider error strings pass through verbatim: never localised, never prettified —
but **clamped**. `failureReason` passes an unrecognised error type through with no
length bound and `NativeEventDecoder` applies none either, so the body takes the
first 60 characters on a word boundary and drops the rest. The system truncates
anyway; doing it deliberately means the cut lands somewhere readable.

The provider is carried by the `subtitle`, always. The provider-naming title —
`Question · Claude Code · agentbar-web` — stays as a safety net for the path
where no art could be attached: `subtitle` is a slot the system may truncate or
drop before it truncates the title, and losing which agent is asking costs more
than a repeated word does on a rare path.

**The title is chosen by whether art was actually attached, not by whether a file
was found.** `UNNotificationAttachment` can still refuse a file that exists — it
was consumed by an earlier post, or it fails the system's own validation — so the
decision belongs at the point of attachment and not at the point of lookup. It is
subtle and it is correct; do not simplify it.

### Attachment art

Five squares, one per verb, each carrying the same three-node figure as the menu
bar so the banner, the status item and the app icon are visibly one family.
**Silhouette first, colour second** — verified by desaturating all five and
comparing them, because five gradients are trivially distinguishable and prove
nothing.

| Event | Figure | Base token |
|---|---|---|
| Question | apex filled, ring leaving it | `stateWaiting` |
| Approval | waiting agent inside a shield outline | `eventApproval` |
| Waiting | all three nodes filled | `stateWorking` |
| Finished | all three filled, enclosed in a closed ring | `connected` |
| Failed | apex is a rounded square | `stateFailed` |

`Waiting` and `Finished` draw the same nodes — both mean "the agent is not
working right now" — and the enclosing ring is the whole of what tells them
apart. Losing it would leave two squares differing only in hue.

```
canvas       256 × 256 px, generated; the system clips it to ~38 pt
gradient     linear, 155°, light stop → dark stop
top sheen    radial white, 45 % → transparent, centred 22 % / 8 %
figure       the three-node glyph at 56 % of the canvas, in onAccent white
```

Each gradient is two stops derived from its semantic `ColorToken` at ±12 % OKLCH
lightness, held in `AttachmentRamp`. Approval introduces `eventApproval`, a
semantic purple role distinct from `stateUnknown` even while their current values
match. Rendered in the
**light appearance always**: an attachment is not re-rendered when the system
theme changes, so a dark-appearance square would be wrong half the time.

There is deliberately **no sixth square for `unknown`**. `NotificationPolicy`
returns `nil` for it and that stays true, so a sixth ramp would be a colour pair
nothing can ever ask for.

**No actions ship.** A `Reply` field on the banner needs a channel from AgentBar
into a running agent session, which is impersonation under the safe-superset
rule; and a text channel into a permission prompt is a mechanism by which a
dropped connection could resolve into a granted permission, which the
never-auto-approve rule forbids without exception. Categories keep `actions: []`
so `Approve`/`Deny` can arrive later without orphaning anything delivered.

**The stack summary is not ours.** `threadIdentifier` groups per project and
macOS composes the string above a group; there is no API to set it. The panel
header carries our own summary, and that one *is* ours.

The `{project}` slot is the bare `ProjectRef.name`, **not** the panel's
disambiguated label. A notification is emitted per event and has no view of what
else is on screen, so the panel's collision rule is not available to it; and
appending a path fragment to every title would cost the glanceability that the
`what → which agent → where` hierarchy exists for. Two worktrees of one
repository therefore produce two identically-titled notifications. That is
accepted, not overlooked: the panel is one click away and disambiguates.

**Leading image.** The canvas mocks a Messages-style large provider avatar with
a small AgentBar badge in its corner: 38 pt image at radius 10, 16 pt badge at
radius 5 offset −3 / −3, ringed 2 pt in the banner's own background. That
composite has to be generated and attached as a `UNNotificationAttachment` — one
static PNG per provider, rendered once.

> **Deviation, step 07: the corner badge is dropped.** On macOS a banner already
> shows the **app's own icon** in its leading slot and places an attachment as a
> separate thumbnail beside it, so an AgentBar badge in the corner of the
> attachment would repeat the app icon three centimetres from itself. This
> section's own instruction for that case is to match the intent, not the pixel.
>
> **Revised again in v2: the provider tile is dropped too.** Step 07 kept the
> tile alone, and the same argument that killed the corner badge applies one step
> further — the `subtitle` says `Claude Code` in words for free, so a square
> repeating it wastes the only graphic surface the app controls. What ships is
> [the event's art](#attachment-art). `ProviderBadgeImage` went with its last
> caller; `ProviderBadge`, the view, stays, because the panel rows use it.
>
> The attachment is re-rendered on demand: `UNNotificationAttachment` **moves**
> the file it is given into the notification's own store, so every square is
> consumed by its first use. When it cannot be produced at all the title becomes
> `Question · Claude Code · agentbar-web`, as specified above.

Approval has its own registered category, with `actions: []`. Approve/Deny remain
out of scope: the hook fingerprint is observation state, not a reply handle, and
the user answers only in Codex.

**Never auto-approve.** No notification path — timeout, dismissal, dropped
delivery, failure to render — may ever resolve into granting a permission. This
applies pre-emptively to any future buttons.

### The sound set

Four files in the bundle root serve five verbs and are the defaults the matrix
ships with. Approval reuses `AgentBar Waiting.aiff` by default but remains a
separate matrix row, so the user can choose another sound for it without changing
Waiting. A fifth authored file is not part of this stage.

| File | Interval | Length | Verb |
|---|---|---|---|
| `AgentBar Question.aiff` | D4 → G4, a fourth **up** | 560 ms | Question — a question rises |
| `AgentBar Waiting.aiff` | G4 → E4, a minor third down | 509 ms | Waiting |
| `AgentBar Finished.aiff` | G4 → C4 with a sub C3 | 718 ms | Finished — a resolution, and the only one with weight under it |
| `AgentBar Failed.aiff` | C4 → A♭3 | 450 ms | Failed |

48 kHz, 24-bit, mono, Linear PCM, peak −3 dBFS, and the four sit within 0.4 dB
of each other in RMS so no one event is louder than the rest by accident. Under
1.1 % of each one's energy lives in the 2–5 kHz band the ear is sharpest in,
which is what keeps a notification that fires twenty times a day from becoming
the reason the feature gets turned off.

**AIFF rather than the authored WAV**, converted losslessly — the PCM is
bit-identical, byte order and container aside. `/System/Library/Sounds/Glass.aiff`
is 48 kHz 24-bit AIFF, so this is the format macOS itself ships notification
sounds in; and keeping the file *names* unchanged means a stored selection from
an earlier build still resolves, which a change of extension would have broken
silently — a missing sound plays as the system default with no diagnostic
([ADR-0006](../adr/ADR-0006-notification-sounds-are-files-agentbar-can-resolve.md)).

**Per-event volume offsets are not implementable and are not applied.**
`UNNotificationSound` takes a file name and nothing else — no volume — so the
files ship at the level they were authored at. Applying an offset in
`SoundPreview` alone would be worse than not applying one: the audition would
stop matching the notification, which is the one thing the play button exists to
prove.

---

## The app icon

A network of three agent nodes: two calm ones at the base, one at the apex inside
a soft pulse ring — the one that needs you. It reads as *connected agents* and as
*monitoring* at once, which is the product in one glyph. Original work; no
third-party brand asset is used or referenced.

Geometry, in a 200 × 200 box, mirror-symmetric about `x = 100` and to be kept
that way in any redraw:

| Element | Value |
|---|---|
| Base nodes | circles at (55, 130) and (145, 130), r 17 |
| Apex node | circle at (100, 55), r 21, `stateWorking` blue `#407CC5` — the same token as the Working state, reused on purpose |
| Pulse ring | circle at (100, 55), r 30, stroke 3, `#6AA7F4` at 50 % |
| Edges | (55,130)→(100,55), (145,130)→(100,55), (55,130)→(145,130), stroke 9, round caps |
| Tile | dark, `#22272C` → `#05080B` |

**It is a layered Icon Composer document, not a bitmap.** macOS 26 renders an
icon in light, dark, tinted and clear appearances and applies its own depth and
specular pass; a flat `.icns` is pasted into all four unchanged. `AgentBar.icon`
gives the system the tile fill and two layers — the accent apex in front, the
white network behind — and lets it do the rest. Everything about the document's
layout, including the two ways it fails silently, is in
[platform-integration.md §8](platform-integration.md).

The colour lives only in the apex node, so the mark survives the tinted and mono
appearances as a shape rather than as a picture of one.

The **menu-bar status glyph is a separate asset** and is not derived from this
mark. It was drawn standalone for legibility at 16 pt monochrome, and it carries
state, which the app icon never does.

---

## Settings window

Added by step 07. This document deferred a settings screen and reserved the
footer gear for it; the sound matrix has to be editable, so the screen exists
now.

**It is deliberately not the panel's vocabulary.** A settings window is system
chrome: a titled `NSWindow` — with the title bar made transparent in v2, so the
buttons sit on the sidebar — around a sidebar and a grouped SwiftUI `Form` of
native controls. Three reasons. macOS users already know what one looks like and
how it behaves. Reproducing the panel's glass in a resizable window would need the dark
chip inks [design-system.md](design-system.md) says do not exist yet, which would
mean designing rather than transcribing. And a form of standard controls inherits
every accessibility behaviour — focus order, VoiceOver, Full Keyboard Access —
that the panel had to build by hand.

What it does take from the design system is the type scale, the ink tokens, the
provider badge and the **state shapes**, so a Waiting row in the matrix is
recognisably the same Waiting as the session row and the status glyph.

**Activation.** Unlike the panel, this window activates the app and takes key
status. It is asked for by name with a click, and a window the user cannot type
in would be worse than the focus rule it would be honouring. Closing it calls
`NSApp.hide` — otherwise an accessory app is left active with nothing on screen
and every keystroke going nowhere.

Opens at 932 × 640, resizable, and **never larger than the screen it opens on**.
The resize minimum is 850 × 420, and it is **derived** — from what the matrix
needs at every provider the domain has, plus the grouped form's own insets, plus
the sidebar's fixed width — rather than chosen beside it. It scrolls vertically;
it never scrolls horizontally.

### The sidebar

**Added in v2**, and the one part of the mock this window had refused. The
argument for refusing it was that there was no split view to give a selection
fill to; the answer is that there is one now, because a settings window with
seven sections and no navigation is a window you scroll to find things in.

A fixed 212 pt column: the app's mark and name, a hairline, then one row per
section. The rows are `Notifications`, `Quiet Hours`, `While You're Working`,
`Sounds`, `Caffeine`, `General` and `About` — the last two beyond what the mock
drew, because the mock did not know about them and dropping either would have
hidden a real setting. The mock's width is 200; the extra twelve points are what
*While You're Working* needs at the system's own sidebar text size, and shrinking
the text to fit a mock is the wrong way round.

- **Glass here and nowhere else in this window.** Long lists of settings text
  over a blurred backdrop are measurably harder to read and the content pane has
  no reason to show what is behind the window. Under Reduce Transparency the
  sidebar becomes a flat `surface` fill, the same rule the panel already follows.
- **The traffic lights sit on it**, with no title bar of their own —
  `fullSizeContentView`, a transparent title bar, and a hidden title. Three
  decisions that only work together, and the room for the buttons comes from the
  window's own 32 pt safe-area inset: the sidebar's *content* respects it, its
  *glass* ignores it. Paying for it twice pushes the whole interface an inch down
  the window, and paying for it never puts the buttons on a bare strip.
- **Selection is a filled pill** — radius 9, the accent at 0.14 light / 0.18
  dark, no hairline — and the row's ink takes the accent too, so the selection is
  never carried by a fill alone. Hover on an unselected row is `hoverOverlay`.
- **A focus ring**, read from inside the row's own `ButtonStyle` the way
  `SessionRowButtonStyle` already does it in the panel — `.plain` draws no focus
  indication of its own, and this is the one hand-rolled navigation list in a
  window whose stated reason for native controls is that they inherit Full
  Keyboard Access. The ring is the system accent rather than `stateWorking`, so
  it cannot be mistaken for the selection fill it sits beside.
- **SF Symbols, not the mock's hand-drawn figures.** A settings sidebar is the
  most conventional list in macOS.

**It scrolls the content pane; it does not switch panes.** The sections stay one
continuous column with the preview block at its head — which is the only way the
preview can be what the design asks it to be, *above every section* rather than
above one of them — and a sidebar row moves the scroll to that section's heading.
The lit row therefore follows the last row pressed rather than the scroll
position, and that is a deliberate limit: making it follow the scroll means
measuring section frames on every scrolled frame, and publishing a measurement
out of layout is what once cost this app 98 % of a core in the panel.

The anchors live on the **section headings**, not on the `Section`s. A `Section`
in a grouped `Form` is a layout container rather than a view in the scroll's own
content, and an `.id` on one is not reliably what `ScrollViewReader` finds.

**Pressing the already-lit row scrolls to it too.** The request that drives the
scroll carries a count as well as a section, and the count changes on every
press including a repeat — because the lit row does not follow the scroll, a
user who presses `Sounds`, reads on past it, and wants to come back has no
other way to ask than pressing `Sounds` again, and a request keyed on the
section alone would see no change and do nothing.

A scroll view lays its content out **into** its safe area rather than stopping
at it, so a heading at rest sits below the traffic lights but a scrolled row
runs up to the window's bare top edge — a control sliced in half against
nothing, with no title bar left to draw a material over it. The content pane
covers that strip with its own `canvas` fill, sized from the same safe-area
inset the sidebar reads, so a scrolled section stops exactly where the buttons
begin rather than running under them.

> The title is still set on the window even though nothing draws it: that is what
> VoiceOver and the window list announce, and hiding a window's title bar is a
> different decision from hiding its name.
>
> The window's own sizing had to change with the chrome. `contentLayoutRect` — the
> part of the content *not obscured by the title bar* — is no longer the same
> quantity `setContentSize` sets, so the re-showing path reads
> `contentRect(forFrameRect:)` instead. Left alone it would have reported the
> window as 32 pt shorter than it is and shrunk it by a title bar on every visit.

> **Step 11: it opened 620 wide around a form that could not be drawn narrower
> than 710.** SwiftUI does not refuse that. It lays the form out at 710 anyway,
> centred, and the 45 pt hanging off each side is clipped — no horizontal
> scroller, no diagnostic. What the user saw was a settings window with the verb
> labels cut off the left edge. The 620 × 620 in the line above used to read
> "minimum 560 × 520, opening at 620 × 620", and it was right when it was
> written: the matrix had **one** column. Step 09 added the second and nothing
> re-measured the window it had to fit in.
>
> Two changes close it and they are independent. The opening width and the
> resize minimum are computed from `NotificationMatrixView.minimumWidth(_:)`, so
> the window cannot be smaller than the form it holds; and the matrix's provider
> columns compress, so a narrower window would squeeze rather than clip.
> `SettingsWindowSizingTests` pins the relationship by asking SwiftUI what the
> form's minimum actually is — the only way to observe it, since an overflow
> reports nothing.
>
> Sizing is also **clamped to `NSScreen.visibleFrame`** and re-measured on every
> showing rather than only the first. Nothing forced this window off the display
> before, but nothing stopped it either, and a Mac undocked from an external
> monitor would otherwise reopen a window larger than the screen it is now on.

### Sections, in order

| Section | Contents |
|---|---|
| *(unnamed, conditional)* | The authorisation problem, when there is one. First in the window, because every other setting is moot if macOS will not deliver. Carries the failed state shape, the sentence, and either **Allow…** or **Open System Settings** |
| `Preview` | A live mirror of what the settings below would produce — see below |
| `Events` | The global switch, the matrix, one **Test {Provider}** button per registered provider, and the last action's result |
| `Quiet Hours` | Enable, plus From and Until at half-hour granularity |
| `While You're Working` | Enable, plus the application list with add and remove |
| `Sounds` | **Add Sound File…**, **Reveal Sounds Folder**, and every current sound problem |
| `Caffeine` | The three-state setting, a live status line, and the limitation |
| `General` | Launch at login, and its last error if it has one |
| `About` | The running version, and the one claim about this app worth making in the interface: it reads what the two tools already tell it, on this Mac only, and makes no network request to Anthropic or OpenAI. Added in v2 so the sidebar's last row leads somewhere |

Section headers use the panel's `sectionLabel` — 11 pt semibold, uppercase,
tracked — in `ink400`. Every section has a footnote in Caption explaining the one
thing about it a user cannot infer.

### The preview block

**Added in v2.** The window used to open onto a section: the user toggled
something and had to imagine the result.

The block is a miniature menu-bar strip over a desktop-tinted fill, with a banner
mock beneath it. Its one rule is why it is worth having: **it is built from the
code that ships.** The glyph is `StatusItemGlyph`'s own template image and the
square is `EventAttachmentImage`'s own art — neither is redrawn here, so the
preview cannot drift from the thing it previews. *A preview that can disagree
with reality is worse than no preview.*

- **It follows the matrix by ordered rules**, first enabled event wins. Turning
  `Question` off moves the preview to the next event the user would actually
  receive rather than to one they have just switched off. Nothing enabled — or
  the global switch off — replaces the banner with a sentence saying no banner
  will arrive.
- **It is a mirror, not a control.** Hit testing is off, so it cannot become a
  second, undocumented control surface.
- **The banner mock is approximate and should look it.** macOS owns that chrome;
  chasing fidelity invites a bug report. What it is accurate about is the four
  decisions that are actually ours — the art, the three text slots, the grouping
  and the sound.
- Static under Reduce Motion.

The preview keeps its place at the head of the content pane now that the
[sidebar](#the-sidebar) exists — the sidebar scrolls that pane rather than
replacing it, so *above every section* stays literally true.

### The matrix

A `Grid`: one row per verb, one column per **registered** provider. The columns
come from the providers the app assembly actually registers, never from
`Provider.allCases` — a Codex column before step 09 lands would offer settings
for notifications that cannot arrive, which is the footer's hardcoded `1 of 2`
mistake in another place. Since step 09 the app registers both providers, so
there are two columns; before it there was one, and the rule is what made that
correct rather than accidental.

**The provider columns are elastic; the verb column is not.** The verb column
holds a fixed amount of text at a fixed 168 pt; the provider columns share what
is left, with a 16 pt gutter and a floor of 172 pt below which the sound picker
stops being readable. Fixed widths for all three made the matrix the widest thing
in the window with no way to give — and a form wider than its window is clipped
rather than shrunk. The window's minimum width is derived from these three
numbers rather than chosen beside them.

The row label is the verb's state shape, the verb, and one line saying what the
event actually is — the settings window is the one surface with room for it:

| Verb | Shape | Colour | Explanation |
|---|---|---|---|
| Question | waiting triangle | `stateWaiting` | An agent asked you something |
| Approval | waiting agent in a shield | `eventApproval` | An agent requested access |
| Waiting | waiting triangle | `stateWorking` | An agent is blocked and needs you |
| Finished | idle hollow ring | `connected` | An agent finished its turn |
| Failed | failed rounded square | `stateFailed` | A turn ended in an error |

**The colour is the event's `AttachmentRamp` base, not the state's accent**, so
the matrix, the banner and the preview block agree about what colour an event is.
They deliberately differ from row-state accents where event semantics need more
precision: bare Waiting is blue, Approval is purple, and Finished announces the
accent-less idle state with a green resolution tile.

Each cell is a **Notify** checkbox, a sound picker, and a play button that
auditions the selection. The picker is grouped — Standard (Default, None),
AgentBar, Your Sounds — and a cell whose sound is unusable carries the problem
underneath it in `stateFailed`, in the sentence the sound library wrote.

**Test {Provider}** fires one real notification per enabled verb, through the
real delivery path. It is the step's own validation criterion handed to the user
rather than kept for a developer: nothing short of a real banner confirms that a
chosen sound plays, because `UNNotificationSound` falls back to the default
without saying so. It bypasses the coalescer and quiet hours — five notifications
a millisecond apart would collapse into one, and the settings window is frontmost
by definition — but **not** the matrix, so a disabled event sends nothing and the
test shows what the user will actually get.

### What the copy has to say and why

- Quiet hours: *a window that ends earlier than it starts crosses midnight, and
  both ends equal means no quiet hours at all.* Both readings of the second are
  defensible from the numbers, and only one of them can silently swallow every
  notification the product exists to deliver.
- Focus suppression: *AgentBar can see which application is frontmost, but not
  which project its window belongs to — so this silences every project, not just
  the one you are looking at.* Nothing in a hook payload says which project a
  frontmost editor window belongs to, so the feature is honest about its own
  bluntness and ships **off, with an empty list**.
- Sounds: *macOS plays notification sounds only from AgentBar's own bundle and
  from your Sounds folder, so a file added here is copied there.* This is the
  user-facing half of [ADR-0006](../adr/ADR-0006-notification-sounds-are-files-agentbar-can-resolve.md).
- Events: *a burst of activity in one session produces one notification, not one
  per event.* Otherwise coalescing looks like dropped notifications.
- Caffeine: *this stops the Mac falling asleep on its own while an agent works.
  It does not keep the display awake, it does not survive closing the lid, and
  macOS still sleeps when the battery runs low.* All three are hard limits of
  `PreventUserIdleSystemSleep` rather than of this implementation, and
  [design-brief.md](design-brief.md) §5 lists the second as a limitation the
  interface must state rather than hide.

### The Caffeine section

A three-state picker — **Never**, **While an agent is working** (the default),
**Always** — over the footer button's two states. It exists because "keep the Mac
awake" has two honest meanings, following the agents and simply staying awake,
and a switch makes one of them unreachable.

Beneath it, one live status line carrying the state shape as well as the sentence:
`Keeping your Mac awake · 2 working`, `Not holding · no agent is working`,
`Caffeine is off`, or the system's own refusal in `stateFailed`. It is shown for
**every** setting, including `Never`: a Caffeine switched off beside three working
agents is exactly the situation a user opens this window to understand.

---

## Domain coverage

The step's own validation criterion: walk every domain state and confirm it has a
representation. Everything `AgentBarCore`, `AgentBarIngest` and
`ClaudeCodeAdapter` can hand a view, and where it lands.

### Session state

| Domain | Representation |
|---|---|
| `SessionState.idle` | hollow-ring row, no tint, no detail line |
| `SessionState.working` | filled-dot row, mono detail line |
| `SessionState.waitingInput` | triangle row, waiting wash |
| `SessionState.waitingPermission(_)` | the same waiting row and wash, because the action remains in the provider. Its distinction appears in the Approval notification label, shield and optional safe summary; there is no Approve/Deny affordance |
| `SessionState.failed(reason:)` | rounded-square row, failed wash, reason in the detail line |
| `SessionState.unknown` | dashed-ring row, unknown wash, silence in the detail line |
| `SessionStateKind` | the five row shapes, the five status glyphs, the notification verbs |
| `attentionRank` | status-item priority, unchanged |

### Session fields

| Domain | Representation |
|---|---|
| `provider` | badge colour and glyph |
| `project` | group header |
| `state` | shape, label, tint |
| `currentTool` | detail line, working only |
| `activeSubagentCount` | `+N` pill when > 0 |
| `timeInState` | the row's duration |
| `timeSinceLastEvent` | the unknown row's detail line |
| `uptime`, `startedAt` | row tooltip and long accessibility description |
| `lastEventAt` | not rendered — `timeSinceLastEvent` says the same thing in the form the row needs |
| `model` | **deliberately not rendered.** The row already carries five things, and every element has to earn its place. It is also `nil` for every Claude Code session: it arrives only on `SessionStart`, which takes no `http` handler. Kept for Codex and for the dashboard |

### Store

| Domain | Representation |
|---|---|
| `StoreSnapshot.projects` | the list, in the store's own order |
| `isEmpty` | half of the empty-vs-onboarding decision |
| `mostUrgentState` | the status glyph |
| `waitingSessionCount` | the optional numeral, when > 1 |
| `isAnyAgentWorking` | not drawn as such. The count of working sessions drives the power assertion and appears in the Caffeine tooltip and status line |
| `finished`, `FinishedSession`, `FinishOutcome` | **no MVP surface.** The dashboard is deferred; the footer gear is the entry point left for it |
| `ApplyOutcome`, `IgnoreReason`, `StateChange`, `RawPayload` | not drawn, on purpose. A stream of `duplicate` ignores — the one a user could act on — reaches them as `ClaudeCodeInstallDrift.duplicateHandler` on the integration card, which is the actionable form |
| `ProjectRef.root` | the group header's disambiguating suffix, and its tooltip |
| `ProjectRef.worktree` | extra context on a disambiguated header when it differs from the computed name. Always `nil` today — `PathProjectResolver` never fills it — and never the disambiguator |

### Install and ingest

| Domain | Representation |
|---|---|
| `ClaudeCodeInstallState`, all five cases | one row of the integration card each |
| `ClaudeCodeInstallDrift`, all eight cases | the `needsRepair` row's second line, using each case's own `description` |
| `ClaudeCodeInstallWarning`, both cases | muted `ⓘ` lines under the provider row |
| `ForeignHookOverlap` | the coexistence line, expandable |
| `ClaudeCodeInstallOutcome` | the row after a write: `changed == false` becomes a transient `Nothing to change` rather than looking like a failure. `backupURL` is not shown — a backup is AgentBar's artefact, not the user's business |
| `ClaudeCodeInstallerError`, 6 cases | a second line on the provider row in `stateFailed`, using the error's own text, with the action left available. `claudeDirectoryMissing` is the reachable one: a machine with no `~/.claude` reads as `notInstalled` and then fails at the write |
| `IngestDiagnostic`, 17 cases | the log. Two of them resurface through the install report as drift; a dead endpoint resurfaces as `endpointUnavailable` and as the footer's `Not receiving events` |
| `IngestEndpointError.alreadyRunning` | never shown. It is what makes `Retry` mean "bind if unbound, then re-read", not a bare `start()` |

### Not represented, and why

| Domain | Why not |
|---|---|
| `Session.model` | earns no place in the row; always `nil` for Claude Code |
| `StoreSnapshot.finished` | the dashboard is out of scope for this pass |
| `ApplyOutcome` / `IgnoreReason` | diagnostics, not status |
| Subagent names | the store keeps `Set<AgentID>`, so `AgentRef.subagent(id:type:)`'s `type` is discarded before the UI could see it. `+2` rather than `+2 (Explore, Plan)` is a deliberate ceiling, and lifting it is a domain change |
| Watchdog timeouts | not explained anywhere in the panel; the unknown row's "last seen" is the user-facing form |

---

## Obligations on later steps

What this design requires that does not exist yet. Each is a contract, not a
suggestion — the surface above cannot be built honestly without it.

### Step 06 — menu-bar UI

**Delivered.** All seven, plus the question line below. Three deviations, each
recorded where it belongs: the panel is an `NSPanel` (above), the tokens are
Swift rather than an asset catalog and the sparkle is a concave star
([design-system.md](design-system.md)). Kept for the record because the
reasoning is what a later step needs, not the tick.

1. A view model holding both the latest `StoreSnapshot` **and** an integration
   status per provider. Neither alone decides what the panel shows. Statuses are
   refreshed on panel open and after any install action, never on a timer:
   `report(for:)` is disk I/O.
2. **A push leg out of the ingest boundary.** `EventIngestHandler` counts the
   `[ApplyOutcome]` that `apply()` returns and discards it; nothing can observe a
   state change. Forward the `.changed(StateChange)` outcomes to an app-level
   observer. Without it the status item — and step 07's notifications — learn
   about a waiting agent only when the next poll comes round.
3. The timers in [Panel](#panel): 1 s while open, 30–60 s while closed. Nothing
   calls `sweep()` today either.
4. The five status glyphs drawn with `NSBezierPath` from the geometry in
   [Status item](#status-item), `isTemplate = true`. Drawing rather than shipping
   five PDFs also settles the light/dark pair question, and it makes
   `StatusItemController`'s current `"AB"` text fallback unreachable — a symbol
   name can be withdrawn between releases, a path cannot.
5. Both provider glyphs drawn in code, sized as a fraction of the badge so one
   implementation serves every badge size: the sparkle's bars at 12 % of badge
   width and 54 % of its height, crossed and rotated 45°; `</>` as SF Mono at
   46 % of badge height, tracking −1.
6. The integration card built against that same UI-owned type, so the Codex row
   can render before step 09 exists without the card being restructured.
7. **A panel that can open either way**, because key status depends on which was
   used — see [Session row](#session-row). A click on the status item must not
   activate the app; opening as key window must be possible for when a shortcut
   exists. Build the capability and leave the trigger as a seam; do not pick a
   global key combination here. A single code path that always does one or the
   other breaks either the focus rule or the keyboard requirement.
#### Where the integration status lives

`AgentBarUI` cannot hold a `ClaudeCodeInstallReport`. Its only permitted import
is `AgentBarCore`, and `ModuleBoundaryTests.allowedInternalDependencies` fails the
build if that changes; CLAUDE.md's rule that nothing above the adapter knows the
providers exist says the same thing from the other direction. A view model that
took an install report would be an architecture violation caught by a test, not a
style question.

So the abstraction is **declared in `AgentBarUI` and populated by the app
target**, which is already the assembly point and already links every module:

- `AgentBarUI` declares a plain value type — `Provider`, a status line, an
  optional second line, an indicator state drawn from `SessionStateKind`'s own
  palette, and an action identified by a UI-level case (`connect`, `repair`,
  `trust`, `retry`, `revealInFinder`, `none`). `Provider` is legitimate here:
  `Provider.swift` sanctions it as a label, and only the UI attaches a colour and
  a glyph to it.
- `Apps/AgentBar` maps each provider's own report onto it — the switch over
  `ClaudeCodeInstallState`, its drift and its warnings lives there, next to the
  installer it belongs to.
- The action cases come back to the app target, which knows which installer to
  call.

That keeps every provider word out of `AgentBarUI`, needs no new module and no
change to the dependency table, and lets a preview construct a status directly —
which matters, because `ClaudeCodeInstallReport` has no public initialiser.

**Do not put the type in `AgentBarCore`.** The core is the domain and owns no
install vocabulary; adding one there to satisfy the view would be exactly the
kind of leak the boundary test exists to prevent.

### Step 06 or 07 — the question line — **landed in step 06**

The `Question` notification is specified to carry "the question asked" as its
body, and nothing in AgentBar can produce that string.

The facts, all verified: `SessionState.waitingInput` carries no payload;
`ClaudeCodeEventDecoder` never returns `.waitingPermission`, so no adapter
produces a `PermissionRequestRef` even though `NativeEventDecoder` can already
decode one off the wire; `ToolInvocation.summarise` deliberately returns `nil`
for `AskUserQuestion`; and `SessionStore.reading` clears `currentTool` outside
`working`. Four independent reasons, any one of which is sufficient.

The decision is to close it rather than ship around it, because "an agent asked
you something" is the single event the product exists for, and a notification
whose body is empty on that event is the one place the design's
*what → which agent → where → one line of detail* hierarchy loses its last term.

The decision, its three rejected alternatives and its consequences are recorded
in [ADR-0005](../adr/ADR-0005-waiting-input-carries-a-question-line.md), status
`proposed` until the step that implements it. What follows is the summary.

Required, as a bounded addendum to steps 02 and 04:

- `EventKind.waitingInput` and `SessionState.waitingInput` gain one optional,
  bounded, adapter-redacted line — the same contract `ToolRef.invocation`
  already meets, produced by the same `ToolInvocation` machinery and capped the
  same way.
- `ToolInvocation` gains a rule for `AskUserQuestion`, reading the question out
  of `tool_input`. Today it returns `nil` for that tool by name, and that rule is
  precisely what changes.
- It stays a **display** line. Not a second source of truth, and nothing above
  the adapter may branch on it.

**Do not fill it from Claude Code's `Notification.message`**, tempting as it is —
the payload does carry one. Two reasons. It is provider boilerplate
("Claude needs your permission to use Bash") and adds nothing the `Waiting` label
does not already say. And it exists on only one of the two waiting paths: the
`Notification` route carries a message, the `PreToolUse(AskUserQuestion)` route
carries none. A line that appears on one kind of waiting and not the other reads
as a bug rather than as information.

The `AskUserQuestion` path is the one where a real, specific question exists, so
that is the only path that gets a line. The permission and elicitation paths stay
bare, correctly: there the state label already says everything there is to say.

It landed in step 06, verified against seven recorded `AskUserQuestion` payloads
— see [platform-integration.md](platform-integration.md) §1 for the shape. Step
07 therefore has both verbs available from the day it starts. Where no line is
produced, the `Question` notification is title-only and the Waiting row is state
and duration; both degrade correctly, and neither looks broken.

### Step 07 — notifications — **delivered**

Three things were fixed in [Notifications](#notifications) so they could not be
invented later, and step 07 owes all three. All three landed, each with a test
per row of the table:

1. **The verb predicates.** Each verb is a condition on the `StateChange`, and
   two reachable shapes — `from == nil` and `to == nil` — fire nothing at all.
2. **The body's source per event**, which is `failed(reason:)`, the question line,
   or nothing. The canvas's `3 files changed` has no source and never will without
   new payload plumbing through the adapter and the store; it is not worth one
   notification line.
3. **A clamp on the body.** `failureReason` passes an unrecognised provider error
   type through, and `NativeEventDecoder`'s own bound is 120 characters — a
   transport cap, not a readable line. Do not assume a short sentence arrives.

Two deviations, both recorded where they belong: the leading image is the
provider tile without the corner badge ([Notifications](#notifications)), and
`Provider.displayName` moved into `AgentBarCore` because a notification title and
a panel row both need the same fixed string and their modules may not import each
other.

Step 07 also delivered the **settings window** below, which this document had
deferred.

### Step 09 — Codex adapter — delivered

`CodexInstallState` has the explicit `installedNotTrusted(CodexTrustStatus)` case
the brief asked for, plus `disabledInCodex` — a state the spec did not
anticipate, because Codex lets a user trust a hook and then switch it off, which
is a different sentence from "not trusted" and cannot be fixed by the `Trust`
button. Both map onto `IntegrationCondition.notTrusted`; the difference reaches
the user as the row's second line, which each state supplies for itself.

The `Trust` button does not trust anything — nothing outside Codex can. It
re-reads the state and reports what it found, which is the honest reading of a
row whose action is "go and do this in another application". The card's footnote,
already specified above, is what explains the rule.

### Step 10 — Codex limits, as delivered

An ordered `[UsageWindow]` of `name: String?`, `fractionUsed: Double?`,
`resetsAt: Date?`. Count not fixed — the live account returns exactly one bucket.
Each field independently omittable, degrading by omission and never by a
placeholder zero. Step 06's section needed **no change** to receive it.

**Naming is the one thing step 10 added to this surface.** `limitName` came back
`null` from every live reading, so "the server's own name, verbatim" is a path
the real data does not take. `UsageWindow.label` fills the gap the way the
prototype did — by the window's **length**: `Weekly`, `5 hours`. In order:

| Source | Renders |
|---|---|
| `limitName` | the provider's name, verbatim |
| `windowDurationMins` | `Hourly`, `Daily`, `Weekly`, `Monthly`, else `5 hours` / `2 days` / `90 minutes` |
| `limitId` | `codex` — an identifier, and last for that reason |
| none of them | `nil`, so the row falls back to `Usage` |

A name and a length are **joined** — `Pro limit · 5 hours` — rather than one
replacing the other: a bucket that has a name *and* two windows would otherwise
draw two identical rows, and the list is keyed on position.

When there is nothing to show — no Codex, no account, an older Codex without the
account API, a refresh that failed before the first success — the Codex half is
simply absent. No header, no empty state, no error styling, and the permanent
Claude Code caveat row keeps the section whole. `PanelModel.refreshUsage()` is
new and runs on the open panel's one-second clock, so a refresh landing while the
panel is open appears without it being closed and opened again.

**Token usage has no surface, deliberately.** `account/usage/read` returns
lifetime tokens, a peak day and streaks — what an account has *spent*, not what
it has left. §4.4 of the brief scopes Limits to remaining quota, §4.5 enumerates
the settings window and does not include a stats block, and §3.3 makes "not
overloaded" an explicit product requirement. The call is implemented and tested;
nothing renders it.

### Step 11f — Codex notification reliability — delivered

Codex now observes `PermissionRequest` without answering it and recognises the
exact `request_user_input` tool inside `PreToolUse`. Their domain states become
separate Approval and Question notifications. Approval has its own settings row,
category, purple semantic accent and shield silhouette, but no action buttons;
its default sound reuses the authored Waiting file.

Urgent notifications no longer wait behind the 1.5-second Finished coalescer.
The first Question, Approval, Waiting or Failed draft is queued immediately and
only an exact repeat is suppressed during the next 1.5 seconds. Finished keeps
the existing delay.

The Codex helper is deployed from the bundle to the stable AgentBar-owned path
specified by ADR-0014. One explicit Repair migrates older DerivedData or bundle
commands; moving among app copies afterwards changes no hook definition.

### Whenever the dashboard is built

`FinishedSession.finalState` is the last state actually *observed* and is never
`unknown`, so a session the watchdog gave up on will read `Working` beside an
outcome of `lost`. Present the outcome first, or the row looks like a
contradiction. Recorded here so it is not rediscovered as a bug.

---

## Reserved space

| Deferred | What step 05 leaves for it |
|---|---|
| Dashboard window | a footer entry point; `StoreSnapshot.finished` already carries the history |
| Approve / Deny in notifications | the Approval category is registered with no actions; implementation requires a supported provider reply handle, never the hook fingerprint |

Settings was the third row here until step 07. It is now a real surface — see
[Settings window](#settings-window) — and the footer gear opens it. Caffeine
joined it in step 08 as one more section, plus the footer indicator described
under [Footer](#footer).

One more thing v2 deliberately left unbuilt, recorded so its absence is a
decision rather than an oversight. The settings sidebar was the second entry here
and is no longer: it was refused on the grounds that the window was a `Form`
rather than a split view, which was a statement about the implementation rather
than about the design, and it is built — see [The sidebar](#the-sidebar).

| Not built | Why, and what would change it |
|---|---|
| Inline row actions on a waiting row | The panel is a status surface and clicking a row already opens the session. Ship the panel, use it for a week, and see whether reaching a waiting session is slow. If it is, one `Open session` button is likely enough — see [Session row](#session-row) |

And one that is **not** deferred but refused: a `Reply` field on a notification
banner. It needs a channel from AgentBar into a running agent session, which is
impersonation under the safe-superset rule, and a text channel into a permission
prompt is a mechanism by which a dropped connection could resolve into a granted
permission. Revisit only alongside the Approve/Deny work, under whatever consent
model that establishes.
