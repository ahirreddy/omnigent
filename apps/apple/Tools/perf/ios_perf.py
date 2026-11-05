#!/usr/bin/env python3
"""Timed scenarios for the iPhone and iPad apps in a simulator, for before/after numbers.

Starts YOUR Debug build (installed on the simulator you name) with the frame monitor
(`-OmnigentFrameMonitor YES`, FrameMonitor.swift) and the perf driver (`-OmnigentPerfDriver
YES`, PerfDriver.swift), drives it with deep links and Darwin notifications, and reports the
main thread's CPU time (``ps -M``) and frame pacing over each scenario. See
apps/apple/docs/performance.md.

    ios_perf.py launch --udid <udid> [--runs 3]          # to the idle session list
    ios_perf.py run --udid <udid> <scenario>... [--style cli] [--runs 3]
    ios_perf.py suite --udid <udid> [--style cli] [--runs 3]

Scenarios: open, switch, scroll, type, stream, list-scroll, search, keyboard, rotate,
sidebar, settings, usage, panel, new-session. ``--sample`` also runs ``sample`` on each.
"""

from __future__ import annotations

import argparse
import atexit
import hashlib
import json
import re
import statistics
import subprocess
import threading
import time
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

BUNDLE = "ai.omnigent.ios.lab"
SERVER = "http://127.0.0.1:6767"
LINK = "omnigent://127.0.0.1:6767"
PREDICATE = 'subsystem == "ai.omnigent.perf"'
# Main-thread CPU per second below which the app counts as quiet (the monitor costs a little).
QUIET_MS_PER_S = 40.0


def long_session(index: int) -> str:
    """The id seed-large-fixtures.py gives its long transcript ``index``."""
    return hashlib.sha256(f"perf-long/{index}".encode()).hexdigest()[:32]


def parse_stats(line: str) -> dict[str, float] | None:
    """The numbers in a FrameMonitor summary line (``FrameStats.summary`` plus renders)."""
    if "fps=" not in line:
        return None
    numbers: dict[str, float] = {}
    for key, value in re.findall(r"(\S+?)=(\S+)", line[line.index("fps=") :]):
        if key == "renders":
            for name, count in (pair.split(":") for pair in value.split(",")):
                numbers[f"renders.{name}"] = float(count)
        else:
            numbers[key] = float(re.sub(r"(ms/s|ms)$", "", value))
    return numbers


def ps_cpu_ms(field: str) -> float:
    """``ps`` time (``M:SS.ss`` or ``H:MM:SS``) in ms."""
    parts = [float(part) for part in field.split(":")]
    seconds = 0.0
    for part in parts:
        seconds = seconds * 60 + part
    return seconds * 1000


