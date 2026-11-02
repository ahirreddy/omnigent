#!/usr/bin/env python3
"""Wheel deltas with client-side momentum against CEF touch events for scrolling a remote page
(design doc section 16.4).

Both methods replay the same flick on tests/pages/v11.html: a 300 CSS px drag over 100 ms
(3000 px/s). `wheel` then continues with UIScrollView's normal deceleration (0.998 per ms)
computed here and sent as one wheel delta per 16 ms frame, as the iOS client does; `touch`
sends touch start, moves and end and lets Chromium fling. For each trial: host process tree CPU
from the first input until the page stops moving, the time from the first input to the first
scroll report and to the first video frame after it, the distance and the motion's duration.

    scroll_bench.py --host BIN [--encoder PATH] [--headless-mode ozone|xvfb] [--trials 5]
"""

from __future__ import annotations

import argparse
import json
import shutil
import statistics
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from m0_bench import Host
from rb_client import AttachClient

# 200 rows, 10320 CSS px tall: long enough that no flick reaches the end.
PAGE = Path(__file__).resolve().parent.parent / "tests" / "pages" / "v11.html"
FRAME_S = 0.016
DRAG_STEPS = 6
DRAG_PX = 50.0
FLICK_PX_PER_S = 3000.0
DECELERATION_PER_MS = 0.998
X, Y = 640.0, 600.0


def scroll_y(viewer: AttachClient) -> float:
    return float((viewer.state.last("scroll") or {}).get("y", 0))


def wheel_flick(viewer: AttachClient) -> None:
    for _ in range(DRAG_STEPS):
        viewer.wheel(X, Y, DRAG_PX)
        viewer.pump(FRAME_S)
    velocity = FLICK_PX_PER_S
    while velocity > 10:
        velocity *= DECELERATION_PER_MS ** (FRAME_S * 1000)
        viewer.wheel(X, Y, velocity * FRAME_S)
        viewer.pump(FRAME_S)


def touch_flick(viewer: AttachClient) -> None:
    def touch(kind: str, y: float) -> None:
        viewer.send({"type": "touch", "kind": kind, "id": 1, "x": X, "y": y, "modifiers": 0})

    touch("start", Y)
    viewer.pump(FRAME_S)
    for step in range(1, DRAG_STEPS + 1):
        touch("move", Y - step * DRAG_PX)
        viewer.pump(FRAME_S)
    touch("end", Y - DRAG_STEPS * DRAG_PX)


def settle(viewer: AttachClient, quiet_s: float = 0.5, limit_s: float = 6.0) -> float:
    """Pumps until the scroll position has not changed for `quiet_s`; returns the last change."""
    last_y = scroll_y(viewer)
    last_change = time.monotonic()
    deadline = time.monotonic() + limit_s
    while time.monotonic() < deadline and time.monotonic() - last_change < quiet_s:
        viewer.pump(0.02)
        if scroll_y(viewer) != last_y:
            last_y = scroll_y(viewer)
            last_change = time.monotonic()
    return last_change


def open_tab(host: Host) -> tuple[str, AttachClient]:
    """A fresh tab per trial: after a touch scroll, CEF ignores wheel events on that tab."""
    tab = host.control.request(
        "tabs.create", {"session_id": "bench", "url": PAGE.as_uri(), "created_by": "user"}
    )
    viewer = AttachClient(str(host.socket), tab["id"], features=["scroll_metrics"])
    stamp_messages(viewer)
    viewer.wait_for(lambda s: (s.last("scroll") or {}).get("content_h", 0) > 5000, 20, "the page")
    viewer.send({"type": "control", "op": "take"})
    viewer.wait_for(lambda s: (s.last("control") or {}).get("holder") == "this", 5, "take")
    settle(viewer)
    return tab["id"], viewer


def trial(host: Host, method: str) -> dict[str, float]:
    tab_id, viewer = open_tab(host)
    y0 = scroll_y(viewer)
    reports = len(viewer.state.messages)
    frames = len(viewer.state.frames)
    before = host.control.request("tabs.stats", {"tab_id": tab_id})
    started = time.monotonic()
    (wheel_flick if method == "wheel" else touch_flick)(viewer)
    stopped = settle(viewer)
    after = host.control.request("tabs.stats", {"tab_id": tab_id})
    first_report = next(
        (
            message
            for message in viewer.state.messages[reports:]
            if message.get("type") == "scroll" and message.get("y") != y0
        ),
        None,
    )
    first_frame = viewer.state.frames[frames] if len(viewer.state.frames) > frames else None
    elapsed = max(stopped - started, 1e-3)
    viewer.close()
    host.control.request("tabs.close", {"tab_id": tab_id})
    cpu = after["host_tree_cpu_s"] - before["host_tree_cpu_s"]
    return {
        "cpu_s": cpu,
        "cpu_core_pct": cpu / elapsed * 100,
        "encoder_cpu_s": after["encoder_cpu_s"] - before["encoder_cpu_s"],
        "frames": after["frames_encoded"] - before["frames_encoded"],
        "first_report_ms": (first_report["_at"] - started) * 1000 if first_report else -1,
        "first_frame_ms": (first_frame.received_at - started) * 1000 if first_frame else -1,
        "distance_px": scroll_y(viewer) - y0,
        "motion_ms": elapsed * 1000,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--host", required=True)
    parser.add_argument("--encoder")
    parser.add_argument("--headless-mode", choices=["ozone", "xvfb"])
    parser.add_argument("--trials", type=int, default=5)
    parser.add_argument("--out", help="work directory (default: a temporary one, removed after)")
    args = parser.parse_args()
    out = Path(args.out) if args.out else Path(tempfile.mkdtemp(prefix="rb-scroll-"))
    out.mkdir(parents=True, exist_ok=True)
    host = Host(args, out, None)
    results: dict[str, list[dict[str, float]]] = {"wheel": [], "touch": []}
    try:
        for _ in range(args.trials):
            for method in ("wheel", "touch"):
                results[method].append(trial(host, method))
    finally:
        host.stop()
        if not args.out:
            shutil.rmtree(out)
    summary = {
        method: {key: round(statistics.median(run[key] for run in runs), 2) for key in runs[0]}
        for method, runs in results.items()
    }
    print(json.dumps({"median_of": args.trials, "summary": summary, "trials": results}, indent=2))
    return 0


def stamp_messages(viewer: AttachClient) -> None:
    """Records each text message's arrival time in `_at`."""
    original = viewer._handle

    def handle(kind: int, payload: bytes) -> None:
        count = len(viewer.state.messages)
        original(kind, payload)
        if len(viewer.state.messages) > count:
            viewer.state.messages[-1]["_at"] = time.monotonic()

    viewer._handle = handle  # type: ignore[method-assign]


if __name__ == "__main__":
    sys.exit(main())
