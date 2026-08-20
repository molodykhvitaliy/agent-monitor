#!/usr/bin/env python3
"""Install AgentBar's four notification sounds from the authored pack.

    scripts/make-sounds.py [pack-directory]

This script **used to synthesise** the four sounds from additive tones, and
committing it was how a voice could be changed without finding whoever made the
file ([ADR-0006](../docs/adr/ADR-0006-notification-sounds-are-files-agentbar-can-resolve.md)).
Step 11 replaced the synthesised set with a designed one and the script with
this: the audio is authored elsewhere now, and what this file owns is the step
between the authored WAV and the `.aiff` the bundle carries
([ADR-0010](../docs/adr/ADR-0010-notification-sounds-are-an-authored-pack.md)).

Rewriting it rather than deleting it is the point. Left as it was, the first
person to follow its own docstring would have overwritten the designed pack with
44.1 kHz synthesis, and the only evidence would have been four changed binaries.

The conversion is **lossless and reversible** — same sample rate, same bit
depth, big-endian instead of little, AIFF instead of RIFF — so the committed
`.aiff` is the authored asset rather than a build artefact, and this script
reproduces it byte for byte rather than producing it. It verifies that: every
sample is compared against the source after the byte swap, and a mismatch is an
error rather than a warning.

The pack is not in the repository — it is 24-bit audio rendered by a generator
that needs numpy and scipy, which nothing else here does. Point the script at it
or leave it in `.scratch/audio-pack`.
"""

from __future__ import annotations

import shutil
import struct
import subprocess
import sys
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parent.parent
DESTINATION = REPOSITORY / "Apps" / "AgentBar" / "Sounds"
DEFAULT_PACK = REPOSITORY / ".scratch" / "audio-pack"

#: Pack file → bundled file. The mapping is the whole design decision in this
#: script: `permission` is AgentBar's `Waiting`, because the event AgentBar
#: calls Waiting is the one where an agent is blocked on a person, which is
#: what the pack's request-for-access voice was written for.
VOICES = (
    ("question", "AgentBar Question", "D4 → G4, a fourth up — a question rises"),
    ("permission", "AgentBar Waiting", "G4 → E4, a minor third down"),
    ("done", "AgentBar Finished", "G4 → C4 with a sub C3 — a resolution"),
    ("error", "AgentBar Failed", "C4 → A♭3"),
)

#: Big-endian signed 24-bit at 48 kHz. Not a taste decision: it is the encoding
#: the pack is authored in and the one `/System/Library/Sounds/Glass.aiff` uses,
#: so the conversion moves no bits and macOS is being handed the format it ships
#: its own notification sounds in.
ENCODING = "BEI24@48000"


def wave_samples(path: Path) -> bytes:
    """The `data` chunk of a RIFF/WAVE file, unparsed."""
    raw = path.read_bytes()
    if raw[:4] != b"RIFF" or raw[8:12] != b"WAVE":
        raise ValueError(f"{path.name} is not a RIFF/WAVE file")
    offset = 12
    while offset + 8 <= len(raw):
        identifier = raw[offset : offset + 4]
        size = struct.unpack("<I", raw[offset + 4 : offset + 8])[0]
        if identifier == b"data":
            return raw[offset + 8 : offset + 8 + size]
        offset += 8 + size + (size & 1)
    raise ValueError(f"{path.name} has no data chunk")


def aiff_samples(path: Path) -> bytes:
    """The sample data of an AIFF file, past the SSND chunk's own header."""
    raw = path.read_bytes()
    if raw[:4] != b"FORM" or raw[8:12] != b"AIFF":
        raise ValueError(f"{path.name} is not an AIFF file")
    offset = 12
    while offset + 8 <= len(raw):
        identifier = raw[offset : offset + 4]
        size = struct.unpack(">I", raw[offset + 4 : offset + 8])[0]
        if identifier == b"SSND":
            # SSND opens with offset and blockSize, then the samples.
            start = struct.unpack(">I", raw[offset + 8 : offset + 12])[0]
            return raw[offset + 16 + start : offset + 8 + size]
        offset += 8 + size + (size & 1)
    raise ValueError(f"{path.name} has no SSND chunk")


def byte_swapped(samples: bytes, width: int = 3) -> bytes:
    """Little-endian samples read as big-endian, which is the whole conversion."""
    return b"".join(samples[i : i + width][::-1] for i in range(0, len(samples), width))


def main() -> int:
    afconvert = shutil.which("afconvert")
    if afconvert is None:
        print("error: afconvert not found; it ships with macOS", file=sys.stderr)
        return 2

    pack = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else DEFAULT_PACK
    sources = {name: pack / "core" / f"{name}.wav" for name, _, _ in VOICES}
    missing = [str(path) for path in sources.values() if not path.is_file()]
    if missing:
        # Refusing beats writing three of four: a half-installed set is a set
        # whose sounds no longer belong to each other, and nothing downstream
        # would say so.
        print("error: the authored pack is not where this script looked", file=sys.stderr)
        for path in missing:
            print(f"  missing {path}", file=sys.stderr)
        print(f"\nusage: {sys.argv[0]} [pack-directory]", file=sys.stderr)
        return 2

    DESTINATION.mkdir(parents=True, exist_ok=True)
    for name, bundled, intent in VOICES:
        source = sources[name]
        target = DESTINATION / f"{bundled}.aiff"
        subprocess.run(
            [afconvert, "-f", "AIFF", "-d", ENCODING, str(source), str(target)],
            check=True,
        )
        if byte_swapped(wave_samples(source)) != aiff_samples(target):
            print(
                f"error: {target.name} is not sample-identical to {source.name} — "
                "the conversion was not the byte swap it is supposed to be",
                file=sys.stderr,
            )
            return 1
        print(f"{target.name}  ← {source.name}  — {intent}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
