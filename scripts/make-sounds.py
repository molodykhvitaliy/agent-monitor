#!/usr/bin/env python3
"""Synthesise AgentBar's four notification sounds.

Committed rather than only its output, for the same reason the render proof is
committed: an asset nobody can regenerate is an asset nobody can adjust. Run it
after changing a voice below, and commit the .aiff files it writes.

    scripts/make-sounds.py

Each sound is additive synthesis — a fundamental with a few decaying partials
and an exponential envelope, which is what a struck metal bar does. Short on
purpose: a notification sound competes with whatever the user is listening to,
and the whole of AgentBar's opinion fits in half a second.

Written as 16-bit 44.1 kHz mono Linear PCM, then converted to AIFF with
afconvert so the files match the encoding UNNotificationSound documents and the
format /System/Library/Sounds already uses.
"""

from __future__ import annotations

import math
import shutil
import struct
import subprocess
import sys
import tempfile
import wave
from dataclasses import dataclass, field
from pathlib import Path

SAMPLE_RATE = 44_100
#: Headroom below full scale. A notification that clips is a notification the
#: user turns off.
PEAK = 0.55
#: Attack ramp. Anything shorter clicks; anything longer loses the strike.
ATTACK = 0.004
#: Fade applied to the tail of the whole file, so it cannot end on a step.
RELEASE = 0.02

DESTINATION = Path(__file__).resolve().parent.parent / "Apps" / "AgentBar" / "Sounds"


@dataclass(frozen=True)
class Note:
    """One struck tone inside a sound."""

    #: Seconds from the start of the file.
    at: float
    #: Fundamental, in hertz.
    frequency: float
    #: Exponential decay constant, in seconds.
    decay: float
    #: Relative loudness against the loudest note in the same sound.
    gain: float = 1.0
    #: Partial ratios and their amplitudes. The default is a plain bell:
    #: fundamental, octave, twelfth.
    partials: tuple[tuple[float, float], ...] = ((1.0, 1.0), (2.0, 0.3), (3.0, 0.1))


@dataclass(frozen=True)
class Voice:
    """A named sound: its file name and the notes it is built from."""

    name: str
    intent: str
    duration: float
    notes: tuple[Note, ...] = field(default_factory=tuple)


#: A soft bell — fewer upper partials, so it reads as a tap rather than a chime.
SOFT = ((1.0, 1.0), (2.0, 0.22), (3.0, 0.06))
#: A struck bar, with the inharmonic partial that makes a low tone read as a
#: knock instead of a hum.
KNOCK = ((1.0, 1.0), (2.4, 0.34), (4.1, 0.12))

VOICES = (
    Voice(
        name="AgentBar Question",
        intent="An agent asked something. Rising fifth: the shape of a question.",
        duration=0.52,
        notes=(
            Note(at=0.0, frequency=880.00, decay=0.10),
            Note(at=0.13, frequency=1318.51, decay=0.16),
        ),
    ),
    Voice(
        name="AgentBar Waiting",
        intent="An agent is blocked but nothing was asked. One soft tone.",
        duration=0.55,
        notes=(Note(at=0.0, frequency=880.00, decay=0.20, partials=SOFT),),
    ),
    Voice(
        name="AgentBar Finished",
        intent="A turn ended. A falling fifth resolving onto the lower note.",
        duration=0.60,
        notes=(
            Note(at=0.0, frequency=1318.51, decay=0.10, gain=0.85),
            Note(at=0.13, frequency=880.00, decay=0.22),
        ),
    ),
    Voice(
        name="AgentBar Failed",
        intent="A turn died. Two low knocks — negative, never alarming.",
        duration=0.42,
        notes=(
            Note(at=0.0, frequency=220.00, decay=0.09, partials=KNOCK),
            Note(at=0.11, frequency=174.61, decay=0.13, partials=KNOCK),
        ),
    ),
)


def render(voice: Voice) -> list[float]:
    """Sum every note of a voice into one buffer of floats in [-1, 1]."""
    total = int(voice.duration * SAMPLE_RATE)
    buffer = [0.0] * total

    for note in voice.notes:
        start = int(note.at * SAMPLE_RATE)
        for index in range(start, total):
            elapsed = (index - start) / SAMPLE_RATE
            envelope = math.exp(-elapsed / note.decay)
            # Tested before the attack ramp is applied: during the ramp the
            # envelope is legitimately near zero, and breaking there would end
            # every note on its first sample.
            if envelope < 1e-4:
                break
            if elapsed < ATTACK:
                envelope *= elapsed / ATTACK
            sample = sum(
                amplitude * math.sin(2 * math.pi * note.frequency * ratio * elapsed)
                for ratio, amplitude in note.partials
            )
            buffer[index] += note.gain * envelope * sample

    release = int(RELEASE * SAMPLE_RATE)
    for offset in range(min(release, total)):
        buffer[total - 1 - offset] *= offset / release

    loudest = max((abs(sample) for sample in buffer), default=0.0)
    if loudest == 0.0:
        raise ValueError(f"{voice.name} rendered silence")
    return [sample * PEAK / loudest for sample in buffer]


def write_wave(samples: list[float], path: Path) -> None:
    frames = b"".join(
        struct.pack("<h", max(-32_768, min(32_767, round(sample * 32_767))))
        for sample in samples
    )
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(frames)


def main() -> int:
    afconvert = shutil.which("afconvert")
    if afconvert is None:
        print("error: afconvert not found; it ships with macOS", file=sys.stderr)
        return 2

    DESTINATION.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as scratch:
        for voice in VOICES:
            staging = Path(scratch) / f"{voice.name}.wav"
            write_wave(render(voice), staging)
            target = DESTINATION / f"{voice.name}.aiff"
            # -d BEI16: big-endian signed 16-bit, which is what an AIFF holds
            # and what /System/Library/Sounds is encoded as.
            subprocess.run(
                [afconvert, "-f", "AIFF", "-d", "BEI16", str(staging), str(target)],
                check=True,
            )
            print(f"{target.name}  {voice.duration:.2f}s  — {voice.intent}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
