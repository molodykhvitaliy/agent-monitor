#!/usr/bin/env python3
"""Measure what a running AgentBar costs the machine.

The one failure the unit suites could not have caught was a running app pegging
a core: the system's own record for 2026-08-20 has AgentBar at 98 % of a CPU for
92 seconds, entirely inside the panel's layout, and nothing in the repository
could reproduce or even observe that. This script is the observation.

It drives the app the way a working day does — a set of sessions, then a stream
of tool events — and samples the process's CPU and resident size while it runs.
Every request goes to AgentBar's **own loopback endpoint**, discovered from the
description the app publishes for its Codex helper, so this is the same traffic
a hook produces and reaches nothing outside this machine.

    make perf-probe                       # 20 sessions, 60 seconds
    scripts/perf-probe.py --sessions 60 --seconds 120 --budget 25

The synthetic sessions are named `perf-probe-*` under `~/perf-probe/`, so they
are recognisable in the panel; they retire ten minutes after the stream stops
(ADR-0012). Exits non-zero when the app spends more than `--budget` percent of
one core, which is what makes this runnable as a check rather than only as a
diagnostic.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request

SUPPORT = os.path.expanduser("~/Library/Application Support/AgentBar")
PREFIX = "perf-probe"


def endpoint() -> tuple[str, dict[str, str]]:
    """The URL and headers a hook would use, read from the app's own files."""
    try:
        with open(os.path.join(SUPPORT, "endpoint.json"), encoding="utf-8") as handle:
            description = json.load(handle)
        with open(os.path.join(SUPPORT, "ingest-token"), encoding="utf-8") as handle:
            token = handle.read().strip()
    except OSError as error:
        sys.exit(f"perf-probe: AgentBar has published no endpoint ({error})")
    host = description.get("host", "127.0.0.1")
    port = description.get("port")
    if not port:
        sys.exit("perf-probe: the endpoint description names no port")
    return (
        f"http://{host}:{port}/v1/hooks/claude-code",
        {"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )


def post(url: str, headers: dict[str, str], body: dict) -> None:
    request = urllib.request.Request(
        url, data=json.dumps(body).encode(), headers=headers, method="POST"
    )
    try:
        with urllib.request.urlopen(request, timeout=2):
            pass
    except Exception as error:  # noqa: BLE001 - a probe reports, never fails hard
        print(f"  post failed: {error}", file=sys.stderr)


def agentbar_pid() -> int:
    found = subprocess.run(
        ["pgrep", "-x", "AgentBar"], capture_output=True, text=True, check=False
    )
    pids = [line for line in found.stdout.split() if line]
    if not pids:
        sys.exit("perf-probe: AgentBar is not running")
    return int(pids[0])


def cpu_seconds(pid: int) -> float:
    """Accumulated CPU time, in seconds. `ps` reports [dd-]hh:mm:ss.ss."""
    out = subprocess.run(
        ["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True, check=False
    ).stdout.strip()
    if not out:
        sys.exit("perf-probe: AgentBar exited during the run")
    days, _, rest = out.rpartition("-")
    parts = [float(piece) for piece in rest.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0.0)
    total = parts[0] * 3600 + parts[1] * 60 + parts[2]
    return total + (float(days) * 86400 if days else 0.0)


def resident_kb(pid: int) -> int:
    out = subprocess.run(
        ["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True, check=False
    ).stdout.strip()
    return int(out) if out else 0


def register(url, headers, count: int) -> None:
    for index in range(count):
        session = f"{PREFIX}-{index:03d}"
        cwd = os.path.expanduser(f"~/perf-probe/project-{index % 5}")
        post(url, headers, {
            "hook_event_name": "UserPromptSubmit", "session_id": session, "cwd": cwd,
            "model": {"id": "probe"},
        })
        # Two in three finish their turn, one in three stays mid-tool: the mix a
        # working day actually holds, and the one that keeps the panel busy.
        if index % 3:
            post(url, headers, {"hook_event_name": "Stop", "session_id": session, "cwd": cwd})
        else:
            post(url, headers, {
                "hook_event_name": "PreToolUse", "session_id": session, "cwd": cwd,
                "tool_name": "Bash", "tool_input": {"command": "swift test"},
                "tool_use_id": f"{session}-open",
            })


def stream(url, headers, busy: int, seconds: float, pid: int, interval: float) -> list[tuple]:
    """Streams tool events, sampling the process at every interval."""
    samples: list[tuple[float, float, int]] = []
    started = time.monotonic()
    last_cpu, last_at = cpu_seconds(pid), started
    serial = 0
    next_sample = started + interval
    while time.monotonic() - started < seconds:
        for index in range(busy):
            session = f"{PREFIX}-{index:03d}"
            cwd = os.path.expanduser(f"~/perf-probe/project-{index % 5}")
            for event in ("PreToolUse", "PostToolUse"):
                post(url, headers, {
                    "hook_event_name": event, "session_id": session, "cwd": cwd,
                    "tool_name": "Read", "tool_input": {"file_path": f"/tmp/probe-{serial}.swift"},
                    "tool_use_id": f"t-{serial}",
                })
            serial += 1
        now = time.monotonic()
        if now >= next_sample:
            cpu = cpu_seconds(pid)
            elapsed = now - last_at
            percent = (cpu - last_cpu) / elapsed * 100 if elapsed > 0 else 0.0
            samples.append((now - started, percent, resident_kb(pid)))
            print(f"  t+{now - started:5.0f}s  cpu {percent:6.1f}%  rss {resident_kb(pid) // 1024:5d} MB")
            last_cpu, last_at, next_sample = cpu, now, now + interval
        time.sleep(0.35)
    return samples


def main() -> int:
    parser = argparse.ArgumentParser(description="Measure a running AgentBar under load.")
    parser.add_argument("--sessions", type=int, default=20, help="synthetic sessions to register")
    parser.add_argument("--busy", type=int, default=4, help="sessions emitting tool events")
    parser.add_argument("--seconds", type=float, default=60, help="how long to stream for")
    parser.add_argument("--interval", type=float, default=10, help="seconds between samples")
    parser.add_argument(
        "--budget", type=float, default=25,
        help="fail if mean CPU exceeds this percentage of one core")
    arguments = parser.parse_args()

    url, headers = endpoint()
    pid = agentbar_pid()
    print(f"AgentBar pid {pid}, endpoint {url}")

    print(f"idle baseline over {arguments.interval:.0f}s (nothing sent)")
    before, at = cpu_seconds(pid), time.monotonic()
    time.sleep(arguments.interval)
    idle = (cpu_seconds(pid) - before) / (time.monotonic() - at) * 100
    print(f"  idle {idle:6.1f}%  rss {resident_kb(pid) // 1024:5d} MB")

    print(f"registering {arguments.sessions} sessions")
    register(url, headers, arguments.sessions)

    print(f"streaming tool events from {arguments.busy} sessions for {arguments.seconds:.0f}s")
    samples = stream(url, headers, arguments.busy, arguments.seconds, pid, arguments.interval)
    if not samples:
        print("no samples taken — run for longer than one interval", file=sys.stderr)
        return 2

    percents = [percent for _, percent, _ in samples]
    mean = sum(percents) / len(percents)
    growth = samples[-1][2] - samples[0][2]
    print(f"\nmean {mean:.1f}% of a core, peak {max(percents):.1f}%, idle {idle:.1f}%")
    print(f"resident size moved {growth / 1024:+.1f} MB across the run")
    print("panel rows retire ten minutes after the stream stops (ADR-0012)")

    if mean > arguments.budget:
        print(f"\nFAIL: {mean:.1f}% exceeds the {arguments.budget:.0f}% budget", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