@dataclass
class LogStream:
    """``log stream`` from the simulator, kept in memory with arrival times."""

    udid: str
    lines: list[tuple[float, str]] = field(default_factory=list)

    def start(self) -> None:
        stream = ["log", "stream", "--style", "compact", "--predicate", PREDICATE]
        process = subprocess.Popen(
            ["xcrun", "simctl", "spawn", self.udid, *stream],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        atexit.register(process.terminate)

        def read() -> None:
            assert process.stdout is not None
            for line in process.stdout:
                self.lines.append((time.time(), line.rstrip()))

        threading.Thread(target=read, daemon=True).start()

    def wait_for(self, pattern: str, since: float, timeout: float = 10) -> str:
        deadline = time.time() + timeout
        while time.time() < deadline:
            for stamp, line in list(self.lines):
                if stamp >= since and pattern in line:
                    return line
            time.sleep(0.05)
        raise SystemExit(f"No `{pattern}` in the app's log within {timeout:.0f}s")


class Device:
    def __init__(self, udid: str, style: str, sample: bool) -> None:
        self.udid, self.style, self.sample_on = udid, style, sample
        self.log = LogStream(udid)
        self.log.start()
        self.pid = 0

    def simctl(self, *args: str) -> str:
        return subprocess.run(
            ["xcrun", "simctl", *args], capture_output=True, text=True, check=True
        ).stdout

    def post(self, name: str) -> None:
        self.simctl("spawn", self.udid, "notifyutil", "-p", f"ai.omnigent.perf.{name}")

    def open_link(self, path: str) -> None:
        # `simctl openurl` asks "Open in…?" first; the app routes the session as a link would.
        (self.container() / "tmp/perf-link.txt").write_text(path.removeprefix("/c/"))
        self.post("open")

    def container(self) -> Path:
        return Path(self.simctl("get_app_container", self.udid, BUNDLE, "data").strip())

    def main_cpu_ms(self) -> float:
        rows = subprocess.run(
            ["ps", "-M", "-p", str(self.pid)], capture_output=True, text=True, check=True
        ).stdout.splitlines()
        # The first thread is the main thread: USER PID TT %CPU STAT PRI STIME UTIME COMMAND.
        fields = rows[1].split()
        return ps_cpu_ms(fields[6]) + ps_cpu_ms(fields[7])

    def process_cpu_ms(self) -> float:
        return ps_cpu_ms(
            subprocess.run(
                ["ps", "-o", "cputime=", "-p", str(self.pid)], capture_output=True, text=True
            ).stdout.strip()
        )

    def settle(self, start: float, limit: float = 60, cpu=None) -> float:
        """Seconds from ``start`` until the main thread's (or ``cpu``'s) last busy moment
        before a quiet second."""
        read = cpu or self.main_cpu_ms
        history: list[tuple[float, float]] = [(time.time(), read())]
        busy_until = history[0][0]
        while time.time() - start < limit:
            time.sleep(0.2)
            now, used = time.time(), read()
            if used - history[-1][1] > QUIET_MS_PER_S * 0.2:
                busy_until = now
            history.append((now, used))
            window = [entry for entry in history if entry[0] >= now - 1.0]
            if now - start > 1.2 and window[-1][1] - window[0][1] < QUIET_MS_PER_S:
                return busy_until - start
        return limit

    def launch(self, *, monitor: bool = True, extra: list[str] | None = None) -> float:
        """Restarts the app; returns the launch time."""
        self.terminate()
        args = ["-OmnigentNoNotificationPrompt", "YES", "-omnigent.lastServer", SERVER]
        args += ["-omnigent:transcript-style", self.style]
        if monitor:
            args += ["-OmnigentFrameMonitor", "YES", "-OmnigentPerfDriver", "YES"]
        start = time.time()
        output = self.simctl("launch", self.udid, BUNDLE, *args, *(extra or []))
        self.pid = int(output.strip().split(":")[-1])
        return start

    def terminate(self) -> None:
        # Fails when the app is not running, which is fine.
        subprocess.run(["xcrun", "simctl", "terminate", self.udid, BUNDLE], capture_output=True)

    def clear_tabs(self) -> None:
        for file in (self.container() / "Library/Application Support" / BUNDLE / "Tabs").glob(
            "*.json"
        ):
            file.unlink()

    def sample(self, seconds: int, name: str) -> None:
        out = Path("/tmp") / f"omnigent-ios-{name}-{int(time.time())}.txt"
        subprocess.run(
            ["sample", str(self.pid), str(seconds), "-f", str(out)], capture_output=True
        )
        print(f"  sample: {out}")

    def measure(self, name: str, action, seconds: float | None = None) -> dict[str, float]:
        """Runs ``action`` inside a marked interval; waits ``seconds`` or until settled."""
        self.settle(time.time(), limit=20)
        cpu, start = self.main_cpu_ms(), time.time()
        self.post("begin")
        action()
        if self.sample_on:
            self.sample(int(seconds or 4), name)
        if seconds is not None:
            time.sleep(max(0.0, seconds - (time.time() - start)))
            settled = seconds
        else:
            settled = self.settle(start)
        self.post("end")
        # A hung main thread answers the end mark only once it frees up.
        line = self.log.wait_for("interval marked", start, timeout=180)
        stats = parse_stats(line) or {}
        stats["main_cpu_ms"] = self.main_cpu_ms() - cpu
        stats["settled_s"] = settled
        print(f"  {name}: {format_numbers(stats)}")
        return stats


def format_numbers(stats: dict[str, float]) -> str:
    keys = [
        "settled_s",
        "process_settled_s",
        "idle_cpu_pct",
        "main_cpu_ms",
        "fps",
        "hitch",
        ">16.7ms",
        ">8.3ms",
        "worst",
    ]
    keys += sorted(key for key in stats if key.startswith("renders."))
    return ", ".join(f"{key}={stats[key]:g}" for key in keys if key in stats)


def stream_message(session_id: str) -> None:
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
    urllib.request.urlopen(request, timeout=30).read()


def launch_scenario(device: Device) -> dict[str, float]:
    """Cold start to the session list with no saved tabs: time until the main thread is quiet,
    its CPU, then idle CPU over 5 s (without the monitor, which wakes every frame)."""
    device.terminate()
    device.clear_tabs()
    start = device.launch(monitor=False)
    settled = device.settle(start)
    cpu = device.main_cpu_ms()
    # Background threads (the core's session list) may still work after the main thread rests.
    quiet = device.settle(start, cpu=device.process_cpu_ms)
    idle_start = device.process_cpu_ms()
    time.sleep(5)
    idle = (device.process_cpu_ms() - idle_start) / 5000 * 100
    stats = {
        "settled_s": settled,
        "main_cpu_ms": cpu,
        "process_settled_s": quiet,
        "idle_cpu_pct": idle,
    }
    print(f"  launch: {format_numbers(stats)}, idle_cpu_pct={idle:.1f}")
    return stats


def scenarios(device: Device, names: list[str], ipad: bool) -> dict[str, dict[str, float]]:
    # iPad runs use transcripts 2 and 3, so an iPhone run can stream into 1 at the same time.
    first, second = (
        (long_session(2), long_session(3)) if ipad else (long_session(1), long_session(2))
    )
    results: dict[str, dict[str, float]] = {}
    device.clear_tabs()
    device.launch()
    device.settle(time.time())
    plan = {
        "list-scroll": lambda: device.measure(
            "list-scroll", lambda: device.post("scroll.leading" if ipad else "scroll"), 6.5
        ),
        # Search on iOS is the palette: open it, type 20 characters, delete them, close it.
        "search": lambda: device.measure(
            "search",
            lambda: (
                device.post("palette"),
                time.sleep(1.0),
                device.post("type.top"),
                time.sleep(3.6),
                device.post("palette.close"),
            ),
            5.6,
        ),
        "new-session": lambda: device.measure("new-session", lambda: device.post("newsession")),
        "settings": lambda: device.measure(
            "settings",
            lambda: (
                device.post("settings.general"),
                time.sleep(2.5),
                device.post("settings.appearance"),
                time.sleep(2.5),
                device.post("settings.close"),
            ),
            6.5,
        ),
        "usage": lambda: device.measure("usage", lambda: device.post("settings.usage")),
        "open": lambda: device.measure("open", lambda: device.open_link(f"/c/{first}")),
        "open2": lambda: device.measure("open2", lambda: device.open_link(f"/c/{second}")),
        "switch": lambda: device.measure("switch", lambda: device.open_link(f"/c/{first}")),
        "scroll": lambda: device.measure("scroll", lambda: device.post("scroll"), 6.5),
        "type": lambda: device.measure("type", lambda: device.post("type"), 3.8),
        "keyboard": lambda: device.measure(
            "keyboard",
            lambda: (device.post("keyboard"), time.sleep(1.5), device.post("keyboard")),
            3.2,
        ),
        "stream": lambda: device.measure("stream", lambda: stream_message(first), 12),
        "rotate": lambda: device.measure(
            "rotate", lambda: (device.post("rotate"), time.sleep(2), device.post("rotate")), 4.2
        ),
        "sidebar": lambda: device.measure(
            "sidebar",
            lambda: (device.post("sidebar"), time.sleep(1.5), device.post("sidebar")),
            3.2,
        ),
        "panel": lambda: device.measure(
            "panel",
            lambda: (
                device.post("panel.files"),
                time.sleep(2),
                device.post("panel.changes"),
                time.sleep(2),
                device.post("panel.pullRequests"),
                time.sleep(2),
                device.post("panel.close"),
            ),
            7.5,
        ),
    }
    for name in names:
        if name == "switch" and "open2" not in results:
            results["open2"] = plan["open2"]()
        results[name] = plan[name]()
    if "stream" in results:
        results["stream"]["renders_per_s"] = results["stream"].get("renders.transcript", 0) / 12
        device.settle(time.time())
    return results


SUITE = [
    "list-scroll",
    "search",
    "settings",
    "usage",
    "open",
    "switch",
    "scroll",
    "type",
    "keyboard",
    "stream",
]
IPAD_EXTRA = ["rotate", "sidebar", "panel"]


def repeat(runs: int, body) -> dict[str, dict[str, float]]:
    collected: dict[str, list[dict[str, float]]] = {}
    for run in range(runs):
        print(f"run {run + 1}/{runs}")
        for name, stats in body().items():
            collected.setdefault(name, []).append(stats)
    medians = {
        name: {
            key: statistics.median(entry[key] for entry in entries if key in entry)
            for key in entries[0]
        }
        for name, entries in collected.items()
    }
    print("medians:")
    for name, stats in medians.items():
        print(
            f"  {name}: {format_numbers(stats)}"
            + (f", idle_cpu_pct={stats['idle_cpu_pct']:.1f}" if "idle_cpu_pct" in stats else "")
            + (f", renders_per_s={stats['renders_per_s']:.1f}" if "renders_per_s" in stats else "")
        )
    return medians


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("command", choices=["launch", "run", "suite"])
    parser.add_argument("scenarios", nargs="*")
    parser.add_argument("--udid", required=True)
    parser.add_argument("--style", choices=["chat", "cli"], default="chat")
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--ipad", action="store_true", help="iPad: sidebar beside the detail")
    parser.add_argument("--sample", action="store_true")
    options = parser.parse_args()
    device = Device(options.udid, options.style, options.sample)
    if options.command == "launch":
        repeat(options.runs, lambda: {"launch": launch_scenario(device)})
        return
    names = (
        options.scenarios
        if options.command == "run"
        else SUITE + (IPAD_EXTRA if options.ipad else [])
    )
    repeat(options.runs, lambda: scenarios(device, names, options.ipad))


if __name__ == "__main__":
    main()
