# Design system

The committed token set for AgentBar's interface: colour, typography, spacing,
radii, material, iconography and the state-shape language, in light and dark.

This file is the **normative** record. It was extracted from the Claude Design
canvas produced against [design-brief.md](design-brief.md); the canvas and its
HTML references live outside the repository, so anything not written down here
is not available to an implementer. Step 06 builds the panel from this file and
[design-spec.md](design-spec.md) and should need no further visual decisions.

**Extracted:** 2026-08-18, step 05.

---

## Reading these numbers

The canvas is HTML, so its measurements are CSS pixels. The panel is 380 px
wide there and 380 **pt** wide in AppKit: read every length in this file as
points, one for one.

Colours were authored in OKLCH. Both forms are given — OKLCH is the source of
truth for a redraw, the sRGB hex is what an asset catalog stores. The hexes here
were computed from the OKLCH values rather than copied, and agree with the
canvas's own table to within one unit per channel.

**UI copy is English** (CLAUDE.md). The canvas was drafted in Russian; that is a
mockup artefact and carries no weight. The English strings are in
[design-spec.md](design-spec.md).

---

## Colour

### Neutrals

| Token | Light | Dark |
|---|---|---|
| `canvas` | `oklch(0.975 0.003 250)` · `#f5f7f9` | `oklch(0.19 0.006 250)` · `#121416` |
| `surface` | `#ffffff` | `oklch(0.26 0.008 250)` · `#212428` |
| `hairline` | `oklch(0.90 0.006 250)` · `#dbdee2` | white at 9 % |
| `divider` | `oklch(0.92 0.005 250)` · `#e2e5e8` | white at 8 % |
| `fillQuiet` | `oklch(0.94 0.006 250)` · `#e8ebef` | white at 10 % |
| `ringQuiet` | `oklch(0.85 0.006 250)` · `#cbced2` | white at 16 % |
| `ink900` — primary text | `oklch(0.20 0.012 250)` · `#12171b` | `oklch(0.96 0.004 250)` · `#f0f2f4` |
| `ink600` — secondary text | `oklch(0.46 0.01 250)` · `#54595e` | `oklch(0.78 0.006 250)` · `#b4b8bb` |
| `ink400` — tertiary, meta | `oklch(0.63 0.01 250)` · `#858a8f` | `oklch(0.56 0.008 250)` · `#717579` |

`hairline` bounds the panel; `divider` separates sections inside it; `fillQuiet`
fills a secondary button, an untinted chip or a hovered row; `ringQuiet` strokes
a decorative outline heavy enough to be seen but too quiet to be read as content
— the empty state's concentric rings, and the dashed placeholders where the
reserved notification buttons will go. They are four tokens rather than one
because the panel puts them next to each other and the differences would
otherwise collapse.

`ringQuiet` light and `providerCodex` dark are the same hex. That is a
coincidence of value, not of role; do not merge them.

### State accents

