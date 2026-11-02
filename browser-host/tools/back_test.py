#!/usr/bin/env python3
"""Back repaints: with several leftover tabs open on one site, follow a link in a fresh tab, go
back, and expect the latest frame to show the first page again. Frames are JPEG so macOS can
decode them with sips (no ffmpeg needed).

    back_test.py --host BIN [--encoder PATH] [--leftover 8] [--runs 5]
"""

from __future__ import annotations

import argparse
import functools
import http.server
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from m0_bench import Host
from rb_client import AttachClient, AttachState

PAGES = Path(__file__).resolve().parent.parent / "tests" / "pages"


def loaded(title: str):
    def predicate(state: AttachState) -> bool:
        nav = state.last("nav") or {}
        return nav.get("title") == title and nav.get("loading") is False and bool(state.frames)

    return predicate


def serve_pages() -> tuple[http.server.ThreadingHTTPServer, str]:
    handler = functools.partial(QuietHandler, directory=str(PAGES))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


def pixel(jpeg: bytes, work: Path, x: int, y: int) -> tuple[int, int, int]:
    """Decodes `jpeg` with sips and returns the RGB value at (x, y)."""
    source, bitmap = work / "frame.jpg", work / "frame.bmp"
    source.write_bytes(jpeg)
    subprocess.run(
        ["sips", "-s", "format", "bmp", str(source), "--out", str(bitmap)],
        capture_output=True,
        check=True,
    )
    data = bitmap.read_bytes()
    offset, width, height, bits = (
        struct.unpack_from("<I", data, 10)[0],
        *struct.unpack_from("<ii", data, 18),
        struct.unpack_from("<H", data, 28)[0],
    )
    channels = bits // 8
    row = (width * channels + 3) & ~3
    top_down = height < 0
    line = y if top_down else abs(height) - 1 - y
    start = offset + line * row + x * channels
    blue, green, red = data[start], data[start + 1], data[start + 2]
    return red, green, blue


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format: str, *args: object) -> None:
        pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--host", required=True)
    parser.add_argument("--encoder")
    parser.add_argument("--headless-mode", choices=["ozone", "xvfb"])
    parser.add_argument("--leftover", type=int, default=8, help="extra tabs open on the site")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--out", help="work directory (default: a temporary one, removed after)")
    args = parser.parse_args()
    out = Path(args.out) if args.out else Path(tempfile.mkdtemp(prefix="rb-back-"))
    out.mkdir(parents=True, exist_ok=True)
    server, origin = serve_pages()
    host = Host(args, out, None)
    failures = 0
    try:
        for _ in range(args.leftover):
            host.control.request(
                "tabs.create",
                {"session_id": "back", "url": f"{origin}/click.html", "created_by": "user"},
            )
        for run in range(args.runs):
            tab = host.control.request(
                "tabs.create",
                {"session_id": "back", "url": f"{origin}/click.html", "created_by": "user"},
            )
            viewer = AttachClient(str(host.socket), tab["id"], mode="control")
            try:
                viewer.send({"type": "settings", "codec": "jpeg"})
                viewer.wait_for(loaded("One"), 20, "the first page")
                viewer.send({"type": "control", "op": "take"})
                viewer.wait_for(
                    lambda s: (s.last("control") or {}).get("holder") == "this", 5, "take"
                )
                viewer.send({"type": "nav", "op": "navigate", "url": f"{origin}/smoke.html"})
                viewer.wait_for(loaded("smoke"), 20, "the second page")
                viewer.pump(1)
                if pixel(viewer.state.frames[-1].payload, out, 100, 100)[0] < 200:
                    raise RuntimeError("the second page is not on screen before back")
                viewer.send({"type": "nav", "op": "back"})
                viewer.wait_for(loaded("One"), 20, "back to the first page")
                viewer.pump(2)
                red, green, blue = pixel(viewer.state.frames[-1].payload, out, 100, 100)
                if not all(abs(channel - 239) <= 12 for channel in (red, green, blue)):
                    raise RuntimeError(
                        f"the first page's grey button is not on screen ({red}, {green}, {blue})"
                    )
                print(f"run {run}: repainted after back ({red}, {green}, {blue})")
            except Exception as error:  # noqa: BLE001 - reported and counted as a failure
                failures += 1
                nav, last_error = viewer.state.last("nav"), viewer.state.last("error")
                print(f"run {run}: FAIL ({error}; nav {nav}; error {last_error})")
            finally:
                viewer.close()
                host.control.request("tabs.close", {"tab_id": tab["id"]})
    finally:
        host.stop()
        server.shutdown()
        if not args.out:
            shutil.rmtree(out)
    print(f"{args.runs - failures}/{args.runs} back navigations repainted")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
