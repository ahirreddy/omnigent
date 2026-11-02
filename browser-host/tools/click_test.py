#!/usr/bin/env python3
"""Clicks land reliably right after load: N times, create a tab on a page that is one big
button, attach, wait for load and the first frame, take control, click at once and expect the
page to react. Also checks that a down without modifier bit 6 still clicks.

    click_test.py --host BIN [--encoder PATH] [--runs 20] [--keep-profile]
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
from rb_client import AttachClient, AttachState

PAGE = Path(__file__).resolve().parent.parent / "tests" / "pages" / "click.html"


def loaded(state: AttachState) -> bool:
    nav = state.last("nav") or {}
    return nav.get("title") == "One" and nav.get("loading") is False and bool(state.frames)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--host", required=True)
    parser.add_argument("--encoder")
    parser.add_argument("--headless-mode", choices=["ozone", "xvfb"])
    parser.add_argument("--runs", type=int, default=20)
    parser.add_argument("--settle", type=float, default=0, help="seconds to wait before clicking")
    parser.add_argument("--out", help="work directory (default: a temporary one, removed after)")
    args = parser.parse_args()
    out = Path(args.out) if args.out else Path(tempfile.mkdtemp(prefix="rb-click-"))
    out.mkdir(parents=True, exist_ok=True)
    host = Host(args, out, None)
    failures = 0
    try:
        for run in range(args.runs):
            tab = host.control.request(
                "tabs.create", {"session_id": "click", "url": PAGE.as_uri(), "created_by": "user"}
            )
            viewer = AttachClient(str(host.socket), tab["id"], mode="control")
            viewer.wait_for(loaded, 20, "load and the first frame")
            viewer.send({"type": "control", "op": "take"})
            viewer.wait_for(lambda s: (s.last("control") or {}).get("holder") == "this", 5, "take")
            viewer.pump(args.settle)
            # Every other run omits the left-button modifier bit on the down.
            modifiers = 64 if run % 2 == 0 else 0
            for kind, mods in (("move", 0), ("down", modifiers), ("up", 0)):
                viewer.send(
                    {
                        "type": "mouse",
                        "kind": kind,
                        "x": 100,
                        "y": 100,
                        "button": "left",
                        "clicks": 1,
                        "modifiers": mods,
                    }
                )
            started = time.monotonic()
            try:
                viewer.wait_for(
                    lambda s: (s.last("nav") or {}).get("title") == "Clicked", 3, "the click"
                )
                print(
                    f"run {run}: clicked after {(time.monotonic() - started) * 1000:.0f} ms "
                    f"(modifiers {modifiers})"
                )
            except Exception as error:  # noqa: BLE001 - reported and counted as a failure
                failures += 1
                print(f"run {run}: FAIL ({error}; modifiers {modifiers})")
            viewer.close()
            host.control.request("tabs.close", {"tab_id": tab["id"]})
    finally:
        host.stop()
        if not args.out:
            shutil.rmtree(out)
    print(f"{args.runs - failures}/{args.runs} clicks landed")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
