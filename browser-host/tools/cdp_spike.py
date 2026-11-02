#!/usr/bin/env python3
"""Runs tools/cdp_spike.mjs (Playwright connectOverCDP) against a fresh host and reports which
CDP paths work under CEF Alloy windowless rendering, and whether pages Playwright opens become
host tabs that stream.

    cdp_spike.py --host BIN --node-modules DIR [--encoder PATH] [--out DIR]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from m0_bench import Host
from rb_client import AttachClient

PAGE = Path(__file__).resolve().parent.parent / "tests" / "pages" / "smoke.html"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--host", required=True)
    parser.add_argument("--node-modules", required=True, help="dir with playwright-core installed")
    parser.add_argument("--encoder")
    parser.add_argument("--headless-mode", choices=["ozone", "xvfb"])
    parser.add_argument("--idle-frame-rate", type=int)
    parser.add_argument("--out", default=tempfile.mkdtemp(prefix="rb-cdp-"))
    args = parser.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    host = Host(args, out, None)
    try:
        cdp_port = host.control.request("health")["cdp_port"]
        tab = host.control.request(
            "tabs.create", {"session_id": "spike", "url": "about:blank", "created_by": "agent"}
        )
        print(json.dumps({"check": "host_tab", "id": tab["id"], "target_id": tab["target_id"]}))
        env = dict(os.environ, NODE_PATH=args.node_modules)
        script = Path(__file__).resolve().parent / "cdp_spike.mjs"
        local = Path(args.node_modules).parent / "cdp_spike.mjs"
        local.write_text(script.read_text())  # ESM resolves imports next to the script.
        run = subprocess.run(
            ["node", str(local), str(cdp_port), PAGE.as_uri(), str(out)],
            capture_output=True,
            text=True,
            timeout=180,
            env=env,
            check=False,
        )
        print(run.stdout, end="")
        if run.returncode != 0:
            print(json.dumps({"check": "node", "ok": False, "stderr": run.stderr[-800:]}))
        time.sleep(1)
        tabs = host.control.request("tabs.list")["tabs"]
        print(
            json.dumps(
                {
                    "check": "host_tabs_after",
                    "tabs": [
                        {
                            "id": t["id"],
                            "url": t["url"],
                            "session_id": t["session_id"],
                            "target_id": t["target_id"],
                        }
                        for t in tabs
                    ],
                }
            )
        )
        for item in tabs:
            if item["id"] == tab["id"]:
                continue
            viewer = AttachClient(str(host.socket), item["id"], mode="view")
            state = viewer.pump(4)
            print(
                json.dumps(
                    {
                        "check": "playwright_page_streams",
                        "tab": item["id"],
                        "url": item["url"],
                        "frames": len(state.frames),
                        "first_keyframe": bool(state.frames and state.frames[0].keyframe),
                    }
                )
            )
            viewer.close()
    finally:
        host.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
