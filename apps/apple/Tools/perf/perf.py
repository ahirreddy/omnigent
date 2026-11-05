#!/usr/bin/env python3
"""Timed scenarios for the Mac app against the local API, for before/after numbers.

Launches YOUR build by path with a main-thread hitch monitor injected (hitch-monitor.c), then
measures launch, opening a session by deep link and streaming a reply. Needs no Accessibility
permission. See apps/apple/docs/performance.md.

    perf.py launch --app <Omnigent.app> [<session-id>]
    perf.py open --app <Omnigent.app> <session-id> [--sample 6]
    perf.py stream --app <Omnigent.app> <session-id> [--seconds 12] [--sample 1]
    perf.py idle --app <Omnigent.app> [--seconds 5] [--sample 1]
    perf.py type --app <Omnigent.app> [<session-id>] [--sample 1]  # 20 keystrokes, then deletes
    perf.py shot --app <Omnigent.app> [<file.png>]
    perf.py drive --app <Omnigent.app> scroll-transcript  # or scroll-sidebar, toggle-panel...
    perf.py suite --app <Omnigent.app> [--runs 3]   # every scenario, medians
    perf.py suite --app <Omnigent.app> --style cli    # the same with the CLI-style transcript
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import statistics
import subprocess
import tempfile
import time
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
CACHE = Path(os.environ.get("TMPDIR", tempfile.gettempdir())) / "omnigent-perf"
LOG = CACHE / "hitches.log"
FRAMES = CACHE / "frames.log"
DRIVE = CACHE / "drive.txt"
SERVER = "http://127.0.0.1:6767"
# Waits of at least this long miss two frames at 60 Hz; 100 ms reads as a stall.
HITCH_MS = 33.0
HANG_MS = 100.0
# Extra launch arguments, for example the transcript style (`--style cli`).
LAUNCH_ARGS: list[str] = []


@dataclass
class Hitches:
    """Main-thread waits inside a time window."""

    waits: list[float]

    @property
    def numbers(self) -> dict[str, float]:
        hitches = [wait for wait in self.waits if wait >= HITCH_MS]
        return {
            "hitches": len(hitches),
            "hangs": sum(wait >= HANG_MS for wait in self.waits),
            "worst_ms": max(self.waits, default=0.0),
            "blocked_ms": sum(hitches),
        }

    @property
    def summary(self) -> str:
        hitches = [wait for wait in self.waits if wait >= HITCH_MS]
        hangs = [wait for wait in self.waits if wait >= HANG_MS]
        worst = max(self.waits, default=0.0)
        return (
            f"hitches(>={HITCH_MS:.0f}ms)={len(hitches)} hangs(>={HANG_MS:.0f}ms)={len(hangs)} "
            f"worst={worst:.0f}ms blocked={sum(hitches):.0f}ms"
        )


def current(text: str) -> list[str]:
    """The log lines the running app wrote: those after the last "# start"."""
    lines = text.splitlines()
    starts = [index for index, line in enumerate(lines) if line.startswith("# start")]
    return [line for line in lines[starts[-1] if starts else 0 :] if line.strip()]


def parse_log(text: str, start_ms: float, end_ms: float) -> Hitches:
    """The waits in ``text`` (hitch-monitor lines) that began inside [start, end)."""
    waits = []
    for line in current(text):
        if line.startswith("#"):
            continue
        began, wait = line.split()
        if start_ms <= float(began) < end_ms:
            waits.append(float(wait))
    return Hitches(waits)


@dataclass
class Frames:
    """Display frames the main thread started inside a time window (driver.m's frame log)."""

    seconds: float
    frames: int
    period_ms: float
    long: list[float]
    # The time the frame counts cover (whole 250 ms windows).
    counted_seconds: float = 0.0

    @property
    def numbers(self) -> dict[str, float]:
        period = self.period_ms or 1000 / 60
        dropped = sum(max(0, round(interval / period) - 1) for interval in self.long)
        hitch = sum(interval - period for interval in self.long)
        return {
            "fps": self.frames / self.counted_seconds if self.counted_seconds else 0.0,
            "long_frames": len(self.long),
            "over_16ms": sum(interval > 1000 / 60 for interval in self.long),
            "dropped": dropped,
            "hitch_ms_per_s": hitch / self.seconds if self.seconds else 0.0,
            "worst_frame_ms": max(self.long, default=period),
        }

    @property
    def summary(self) -> str:
        n = self.numbers
        return (
            f"{n['fps']:.0f} fps at {1000 / (self.period_ms or 1000 / 60):.0f} Hz, "
            f"long frames {n['long_frames']:.0f} (>16.7ms {n['over_16ms']:.0f}), "
            f"dropped {n['dropped']:.0f}, hitch {n['hitch_ms_per_s']:.0f} ms/s, "
            f"worst frame {n['worst_frame_ms']:.0f}ms"
        )


def parse_frames(text: str, start_ms: float, end_ms: float) -> Frames:
    """The frames in ``text`` (driver.m lines) inside [start, end)."""
    frames, windows, period, long = 0, 0, 0.0, []
    for line in current(text):
        parts = line.split()
        if line.startswith("# frames"):
            stamp = float(parts[2])
            # Each line counts the 250 ms before it.
            if start_ms + 250 <= stamp <= end_ms:
                frames += int(parts[3])
                windows += 1
                period = float(parts[4])
        elif not line.startswith("#"):
            stamp, interval = float(parts[0]), float(parts[1])
            if start_ms <= stamp < end_ms:
                long.append(interval)
    return Frames((end_ms - start_ms) / 1000, frames, period, long, windows * 0.25)


def settle_time(text: str, start_ms: float, quiet_ms: float = 1000.0) -> float:
    """Milliseconds from ``start`` to the end of the last hitch before ``quiet_ms`` without one."""
    ends = []
    for line in current(text):
        if line.startswith("#"):
            continue
        began, wait = map(float, line.split())
        if began >= start_ms and wait >= HITCH_MS:
            ends.append((began, began + wait))
    settled = start_ms
    for began, end in sorted(ends):
        if began - settled > quiet_ms:
            break
        settled = max(settled, end)
    return settled - start_ms


def main_thread_busy(sample_text: str) -> tuple[int, int]:
    """(on-CPU, total) main-thread samples in a ``sample`` report: leaves that are not a wait."""
    lines = sample_text.split("\n")
    start = next(
        i
        for i, line in enumerate(lines)
        if re.match(r"^    \d+ Thread_\d+.*Main Thread", line) or "com.apple.main-thread" in line
    )
    end = next(
        (i for i in range(start + 1, len(lines)) if re.match(r"^    \d+ Thread_", lines[i])),
        len(lines),
    )
    pattern = re.compile(r"^([ +!:|]*)(\d+) (.+)")
    parsed = [
        (len(m.group(1)), int(m.group(2)), m.group(3))
        for m in map(pattern.match, lines[start:end])
        if m
    ]
    total = parsed[0][1]
    waiting = 0
    for index, (depth, count, name) in enumerate(parsed):
        is_leaf = index + 1 == len(parsed) or parsed[index + 1][0] <= depth
        if is_leaf and any(
            wait in name
            for wait in ("mach_msg2_trap", "__psynch_cvwait", "__ulock_wait", "__semwait")
        ):
            waiting += count
    return total - waiting, total


def build_tools() -> tuple[str, Path]:
    """The injected libraries (hitch monitor and typist) and the window probe, rebuilt when
    their sources change."""
    CACHE.mkdir(parents=True, exist_ok=True)
    dylib, probe = CACHE / "hitch-monitor.dylib", CACHE / "window-probe"
    typist = CACHE / "typist.dylib"
    driver = CACHE / "driver.dylib"
    builds = {
        dylib: ["clang", "-dynamiclib", "-O2", "-o", dylib, HERE / "hitch-monitor.c"],
        typist: [
            "clang",
            "-dynamiclib",
            "-fobjc-arc",
            "-O2",
            "-framework",
            "AppKit",
            "-o",
            typist,
            HERE / "typist.m",
        ],
        driver: [
            "clang",
            "-dynamiclib",
            "-fobjc-arc",
            "-O2",
            "-framework",
            "AppKit",
            "-framework",
            "QuartzCore",
            "-o",
            driver,
            HERE / "driver.m",
        ],
        probe: [
            "clang",
            "-O2",
            "-framework",
            "CoreGraphics",
            "-framework",
            "CoreFoundation",
            "-o",
            probe,
            HERE / "window-probe.c",
        ],
    }
    for output, command in builds.items():
        if not output.exists() or output.stat().st_mtime < command[-1].stat().st_mtime:
            subprocess.run(command, check=True)
    return f"{dylib}:{typist}:{driver}", probe


def app_pid(app: Path) -> int | None:
    """The pid of the app at ``app``, if it runs."""
    result = subprocess.run(
        ["pgrep", "-f", f"{app}/Contents/MacOS/"], capture_output=True, text=True
    )
    pids = [int(pid) for pid in result.stdout.split()]
    return pids[0] if pids else None


def main_cpu_ms(pid: int) -> float:
    """CPU time the app's main thread has used, in ms (``ps -M``: its first thread). Unlike
    wall-clock times it barely moves with the machine's load."""
    row = (
        subprocess.run(["ps", "-M", "-p", str(pid)], capture_output=True, text=True, check=True)
        .stdout.splitlines()[1]
        .split()
    )

    def milliseconds(field: str) -> float:
        minutes, seconds = field.split(":")
        return (int(minutes) * 60 + float(seconds)) * 1000

    return milliseconds(row[6]) + milliseconds(row[7])


def now_ms() -> float:
    return time.time() * 1000


def quiet_since(text: str, start_ms: float) -> float:
    """How long the monitor has seen the main thread answer since the last hitch after
    ``start``: 0 while a long stall lasts or before the monitor reported in."""
    lines = current(text)
    alive = [float(line.split()[2]) for line in lines if line.startswith("# alive")]
    if not alive or lines[-1].startswith("# stalled"):
        return 0.0
    return alive[-1] - (start_ms + settle_time(text, start_ms))


def wait_settled(start_ms: float, limit_s: float = 60.0) -> float:
    """Waits until the main thread had a quiet second, and returns the settle time in ms."""
    deadline = time.time() + limit_s
    while time.time() < deadline:
        time.sleep(0.25)
        text = LOG.read_text()
        if quiet_since(text, start_ms) > 1000:
            return settle_time(text, start_ms)
    return settle_time(LOG.read_text(), start_ms)


def sample(pid: int, seconds: int, name: str) -> str:
    """Samples ``pid`` and returns the report path; prints the main thread's busy share."""
    path = CACHE / f"{name}.sample.txt"
    subprocess.run(
        ["sample", str(pid), str(seconds), "-file", path], capture_output=True, check=True
    )
    busy, total = main_thread_busy(path.read_text())
    print(
        f"  main thread on CPU: {100 * busy / max(total, 1):.0f}% ({busy}/{total} samples), "
        f"report {path}"
    )
    return str(path)


def saved_tabs() -> dict:
    """A saved-tabs file with one window and one New Tab, so every launch starts the same."""
    tab_id, window_id = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
    snapshot = {
        "closed": [],
        "selectedID": tab_id,
        "tabs": [{"content": {"newTab": {}}, "id": tab_id, "isPinned": False}],
    }
    record = dict(
        snapshot,
        launch=str(uuid.uuid4()).upper(),
        window=window_id,
        savedAt=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    )
    return {"server": SERVER, "version": 1, "windows": [record]}


def tabs_file(bundle_id: str) -> Path:
    """Where the app saves the local server's tabs (TabPersistence: a digest of the URL)."""
    key = hashlib.sha256(SERVER.lower().encode()).digest()[:12].hex()
    return Path.home() / "Library/Application Support" / bundle_id / "Tabs" / f"{key}.json"


def launch(app: Path, session_id: str | None) -> dict[str, float]:
    """Quits the app, starts it with the hitch monitor on one window that opens ``session_id``
    (else a New Tab), and reports time to window and settle."""
    libraries, probe = build_tools()
    quit_app(app)
    bundle_id = subprocess.run(
        [
            "/usr/libexec/PlistBuddy",
            "-c",
            "Print :CFBundleIdentifier",
            app / "Contents/Info.plist",
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    tabs_file(bundle_id).parent.mkdir(parents=True, exist_ok=True)
    tabs_file(bundle_id).write_text(json.dumps(saved_tabs()))
    LOG.write_text("")
    FRAMES.write_text("")
    start = now_ms()
    # Without SwiftUI's saved windows every launch opens one window; the link connects it to the
    # local server and shows the session.
    target = (
        f"omnigent://127.0.0.1:6767/c/{session_id}" if session_id else "omnigent://127.0.0.1:6767"
    )
    subprocess.run(
        [
            "open",
            "-a",
            app,
            "-o",
            CACHE / "stdout.log",
            "--env",
            f"DYLD_INSERT_LIBRARIES={libraries}",
            "--env",
            f"OMNIGENT_HITCH_LOG={LOG}",
            "--env",
            f"OMNIGENT_FRAME_LOG={FRAMES}",
            "--env",
            f"OMNIGENT_DRIVE_FILE={DRIVE}",
            target,
            "--args",
            "-ApplePersistenceIgnoreState",
            "YES",
            *LAUNCH_ARGS,
        ],
        check=True,
    )
    while (pid := app_pid(app)) is None:
        time.sleep(0.005)
    shown = float(
        subprocess.run([probe, str(pid)], capture_output=True, text=True, check=True).stdout
    )
    settled = wait_settled(start)
    cpu = main_cpu_ms(pid)
    hitches = parse_log(LOG.read_text(), start, start + settled + 1)
    print(
        f"launch: first window {shown - start:.0f}ms, settled {settled:.0f}ms, "
        f"main thread CPU {cpu:.0f}ms; {hitches.summary}"
    )
    return {
        "window_ms": shown - start,
        "settled_ms": settled,
        "main_cpu_ms": cpu,
        **hitches.numbers,
    }


def quit_app(app: Path) -> None:
    """Quits every running copy of ``app``, killing one that does not exit within 10 s."""
    deadline = time.time() + 10
    while (pid := app_pid(app)) is not None:
        signal = "-TERM" if time.time() < deadline else "-KILL"
        subprocess.run(["kill", signal, str(pid)], capture_output=True)
        time.sleep(0.5)


def long_session(index: int) -> str:
    """The id seed-large-fixtures.py gives its long transcript ``index``."""
    return hashlib.sha256(f"perf-long/{index}".encode()).hexdigest()[:32]


def require_monitored(app: Path) -> int:
    pid = app_pid(app)
    if pid is None or not LOG.exists():
        raise SystemExit("Start the app with `perf.py launch` first.")
    return pid


def open_session(app: Path, session_id: str, sample_seconds: int = 0) -> dict[str, float]:
    """Opens ``session_id`` by deep link and reports time to settle and the hitches on the way."""
    pid = require_monitored(app)
    wait_settled(now_ms())
    cpu = main_cpu_ms(pid)
    start = now_ms()
    subprocess.run(["open", "-a", app, f"omnigent://127.0.0.1:6767/c/{session_id}"], check=True)
    if sample_seconds:
        sample(pid, sample_seconds, f"open-{session_id[:8]}")
    settled = wait_settled(start)
    cpu = main_cpu_ms(pid) - cpu
    hitches = parse_log(LOG.read_text(), start, start + settled + 1)
    frames = parse_frames(FRAMES.read_text(), start, start + settled + 1)
    print(
        f"open {session_id[:8]}: settled {settled:.0f}ms, main thread CPU {cpu:.0f}ms; "
        f"{hitches.summary}; {frames.summary}"
    )
    return {"settled_ms": settled, "main_cpu_ms": cpu, **hitches.numbers, **frames.numbers}


def stream(app: Path, session_id: str, seconds: int, sampled: bool = False) -> dict[str, float]:
    """Sends a message to ``session_id`` (the mock model streams a reply) and reports the
    main thread while it streams."""
    pid = require_monitored(app)
    body = {
        "type": "message",
        "data": {
            "role": "user",
            "content": [{"type": "input_text", "text": "Stream a long reply for the perf check."}],
        },
    }
    request = urllib.request.Request(
        f"{SERVER}/v1/sessions/{session_id}/events",
        method="POST",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    wait_settled(now_ms())
    cpu = main_cpu_ms(pid)
    start = now_ms()
    urllib.request.urlopen(request, timeout=30).read()
    # Sampling suspends the app briefly per sample, so hitch counts come from unsampled runs.
    if sampled:
        sample(pid, seconds, f"stream-{session_id[:8]}")
    else:
        time.sleep(seconds)
    end = now_ms()
    hitches = parse_log(LOG.read_text(), start, end)
    frames = parse_frames(FRAMES.read_text(), start, end)
    cpu = main_cpu_ms(pid) - cpu
    print(
        f"stream {session_id[:8]} ({seconds}s): main thread CPU {cpu:.0f}ms; {hitches.summary}; "
        f"{frames.summary}"
    )
    # Let the turn finish so the next run starts idle.
    wait_settled(now_ms())
    return {"main_cpu_ms": cpu, **hitches.numbers, **frames.numbers}


def type_burst(app: Path, sampled: bool = False, count: int = 20) -> dict[str, float]:
    """Focuses the open session's composer and types ``count`` characters, one every 80 ms,
    then deletes them (typist.m), and reports the main thread meanwhile."""
    pid = require_monitored(app)
    wait_settled(now_ms())
    cpu = main_cpu_ms(pid)
    start = now_ms()
    subprocess.run(["kill", "-USR1", str(pid)], check=True)
    seconds = 0.3 + 0.08 * 2 * count + 0.5
    if sampled:
        sample(pid, max(1, round(seconds)), "type")
    else:
        time.sleep(seconds)
    wait_settled(now_ms())
    end = now_ms()
    hitches = parse_log(LOG.read_text(), start, end)
    frames = parse_frames(FRAMES.read_text(), start, end)
    cpu = main_cpu_ms(pid) - cpu
    print(
        f"type {count} characters, then delete: main thread CPU {cpu:.0f}ms; {hitches.summary}; "
        f"{frames.summary}"
    )
    return {"main_cpu_ms": cpu, **hitches.numbers, **frames.numbers}


# Driven scenarios (driver.m steps). Fractions of the window: the sidebar is the left fifth.
SCENARIOS = {
    "scroll-transcript": ["scroll 0.6 0.5 -60 90", "scroll 0.6 0.5 60 90"],
    "scroll-sidebar": ["scroll 0.08 0.6 -60 90", "scroll 0.08 0.6 60 90"],
    "toggle-sidebar": ["key s ct", "wait 700", "key s ct"],
    "toggle-panel": ["key ] co", "wait 900", "key ] co"],
    "resize": ["resize -320 -160 30", "resize 320 160 30"],
    "palette": ["key k c", "wait 700", "key esc"],
    "new-session": ["key n c"],
    "settings": ["key , c", "wait 1500", "key w c"],
    # Find Session focuses the sidebar's search; each letter filters every session.
    "search": [
        "key s co",
        "wait 300",
        *[f"key {c}" for c in "perf"],
        "wait 150",
        *["key del"] * 4,
        "wait 300",
        "key esc",
    ],
}


def drive(app: Path, name: str, steps: list[str], sampled: bool = False) -> dict[str, float]:
    """Runs driver steps in the app and reports the main thread and frames meanwhile."""
    pid = require_monitored(app)
    wait_settled(now_ms())
    DRIVE.write_text("\n".join(steps) + "\n")
    cpu = main_cpu_ms(pid)
    start = now_ms()
    subprocess.run(["kill", "-USR2", str(pid)], check=True)
    seconds = 0.5 + sum(step_seconds(step) for step in steps)
    if sampled:
        sample(pid, max(1, round(seconds)), name)
    else:
        time.sleep(seconds)
    # Work that outlasts the steps counts until the main thread is quiet.
    end = max(now_ms(), start + wait_settled(start))
    hitches = parse_log(LOG.read_text(), start, end)
    frames = parse_frames(FRAMES.read_text(), start, end)
    cpu = main_cpu_ms(pid) - cpu
    print(f"{name}: main thread CPU {cpu:.0f}ms; {hitches.summary}; {frames.summary}")
    return {"main_cpu_ms": cpu, **hitches.numbers, **frames.numbers}


def step_seconds(step: str) -> float:
    """How long a driver step takes."""
    parts = step.split()
    frame = 1 / 60
    if parts[0] == "wait":
        return float(parts[1]) / 1000
    if parts[0] == "scroll":
        return frame * (int(parts[4]) + 1)
    if parts[0] == "resize":
        return frame * int(parts[3])
    return 0.05


def idle(app: Path, seconds: int, sampled: bool) -> None:
    pid = require_monitored(app)
    start = now_ms()
    if sampled:
        sample(pid, seconds, "idle")
    else:
        time.sleep(seconds)
    print(f"idle ({seconds}s): {parse_log(LOG.read_text(), start, now_ms()).summary}")


def suite(app: Path, runs: int, sessions: list[str]) -> None:
    """Each scenario ``runs`` times, then the median of each number:

    - launch: cold start to the first window and to a quiet main thread, on a New Tab;
    - open: a long session from that New Tab (deep link), until the main thread is quiet;
    - open second: another long session in a second tab, the first staying built;
    - switch: back to the first long session's tab from a second one;
    - type: 20 characters typed into its composer and deleted again;
    - stream: a mock-model reply streamed into the open long session, 12 s.
    """
    results: dict[str, list[dict[str, float]]] = {}
    for _ in range(runs):
        results.setdefault("launch", []).append(launch(app, None))
        results.setdefault("open long", []).append(open_session(app, sessions[0]))
        results.setdefault("open second", []).append(open_session(app, sessions[1]))
        results.setdefault("switch tab", []).append(open_session(app, sessions[0]))
        results.setdefault("type", []).append(type_burst(app))
        results.setdefault("stream", []).append(stream(app, sessions[0], 12))
        for name in (
            "scroll-transcript",
            "scroll-sidebar",
            "toggle-sidebar",
            "toggle-panel",
            "resize",
            "palette",
            "search",
            "settings",
            "new-session",
        ):
            results.setdefault(name, []).append(drive(app, name, SCENARIOS[name]))
    print(f"\nmedians of {runs} runs ({app}):")
    for scenario, rows in results.items():
        keys = rows[0].keys()
        medians = {key: statistics.median(row[key] for row in rows) for key in keys}
        print(
            f"  {scenario:17s} "
            + "  ".join(f"{key}={value:.0f}" for key, value in medians.items())
        )


def screenshot(app: Path, path: Path) -> None:
    """Saves the app's first window (only that window) to ``path``."""
    pid = require_monitored(app)
    _, probe = build_tools()
    windows = subprocess.run(
        [probe, str(pid), "--list"], capture_output=True, text=True, check=True
    )
    window = windows.stdout.split()[0]
    subprocess.run(["screencapture", "-x", "-o", "-l", window, path], check=True)
    print(f"window {window} saved to {path}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "command",
        choices=["launch", "open", "stream", "idle", "type", "shot", "suite", "drive"],
    )
    parser.add_argument("session", nargs="?")
    parser.add_argument("--app", type=Path, required=True, help="the Omnigent.app to measure")
    parser.add_argument("--seconds", type=int, default=10)
    parser.add_argument("--runs", type=int, default=3, help="suite: runs per scenario")
    parser.add_argument(
        "--sample",
        type=int,
        default=0,
        help="sample for N seconds (stream and idle: any N > 0 samples the whole run)",
    )
    parser.add_argument(
        "--style",
        choices=["chat", "cli"],
        help="launch with this transcript style (a launch argument; the saved setting is kept)",
    )
    args = parser.parse_args()
    app = args.app.resolve()
    if args.style:
        LAUNCH_ARGS.extend(["-omnigent:transcript-style", args.style])
    if args.command == "launch":
        launch(app, args.session)
    elif args.command == "suite":
        suite(app, args.runs, [long_session(0), long_session(1)])
    elif args.command == "idle":
        idle(app, args.seconds, args.sample > 0)
    elif args.command == "type":
        type_burst(app, args.sample > 0)
    elif args.command == "drive":
        if args.session not in SCENARIOS:
            raise SystemExit(f"drive needs one of: {', '.join(SCENARIOS)}")
        drive(app, args.session, SCENARIOS[args.session], args.sample > 0)
    elif args.command == "shot":
        screenshot(app, Path(args.session or CACHE / "window.png"))
    elif args.session is None:
        raise SystemExit(f"{args.command} needs a session id")
    elif args.command == "open":
        open_session(app, args.session, args.sample)
    else:
        stream(app, args.session, args.seconds, args.sample > 0)


if __name__ == "__main__":
    main()
