#!/usr/bin/env python3
"""Starts and stops omnigent-browser-host repeatedly, creating and attaching tabs each time, and
fails on any host crash: an unclean exit, or (on macOS) a new crash report in
~/Library/Logs/DiagnosticReports. Launch races show up here, not in single runs.

    soak_test.py --host BIN [--encoder PATH] [--launches 20] [--tabs 3]
"""

from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from m0_bench import Host
from rb_client import AttachClient

PAGE = Path(__file__).resolve().parent.parent / "tests" / "pages" / "v11.html"
REPORTS = Path.home() / "Library" / "Logs" / "DiagnosticReports"


def crash_reports() -> set[str]:
    if not REPORTS.is_dir():
        return set()
    return {path.name for path in REPORTS.glob("omnigent-browser-host*")}


def one_launch(args: argparse.Namespace, work: Path) -> None:
    host = Host(args, work, None)
    try:
        for index in range(args.tabs):
            tab = host.control.request(
                "tabs.create",
                {"session_id": f"soak{index}", "url": PAGE.as_uri(), "created_by": "user"},
            )
            viewer = AttachClient(str(host.socket), tab["id"], features=["scroll_metrics"])
            viewer.wait_for(lambda s: bool(s.frames), 30, "the first frame")
            viewer.send({"type": "control", "op": "take"})
            viewer.wheel(640, 400, 300)
            viewer.pump(0.3)
            viewer.close()
    finally:
        host.stop()
    if host.process.returncode != 0:
        raise RuntimeError(f"the host exited with {host.process.returncode}; see {work}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--host", required=True)
    parser.add_argument("--encoder")
    parser.add_argument("--headless-mode", choices=["ozone", "xvfb"])
    parser.add_argument("--launches", type=int, default=20)
    parser.add_argument("--tabs", type=int, default=3)
    args = parser.parse_args()
    before = crash_reports()
    failures = 0
    for launch in range(args.launches):
        work = Path(tempfile.mkdtemp(prefix="rb-soak-"))
        started = time.monotonic()
        try:
            one_launch(args, work)
            print(f"launch {launch}: ok in {time.monotonic() - started:.1f} s")
            shutil.rmtree(work)
        except Exception as error:  # noqa: BLE001 - counted, reported and kept for inspection
            failures += 1
            print(f"launch {launch}: FAIL {error}")
    new_reports = sorted(crash_reports() - before)
    for name in new_reports:
        print(f"new crash report: {REPORTS / name}")
    print(f"{args.launches - failures}/{args.launches} launches clean, {len(new_reports)} crashes")
    return 0 if failures == 0 and not new_reports else 1


if __name__ == "__main__":
    sys.exit(main())
