# AgentBar — Design Brief

Written for a designer with no knowledge of the internals. Everything here is
something the app can actually represent; nothing has been aspirationally added.

---

## 1. What this is

A macOS **menu-bar** app. No Dock icon, no main window. The entire product is a
status-bar icon and the panel that opens from it.

Its user runs AI coding agents — **Claude Code** and **OpenAI Codex** — in several
projects at once, mostly inside VSCode. Those agents work autonomously for minutes
at a time and then stop, needing a human: a question to answer, a permission to
grant, or a finished result to review.

**The problem:** without an external signal, those pauses are invisible. The user
keeps switching windows to check whether anything is waiting. That switching is
the cost the product removes.

**The product in one sentence:** know instantly when an agent needs you, and see
at a glance what every agent is doing.

## 2. Who it is for

One developer, several projects, both tools running simultaneously. Technical,
works with a dense screen, keeps many windows open. Values a glanceable signal
over a rich interface, and will keep the panel open during work only if it is
calm enough to ignore.

## 3. Design principles

1. **Answer one question instantly:** *does anything need me right now?* The
   status-bar icon alone should answer it, before the panel is opened.
2. **Calm by default, loud when needed.** A working agent should be visually
   quiet. A waiting agent should be impossible to miss.
3. **Not overloaded.** This is an explicit requirement from the product owner.
   Every element must earn its place.
4. **Honest about what is unknown.** Some data genuinely cannot be obtained. The
   design must show absence gracefully rather than faking completeness.
5. **Native.** It should feel like part of macOS, not a web app in a panel.

---

## 4. Screens to design

### 4.1 Status-bar icon — the most important element

A single small monochrome glyph in a crowded menu bar. It must communicate
overall state at a glance and stay legible at menu-bar size in light and dark.

States, in priority order — the icon shows the most urgent state present:

| State | Meaning |
|---|---|
| **Waiting** | At least one agent needs the user *now*. Must be unmissable. |
| **Failed** | An agent's turn ended in an error. |
| **Working** | At least one agent is running. Calm, present, not attention-seeking. |
| **Unknown** | An agent stopped reporting — state genuinely uncertain. Must not look like "working". |
| **Idle** | Nothing running. Nearly invisible. |

Consider whether a count belongs on the icon (for example, how many are waiting).
Note that macOS menu-bar space is scarce and often contested.

### 4.2 The panel — the main surface

Opens from the status item. Not a menu: a live list that updates while open, with
a custom width. It must not steal keyboard focus from the editor.

**Structure**

- **Sessions, grouped by project.** A project is a working directory — show its
  folder name, not the full path. Several sessions in one project is normal and
  common; group them, but keep them distinct.
- **Limits section** — see §4.4.
- **Footer** — settings, install status, quit.

**A session row must carry**

| Element | Notes |
|---|---|
| Provider | Claude Code or Codex, distinguishable **without reading text** |
| State | working · waiting for input · finished · failed · unknown |
| Current tool | e.g. running a command, editing a file. Only while working. |
| Duration | how long in the current state |
| Subagent count | only when greater than zero; agents spawn parallel helpers |

**Row actions:** open the project in the IDE. Keep it to one primary action.

**States to design explicitly**

- Empty — nothing is running at all. This is the common resting state, and it
  should feel calm rather than broken.
- Many sessions — five projects, a dozen sessions. Does it still scan? Does it
  scroll sensibly?
- A session that has gone `unknown`.
- Not yet installed — hooks are not configured, so nothing will ever appear.

### 4.3 Notifications

Standard macOS notifications. The design decides content and hierarchy, not
chrome.

Each must answer three questions, in this order of importance:

1. **What needs me?** — finished · asked a question · waiting for input · failed
2. **Which agent?** — Claude Code or Codex
3. **Where?** — which project

Plus one line of relevant detail where it exists: the question asked, the tool
being run, the error reason.

Design a layout per event type. Note that the notification is not elastic — the
system truncates, so the first few words carry the meaning.

### 4.4 Limits

The two providers are genuinely asymmetric and the design must not paper over it.

**Codex** — real data is available. Render the usage windows the API returns.

Critical constraint: **the number of windows is not fixed.** It may be one, two,
or more. Their names, durations and reset times all come from the server. A live
sample returned exactly one bucket, a weekly window at 72% used. The design must
be a repeating component, not a fixed two-slot layout. Any field may be missing.

**Claude Code** — there is **no legal way** to obtain remaining quota. This is a
firm project boundary, not a temporary gap.

Design how to say that gracefully. It must not look like an error, must not look
like zero, and must not use a progress bar we cannot fill. A short explanation
should be reachable. Whether this section is visible by default is an open
question worth a recommendation from the design.

### 4.5 Settings

Kept simple; the product owner explicitly does not want a heavy app.

- **Sound matrix** — the notable one. Sound is configurable per **provider ×
  event type**, and the user may supply their own file. That is a two-dimensional
  grid roughly 2 × 5. Design something that stays comprehensible and is pleasant
  to audition. Include the state where a chosen file is invalid — too long, wrong
  format, missing.
- Per-event notification on/off.
- Quiet hours; suppress while the editor is focused.
- Launch at login.
- Caffeine on/off, with its honest caveat (see §5).

### 4.6 Onboarding and install status

The app works by installing small hooks into each tool's configuration. Two things
make this a real design problem rather than a formality:

1. **Codex requires the user to explicitly trust the hook** before it will run.
   Writing the config is not enough. Without this step the user gets an app that
   silently shows nothing.
2. Either integration can be installed, not installed, or installed-but-broken.

Design a status surface that makes "why is nothing appearing?" answerable in one
look, and an onboarding flow that gets a first-time user through both
installations including the Codex trust step.

---

## 5. Honest limitations to surface

Real constraints the interface must communicate rather than hide:

- Claude Code remaining quota is unavailable, permanently and by design.
- Keeping the Mac awake does **not** survive closing the lid, and macOS will
  sleep on low battery regardless.
- A session can become `unknown` — the app genuinely does not know its state.
- A Codex hook can be installed but untrusted, and therefore inert.

## 6. Deliberately out of scope

- A full dashboard window. It is planned, so **leave room for an entry point**,
  but do not design it.
- Approve/Deny buttons inside notifications. Planned later; the notification
  layouts should tolerate two action buttons being added.
- Any settings beyond §4.5. Restraint is a requirement.

## 7. Technical constraints

- macOS 26+, SwiftUI with AppKit where needed. Native components preferred.
- Light and dark are both first-class.
- Respect Reduce Motion, Increase Contrast and Reduce Transparency.
- The panel must be usable by keyboard and legible to VoiceOver.
- Colour alone must never carry state — the user may be colour-blind and the
  status icon is monochrome by convention.

## 8. Vocabulary

Use these exact words in the interface, so design and code stay aligned.

| Term | Meaning |
|---|---|
| **Provider** | Claude Code or Codex |
| **Session** | One agent conversation in one project |
| **Project** | The working directory an agent runs in |
| **Subagent** | A parallel helper agent spawned by a session |
| **Working** | Actively running |
| **Waiting** | Stopped, needs the user |
| **Idle** | Finished its turn, nothing pending |
| **Failed** | The turn ended in an error |
| **Unknown** | Stopped reporting; state uncertain |
