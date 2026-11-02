#!/usr/bin/env python3
"""Host CPU with tabs open and nobody watching (and with one idle viewer).

idle_cpu.py --host BIN [--headless-mode ozone|xvfb] [--seconds 20] [--tabs 3]
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from m0_bench import Host
from rb_client import AttachClient

PAGE = Path(__file__).resolve().parent.parent / "tests" / "pages" / "bench" / "static.html"


def tree_cpu(host: Host, tab_id: str) -> float:
    return host.control.request("tabs.stats", {"tab_id": tab_id})["host_tree_cpu_s"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--host", required=True)
    parser.add_argument("--encoder")
    parser.add_argument("--headless-mode", choices=["ozone", "xvfb"])
    parser.add_argument("--seconds", type=float, default=20)
    parser.add_argument("--tabs", type=int, default=3)
    parser.add_argument("--idle-frame-rate", type=int, default=30)
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix="rb-idle-"))
    host = Host(args, work, None)
    try:
        ids = [
            host.control.request(
                "tabs.create", {"session_id": "idle", "url": PAGE.as_uri(), "created_by": "agent"}
            )["id"]
            for _ in range(args.tabs)
        ]
        time.sleep(5)  # Let the pages load and settle.
        before = tree_cpu(host, ids[0])
        time.sleep(args.seconds)
        unwatched = (tree_cpu(host, ids[0]) - before) / args.seconds * 100
        viewer = AttachClient(str(host.socket), ids[0], mode="view")
        viewer.pump(3)
        before = tree_cpu(host, ids[0])
        frames_before = len(viewer.state.frames)
        viewer.pump(args.seconds)
        watched = (tree_cpu(host, ids[0]) - before) / args.seconds * 100
        print(
            json.dumps(
                {
                    "headless_mode": args.headless_mode or "default",
                    "tabs": args.tabs,
                    "idle_frame_rate": args.idle_frame_rate,
                    "unwatched_core_pct": round(unwatched, 2),
                    "one_idle_viewer_core_pct": round(watched, 2),
                    "frames_while_idle": len(viewer.state.frames) - frames_before,
                }
            )
        )
        viewer.close()
    finally:
        host.stop()
        shutil.rmtree(work)
    return 0


if __name__ == "__main__":
    sys.exit(main())
