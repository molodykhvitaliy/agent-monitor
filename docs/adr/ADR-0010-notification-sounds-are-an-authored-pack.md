---
id: ADR-0010
title: The notification sounds are an authored pack, not synthesis the repository owns
status: accepted
date: 2026-08-19
supersedes: null
superseded_by: null
tags: [notifications, sound, assets, provenance]
---

## Context

[ADR-0006](ADR-0006-notification-sounds-are-files-agentbar-can-resolve.md)
settled where a notification sound may live and how a broken one is reported. It
also recorded, as a **neutral consequence**, how the four bundled sounds were
made:

> The four authored sounds are machine-generated additive synthesis.
> `scripts/make-sounds.py` is committed so a voice can be changed by editing four
> lines and re-running it, rather than by finding whoever made the file.

Step 11 replaced them. The project owner supplied a designed set — one voice,
one register, an interval per verb, 48 kHz / 24-bit / mono, levelled as a set —
and the synthesised tones went. That sentence in ADR-0006 is now false, and the
generator it names had become the most dangerous file in the repository: run it
once, as its own docstring instructed, and the designed pack is gone, with the
only evidence four changed binaries and no test that would notice.

So the question is not whether to take the new sounds. It is what the repository
now owns, and what it can no longer promise.

## Decision drivers

- ADR-0006's principle stands: **an asset nobody can regenerate is an asset
  nobody can adjust.** A committed binary with no story is how a project ends up
  unable to change its own notification sound.
- Nothing may silently destroy a shipped asset. A committed script whose
  documented use overwrites the product is a defect regardless of intent.
- The repository has no scientific-Python dependency and should not grow one.
  `scripts/` today is stdlib Python and shell.
- Provenance matters for anything that ships in the bundle. ADR-0006 rejected
  shipping Apple's own sounds partly on redistribution grounds; a new audio asset
  cannot arrive with less of an answer than the one that was refused.

## Considered options

**1. Keep the generator, ship the pack.** One line of effort, and the state the
step actually left behind for a while. Rejected: the generator and the asset
disagree, and the generator wins the moment anyone runs it.

**2. Delete the generator.** Honest about what changed, and removes the hazard.
Rejected as incomplete: it leaves four binaries with the conversion that produced
them recorded only in prose, and prose is not runnable.

**3. Commit the pack's own renderer.** Keeps ADR-0006's principle exactly. The
renderer is deterministic and parameterised, so this is the ideal on paper.
Rejected in practice: it needs numpy and scipy, hardcodes an output path outside
the repository, and renders three sets AgentBar does not ship — night variants
and per-project transpositions that have no event in the domain model. It would
add a scientific-Python toolchain to a repository whose regeneration story is
otherwise `afconvert` and the standard library.

**4. Commit the WAV sources beside the AIFFs.** Rejected as redundant: the
conversion is lossless and reversible, so the two files carry identical audio.
Committing both to satisfy "regenerable" would double the bytes to store the same
samples twice.

## Decision

**Option 3's principle, option 2's honesty, and neither's cost.**

- The four `.aiff` files in `Apps/AgentBar/Sounds` are the **authored asset**,
  not a build artefact. WAV → AIFF at the same rate and depth is a byte-order and
  container change and nothing else, so no information the author produced is
  missing from what is committed.
- `scripts/make-sounds.py` **no longer synthesises**. It converts the four
  authored WAVs into the four bundled AIFFs, refuses to write anything if a
  source is missing rather than installing a partial set, and **verifies every
  sample against the source after the byte swap** — so it reproduces the
  committed files byte for byte rather than producing new ones.
- The pack's own renderer is not committed. It belongs to the author, needs
  numpy and scipy, and produces material the product has no home for.
- The encoding is `BEI24@48000`, chosen because it is what the pack is authored
  in and what `/System/Library/Sounds/Glass.aiff` is encoded as — the format
  macOS ships its own notification sounds in.
- File **names** are unchanged, deliberately. A stored selection names a file;
  changing the extension would leave every saved matrix cell resolving to nothing
  and playing the system default with no diagnostic, which is the exact failure
  ADR-0006 exists to make impossible.

**Provenance.** The pack is original synthesised audio — oscillators, filters
and a seeded noise source, no sampled or third-party material — rendered by the
project owner and supplied for this project. There is no third-party licence
attached to it and none is required.

## Consequences

**Good.** The hazard is gone: the committed script now produces the committed
audio, and running it is a no-op that proves it. The pipeline is executable
rather than described, and the encoding decision has one home.

**Good.** The sounds are a designed set rather than four separately plausible
tones. Their spectral behaviour is stated in
[design-spec.md](../dev/design-spec.md) § *The sound set*.

**Bad, and the real cost of this decision.** *Changing a voice* is no longer four
lines of committed Python. It needs the author's renderer, which is not here.
ADR-0006's regenerability promise is therefore **narrowed**: the repository can
reproduce the shipped files exactly, and can no longer alter them. A future step
that wants to tune a voice from inside the repository has to revisit option 3
and accept the dependency.

**Neutral.** The pack's recommended per-event gain offsets are not applied and
cannot be. `UNNotificationSound` takes a file name and no volume, and applying an
offset only in the settings window's preview would make the audition stop
matching the notification — which is the one thing the play button exists to
prove.

**Neutral.** Two of the pack's core sounds — an acknowledgement blip and an
all-agents-idle chord — are not installed. Neither has an event in the domain
model: acknowledgement belongs to the deferred Approve/Deny work, and nothing
notifies when the last agent stops. They arrive with the events, not before.

## References

- [ADR-0006](ADR-0006-notification-sounds-are-files-agentbar-can-resolve.md) —
  where a sound may live, and why every selection must be one AgentBar can
  `stat`. Its "machine-generated additive synthesis" consequence is superseded by
  this record.
- [design-spec.md](../dev/design-spec.md) § *The sound set* — the four voices,
  their intervals, and what the set is levelled to.
- `scripts/make-sounds.py` — the conversion, and the only place the encoding is
  written down as something that runs.