Never used alone — see [state-shape language](#state-shape-language).

| State | Light | Dark |
|---|---|---|
| `stateWorking` | `oklch(0.58 0.13 255)` · `#407cc5` | `oklch(0.72 0.13 255)` · `#6aa7f4` |
| `stateWaiting` | `oklch(0.72 0.15 75)` · `#da950b` | `oklch(0.78 0.14 78)` · `#e8ab3e` |
| `stateFailed` | `oklch(0.58 0.18 25)` · `#cf4040` | `oklch(0.68 0.17 25)` · `#ef6661` |
| `stateUnknown` | `oklch(0.58 0.10 310)` · `#8c69a7` | `oklch(0.70 0.10 310)` · `#b18dcd` |
| `stateIdle` | `ink400` | `ink400` |

Idle has no accent of its own on purpose: it is the resting state and must not
draw the eye.

`stateWorking` light and `stateUnknown` dark each sit on a rounding boundary:
converting their OKLCH gives `#407bc5` and `#b28dcd`, one unit away. The values
in the table are the ones [assets/logo-mark.svg](assets/logo-mark.svg) already
ships, so they win — a mark and a state dot that are meant to be the same blue
must be the same blue.

| Token | Light | Dark | Use |
|---|---|---|---|
| `onAccent` | `#ffffff` | `oklch(0.16 0.01 250)` · `#0a0e11` | any glyph or label sitting on a filled accent or provider tile |

`onAccent` is a single rule, not a per-colour decision: in light every filled
tile takes a white glyph, in dark every filled tile takes near-black. It applies
to the provider badges and to a filled button's label alike.

### Row tint

A `waiting`, `failed` or `unknown` row takes its accent as a full-row
background wash. Not a coloured left border — that reads as a generic alert
strip and is louder than the panel wants to be.

| State | Light | Dark |
|---|---|---|
| Waiting | accent at 10 % | accent at 16 % |
| Failed | accent at 7 % | accent at 14 % |
| Unknown | accent at 8 % | accent at 12 % |

A `working` or `idle` row has no tint.

The dark unknown value is the one figure here that was designed rather than
extracted: the canvas never draws an unknown row in dark. 12 % keeps it in the
same relationship to its light value as the other two.

### Provider identity

Must be distinguishable without reading text.

| Provider | Token | Light | Dark | Glyph |
|---|---|---|---|---|
| Claude Code | `providerClaudeCode` | `oklch(0.62 0.12 45)` · `#c16d45` | `oklch(0.72 0.12 48)` · `#e18c5f` | four-point sparkle |
| Codex | `providerCodex` | `oklch(0.30 0.012 250)` · `#292e34` | `oklch(0.85 0.006 250)` · `#cbced2` | `</>` bracket |

Codex inverts between themes — graphite on light, near-white on dark — which is
itself a distinguishing signal against Claude Code's constant warm terracotta.

The glyph's own colour is `onAccent` — white in light, `#0a0e11` in dark — on
both badges. There is no per-provider exception.

> **Trademark.** These are original generic marks. Do not substitute Anthropic's
> or OpenAI's actual logos — they are registered brand assets and AgentBar has no
> licence to them.

### Supporting

| Token | Light | Dark | Use |
|---|---|---|---|
| `connected` | `oklch(0.60 0.13 150)` · `#3b9555` | `oklch(0.72 0.15 150)` · `#53be70` | the footer's install-status indicator when everything is healthy |
| `meterTrack` | `hairline` | white at 10 % | the Codex usage bar's groove |
| `meterFill` | `oklch(0.30 0.012 250)` · `#292e34` | `oklch(0.85 0.006 250)` · `#cbced2` | the Codex usage bar's fill |
| `hoverOverlay` | `ink900` at 6 % | white at 8 % | a hovered row |
| `focusRing` | `NSColor.controlAccentColor` | same | the keyboard focus ring |

`meterFill` is deliberately neutral graphite, not an accent. A quota bar is
information, not a warning, and colouring it would compete with the state accents
for the same attention.

`hoverOverlay` is **translucent, and composited over whatever is beneath**. It
must not be `fillQuiet`, which is opaque in light: painting an opaque neutral
over a failed row at 7 % would erase the wash that says the row failed, and would
punch a hole through the glass besides.

`focusRing` is the only colour here that is not ours. It is the macOS system
accent — the user's own choice, the native focus convention, and understood as
chrome rather than as state. The alternative, `stateWorking`, is *the same blue*
as the Working dot, so a focused Waiting row would wear a Working-coloured ring:
the exact ambiguity the focus rule exists to prevent, merely relocated.

### Chip ink

Text colour for a state chip on its own tinted pill. The MVP panel does not use
chips — the settings screen will — but the values were authored with the rest and
are recorded so they are not re-invented.

| Chip | Light ink | Tint |
|---|---|---|
| Working | `oklch(0.42 0.10 255)` · `#234e82` | `stateWorking` at 10 % |
| Waiting | `oklch(0.46 0.13 60)` · `#8a4100` | `stateWaiting` at 16 % |
| Failed | `oklch(0.50 0.16 25)` · `#ac3031` | `stateFailed` at 10 % |
| Unknown | `oklch(0.42 0.09 310)` · `#5c3e71` | `stateUnknown` at 12 % |
| Idle | `ink600` | `fillQuiet` |

The waiting ink is outside the sRGB gamut and clips to `#8a4100`. Store the hex,
not the OKLCH, or Core Graphics will clip it differently.

**Dark chip inks do not exist yet.** The canvas draws every control — chips,
buttons, toggle, segmented control, search field — in light only. Their dark
variants have to be designed rather than transcribed, and that belongs to
whichever step first needs them.

---

## State-shape language

The accessibility backbone. Colour is never the only carrier of state: every
accent is paired with a distinct silhouette *and* a text label, so the design
survives colour blindness and the monochrome menu-bar glyph.

| State | Shape | Why |
|---|---|---|
| Working | filled circle | calm, present, no badge |
| Waiting | filled triangle (menu bar: filled apex **with a pulse ring**) | unmissable |
| Failed | filled rounded square | a different silhouette from waiting even in mono |
| Unknown | dashed ring | deliberately not solid — must never read as working |
| Idle | hollow ring | near-invisible |

Reuse these shapes everywhere a state appears: session row, status item,
notification, and any future settings surface.

> **One divergence, deliberate and documented rather than hidden.** The v2
> menu-bar glyph draws Waiting as a filled apex with a ring leaving it, and the
> row and footer keep the up-triangle. At 6–8 pt a ring around a disc is mud;
> the triangle is the most legible small silhouette in the set and always
> carries a text label beside it. The two alternatives are worse: a filled disc
> would make Waiting and Working the same shape at row size, distinguished by
> colour alone, which breaks the rule this section exists for; and a triangle at
> the glyph's apex is a triangle inside a triangle of nodes at 18 pt. Failed,
> Unknown, Idle and Working still match the glyph exactly. Recorded in
> `StateShapeView`'s own comment as well as here.

Sizes in the session row: circle 6 pt diameter; triangle 8 pt base × 6 pt tall;
rounded square 7 pt with 2 pt corners; rings 7 pt across on a 1.4 pt stroke,
dashed for unknown.

---

## Typography

System font throughout — SF Pro via `.system(...)`, no bundled font. Monospace is
SF Mono via `.system(..., design: .monospaced)`.

| Token | Size / weight | Use |
|---|---|---|
| Panel title | 17 / semibold (650) | rare; the panel has almost no chrome |
| Row title | 13 / medium (590) | project name, session state label |
| Body | 13 / regular | ordinary interface text |
| Section label | 11 / semibold, uppercase, +0.06 em | group headers such as "Limits" |
| Caption | 11 / regular | durations, counts, meta |
| Mono | 12 / regular, SF Mono | commands, paths, error text |

**Minimum interactive text size is 11 pt.** Nothing goes below it.

### Role mapping, and the one deviation from the canvas

The canvas renders the panel one step tighter than its own type scale: 12 pt row
titles, 11 pt monospace, 10.5 pt meta — about a third of the panel below the
11 pt floor the very same document declares. The scale wins, for two reasons
beyond the contradiction: 13 and 11 are AppKit's own `controlContentFontSize` and
`smallSystemFontSize`, so the panel matches every system menu and control it sits
beside, while 12 and 10.5 sit between them; and the floor is an accessibility
rule, not a measurement.

The hierarchy is unchanged and the panel is a few points taller — roughly 51 pt
per two-line row against the canvas's 47, so about one row fewer before the
340 pt scroll cap bites. Confirmed with the product owner, 2026-08-18.

| Surface element | Token |
|---|---|
| Project group name | Row title |
| Group session count | Caption, `ink400` |
| Session state label | Row title |
| Subagent pill `+2` | Caption, `ink400` on `fillQuiet` |
| Session detail line — tool or error text | Mono, `ink400` |
| Session detail line — prose | Caption, `ink400` |
| Duration | Caption, `ink400`, tabular figures |
| "Limits" header | Section label |
| Limits bucket name | Caption, medium |
| Limits bucket meta | Caption, `ink400` |
| Footer install status | Caption, `ink400` |
| Empty-state title | Row title |
| Empty-state subtitle | Caption, `ink400` |
| Onboarding card title | Row title |
| Onboarding row title | Row title |
| Onboarding row status | Caption |
| Button label | Body, medium (560) |

Durations and percentages use tabular figures (`.monospacedDigit`) so a live row
does not jitter as the number changes.

---

## Spacing and radii

Spacing scale, in points:

```
4 · 8 · 12 · 16 · 20 · 24 · 32 · 40
```

The scale governs new layout. The panel itself was drawn to measured values that
are mostly off it — 9 pt row padding, 3 pt line gaps, 6 pt shape gaps — and
those measurements are normative for the panel, because they are what was
designed and reviewed. They are recorded per surface in
[design-spec.md](design-spec.md). Do not "correct" them onto the scale.

Radii:

| Element | Radius |
|---|---|
| Chip, state pill | fully rounded |
| Icon button (22 pt) | 6 |
| Button | 8; 7 for the compact in-panel buttons |
| Row | 10 |
| Card | 12 |
| Panel | 18 |

A provider badge's radius scales with its tile at roughly 27 %: 6 at 22 pt, 7 at
26 pt, 8 at 28 pt, 10 at 38 pt. A single fixed radius looks wrong at both ends
of that range.

---

## Material

The panel is tinted translucent glass.

- `.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))`, or an
  `NSVisualEffectView` with `material: .popover`, `blendingMode: .behindWindow`
  where more control is needed.
- What the canvas actually painted, for reference and for the flat fallback: a
  vertical gradient from white 85 % to white 72 % in light, and from
  `rgb(50 50 56)` 82 % to `rgb(26 26 32)` 88 % in dark. The light one grows
  *more* transparent downward and the dark one *less* — nobody would guess that
  from the material name, and it is what gives the panel its weight at the
  bottom edge.
- Hairline border, 1 pt: white at 60 % in light, white at 12 % in dark.
- Inner top highlight, 1 pt of white at 60 % (light) / 8 % (dark). Optional
  polish; drop it before fighting it.
- Shadow: `0 20 50` at black 18 % in light, black 55 % in dark. The popover's own
  shadow may make this redundant — do not stack two.

### Accessibility settings

All three are read from `NSWorkspace.shared` and must be honoured **live**, not
only at launch — a user turning one on with the panel open should see it take
effect. Observe `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`,
and note that it is posted on **`NSWorkspace.shared.notificationCenter`**, not the
default centre. Registering on the wrong one fails silently, which is the worst
way for an accessibility setting to fail: verify the observer actually fires by
toggling the setting, not by reading the code.

| System Settings | Property | Behaviour |
|---|---|---|
| **Reduce Transparency** | `accessibilityDisplayShouldReduceTransparency` | replace the material with a flat `surface` fill at the same radius. Never lose the panel or its contrast. |
| **Increase Contrast** | `accessibilityDisplayShouldIncreaseContrast` | thicken the hairline and promote secondary text `ink600` → `ink900`. Do not add heavier shadows. |
| **Reduce Motion** | `accessibilityDisplayShouldReduceMotion` | no row insert or remove animation; cross-fade instead of slide. |

Two more, outside the three the brief names, that this design has to survive
because a menu-bar panel is small type on glass:

- **Increase Contrast also drops the row tints' legibility.** Raise each wash by
  roughly half again rather than removing it — the tint is half of how a waiting
  row is recognised. Light: waiting 16 %, failed 12 %, unknown 12 %. Dark: waiting
  24 %, failed 20 %, unknown 18 %.
- **Larger text.** Nothing here uses Dynamic Type, and AppKit does not offer it
  for a status-item panel, so the type scale is fixed. That is a known limit, not
  an oversight; the panel's own minimum is 11 pt for exactly this reason.

---

## Iconography

### Provider badge

26 × 26 pt, radius 7, filled with the provider colour, glyph centred at 14 pt.
Claude Code is a four-point sparkle inscribed in 54 % of the badge. Codex is a
literal `</>` in SF Mono, 12 pt bold, −1 pt tracking.

> **Corrected in step 06.** This paragraph used to describe the sparkle as "two
> rounded bars crossed at 45°, 3 pt thick with 1.5 pt caps", and two rectangular
> bars at 45° draw an **✕** — which on a filled terracotta tile reads as *error*
> or *close*, the opposite of what a provider badge means. Seen only by rendering
> it at 26 pt. It is now a concave four-point star in the same 54 % box: four
> points, quadratic sides, waist pulled to 28 % of the radius.

In the dense list variant the badge is 22 × 22 pt at radius 6; in a notification
attachment it is 38 × 38 pt at radius 10.

### Folder glyph

The project group header's mark: 11 × 9 pt, 1.3 pt stroke in `ink400`, corner
radii `1 / 3 / 2 / 2` clockwise from top-left — a folder tab suggested rather
than drawn.

### Status-item glyph

**Revised in v2, and the revision reverses the old rule.** The glyph used to be
a separate asset, designed standalone and deliberately *not* derived from the app
mark. It was a filled 12 pt disc with a badge punched out: clean, and invisible —
at 18 pt among a dozen system items a plain disc has no identity, reads as a
generic indicator, and tells a first-time user nothing about what the app is.

It is now **the same three-node figure as the app mark**, reduced to two base
nodes, an apex and hairline links. The silhouette is not confusable with Wi-Fi,
battery, Bluetooth or Control Center, it reads as "several things, connected",
and the menu bar, the notification art and the app icon finally agree about what
AgentBar looks like. The apex is the **state node**: the only element that
changes, so the eye has a fixed frame of reference and one moving part.

Geometry is in [design-spec.md](design-spec.md#status-item) and, normatively, in
`GlyphFigure` — which is where every renderer reads it from. There are three:
an AppKit template image for the status item, a SwiftUI canvas for the panel
header and the onboarding, and a gradient square for the notification
attachment. They share the numbers rather than each holding a copy, because
drift between them would be invisible until somebody put the surfaces side by
side.

### App icon and logo

Source art is committed:

- [assets/logo-mark.svg](assets/logo-mark.svg) — the mark alone, for docs and README
- [assets/app-icon-dark.svg](assets/app-icon-dark.svg) — the full dark tile

The mark is three agent nodes: two calm at the base, one at the apex inside a
pulse ring — the one that needs attention. On a 200 × 180 viewBox: base nodes at
(55, 130) and (145, 130) radius 17; apex at (100, 55) radius 21 in
`stateWorking` light `#407cc5`; pulse ring at (100, 55) radius 30, 3 pt stroke,
35–50 % opacity; edges 9 pt with round caps. Mirror-symmetric about x = 100 —
keep it that way in any redraw.

The tile is a squircle with corner radius 23 % of its width, a `#22272c` →
`#05080b` gradient running top-left to bottom-right (the committed SVG's
`15 %,0 % → 85 %,100 %` on a square box, about 145° — the canvas's prose says
155°; the SVG is what ships), and an 8 % white sheen over the top 45 %. Every
stroke and node is white at 95 % except the apex, `#407cc5`, and its ring,
`#6aa7f4` at 50 % — the only colour in the tile. The mark's edges are `#1b2025`
in the light-background variant.

Those three values are the committed SVGs', which is what settles them: the
canvas offered a different blue for the ring and a different stroke for the
edges, and a mark has to have one answer.

Build the shipping icon in **Icon Composer** (macOS 26's layered `.icon` format)
from this SVG, not as a flat PNG, so the system applies its own depth treatment.
Step 12 owns that.

---

## Motion

Animation exists to communicate three things and nothing else:

1. **a state changed** — the transition between glyph states,
2. **where something came from** — the panel and the onboarding drop from the top,
3. **that a process is alive** — the working hairline, the waiting pulse.

Anything that does not do one of those is decoration and does not ship. Five
prohibitions, because each one is a thing that gets reached for:

- **No rotating spinner.** A spinner claims a duration the app does not know.
  The indeterminate sweep claims only "alive", which is true.
- **No bouncing Dock icon.** `LSUIElement`; there is no Dock tile.
- **No flashing faster than 2 Hz.** An accessibility hazard, and it reads as an
  error even when it is not.
- **Nothing decorative longer than 400 ms.**
- **Nothing animating while its surface is closed.** Timers sleep with the panel.

Every duration and curve lives in `DesignTokens.Motion`; no view spells either.

| Token | Duration | Where |
|---|---|---|
| `drop` | 600 ms | a surface arriving from the top |
| `rise` | 400 ms | a step change, a result line |
| `stateInto` / `stateBack` | 280 / 320 ms | a glyph state gaining or losing fill |
| `micro` | 180 ms | button feedback, the collapse into Failed |
| `crossFade` | 150 ms | the Reduce Motion substitute for all of the above |
| `waitingPulse` | 2200 ms | the menu-bar ring |
| `workingChase` | 1500 ms | the menu-bar nodes — computed, and **off** |
| `hairlineSweep` | 2400 ms | the working row's progress hairline |
| `meterSweep` | 3400 ms | the limits meters |
| `dashCrawl` | 4000 ms | the unknown state's dashed links |
| `breathe` | 3000 ms | the `allQuiet` rings, the onboarding pointer |

`crossFade` is deliberately the same 150 ms as
`AccessibilityPreferences.rowAnimation`, so a cross-fade is one duration in the
app rather than two that nearly agree.

**Two curves for two kinds of loop, and picking the wrong one is visible.**
`cycle` (ease-in-out) is for a loop that **returns** — a pulse, a breathe, a
glow — and is always paired with `autoreverses: true`, so the value comes back
the way it went and the loop point is not a seam. `traverse` (linear) is for a
loop that **wraps**: the working hairline leaves one edge and re-enters from the
other, and a wrapping loop restarts at its beginning rather than reversing.
Ease-in-out puts the slowest part of the motion on both sides of that restart and
the fastest in the middle, so the sweep crawls out of the left edge, races
across, crawls to a halt at the right and reappears — a stutter, not a loop.
Constant velocity is the only thing with no seam, and the travel has to start and
end **off** the track, or the element pops into existence wherever the cycle
begins. Both halves were wrong in the first build of the hairline and both had to
change; `MotionTokenTests` pins the curve by its property — `value(at: t) == t` —
rather than by its name.

**Two rules that are easy to lose.** Every cyclical indicator owes a *static*
appearance that carries the same fact its motion does — a working row under
Reduce Motion still has to look different from an idle one, which is why the
hairline becomes a 40 % fill at the left rather than disappearing or freezing
mid-sweep. And **no animation is load-bearing**: Reduce Motion, a sleeping
timer, an offscreen render and a profiler run all produce the static frame, so
anything only visible once an animation has run is a thing that is sometimes
missing.

Reduce Motion is read through `AccessibilityPreferences` — `entranceAnimation`,
`stepAnimation`, `runsCyclicalMotion` and `stagger(_:)` — and never by a view
directly, so no surface has to remember the rule.

The status item runs **one** timer, at 8 fps, only while the aggregate state has
something to animate, and never at all under Reduce Motion. 8 fps is enough for a
2.2 s ease and halves the wake-ups against 12.

## Elevation

Four levels, expressed as **fill and hairline, never as a blur radius**.

| Level | Meaning | Treatment | Used by |
|---|---|---|---|
| 0 | Flat | no fill change; hairline dividers only | list rows, dividers |
| 1 | Card | `surface` on `canvas`, 1 pt `hairline`, radius `card` | settings sections, the integration card |
| 2 | Above content | `surface`, hairline, radius `panel`. **System shadow only** | a popover inside a window, a sheet |
| 3 | Above the window | the material, radius `panel`. **System shadow only** | the menu-bar panel, the onboarding, a banner |

Levels 2 and 3 are surfaces macOS already shadows. Drawing a second shadow under
one of them is the mistake the Material section warns about, and it is what a
mock inevitably shows, because a browser has no window server to do it for free.

Gradients follow the same discipline. v2 uses one in exactly three places — the
panel's waiting wash, the notification attachment art, and the working
hairline's sweep. Everywhere else, a flat token. **A gradient that does not
carry state is decoration.**

## How this reaches the code

Step 06 landed the tokens as:

- a `ColorToken` enum in `AgentBarUI` holding all twenty colours by the names in
  the tables above, each a dynamic `NSColor` with a light and a dark value;
- a `DesignTokens` enum exposing spacing, radii and the type roles, so no view
  carries a bare number.

> **Not an asset catalog, which is what this document originally asked for.**
> SwiftPM copies an `.xcassets` into a resource bundle **without running
> `actool`**, so `NSColor(named:bundle:)` finds nothing under `swift test` and
> the tokens would resolve only in an Xcode build. ADR-0003 puts the logic in SPM
> modules precisely so the suite runs without Xcode. Established by building it
> both ways in step 06. Everything the catalog was for survives: one place per
> token, two values each, and a test that walks every case.

The alpha-based dark values (`hairline`, `divider`, `fillQuiet`, `ringQuiet`,
`meterTrack`) are white at a stated percentage rather than a fixed hex on
purpose: they sit on glass, whose backdrop is whatever is behind the panel, and a
solid neutral would band against it. Store them as white with the alpha, not as
the colour they happen to resolve to over any particular background.

v2 adds **no base token**. The notification attachment art needs a gradient per
event, and those eight stops are *derived* — each is an existing token's light
value moved ±12 % in OKLCH lightness, hue and chroma untouched, so an event
square and the row tint for the state it announces are visibly the same colour.
They live in `AttachmentRamp` beside `ColorToken`, with the rule that generated
them in the comment, so they can be regenerated when a base token moves.

Two rules for anyone extending this:

1. **A colour used in a view must be a token.** If a view needs a colour that is
   not here, the token set is what changes, not the view.
2. **Colour never carries state alone.** A new state needs a shape and a label
   before it needs a hue.
