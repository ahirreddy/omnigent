#!/usr/bin/env python3
"""End-to-end smoke test of omnigent-browser-host (the M1 host exit criteria).

Starts the host, creates a tab on tests/pages/smoke.html, attaches in control mode and checks:
setup order and an IDR first; an idle page encodes nothing; a click and typing change the page
(nav title and new frames); the saved stream decodes with ffmpeg to the expected pixels; closing
the tab sends tab_closed and close 4404; host.shutdown exits cleanly and removes host.json.

    smoke_test.py --host build/host/omnigent-browser-host [--encoder PATH] [--ffmpeg PATH]
                  [--headless-mode ozone|xvfb] [--keep DIR]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import itertools

from rb_client import AttachClient, AttachState, ControlClient, HostError, h264_stream

PAGE = Path(__file__).resolve().parent.parent / "tests" / "pages" / "smoke.html"
WIDTH, HEIGHT = 1280, 800


class SmokeFailure(AssertionError):
    """A failed smoke check."""


def check(condition: bool, message: str) -> None:
    if not condition:
        raise SmokeFailure(message)
    print(f"  ok: {message}")


def wait_for_file(path: Path, process: subprocess.Popen[bytes], timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while not path.exists():
        if process.poll() is not None:
            raise SmokeFailure(f"the host exited with {process.returncode} before writing {path}")
        if time.monotonic() > deadline:
            raise SmokeFailure(f"{path} did not appear within {timeout} s")
        time.sleep(0.1)


def title_is(expected: str):
    def predicate(state: AttachState) -> bool:
        nav = state.last("nav")
        return nav is not None and nav.get("title") == expected

    return predicate


def decode_rgb(ffmpeg: str, stream: Path) -> list[bytes]:
    result = subprocess.run(
        [
            ffmpeg,
            "-v",
            "error",
            "-f",
            "h264",
            "-i",
            str(stream),
            "-fps_mode",
            "passthrough",
            "-f",
            "rawvideo",
            "-pix_fmt",
            "rgb24",
            "-",
        ],
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise SmokeFailure(f"ffmpeg failed to decode {stream}: {result.stderr.decode()}")
    size = WIDTH * HEIGHT * 3
    data = result.stdout
    if len(data) % size != 0:
        raise SmokeFailure(
            f"decoded {len(data)} bytes, not a whole number of {WIDTH}x{HEIGHT} frames"
        )
    return [data[offset : offset + size] for offset in range(0, len(data), size)]


def pixel(frame: bytes, x: int, y: int) -> tuple[int, int, int]:
    offset = (y * WIDTH + x) * 3
    return frame[offset], frame[offset + 1], frame[offset + 2]


def near(color: tuple[int, int, int], expected: tuple[int, int, int], tolerance: int = 24) -> bool:
    return all(abs(a - b) <= tolerance for a, b in zip(color, expected, strict=True))


def run(args: argparse.Namespace, work: Path) -> dict[str, object]:
    profile_dir = work / "profiles" / "smoke"
    # sun_path is 104 bytes on macOS, so the socket lives in its own short directory.
    socket_dir = Path(tempfile.mkdtemp(prefix="rb-"))
    socket_path = socket_dir / "host.sock"
    command = [
        args.host,
        "--profile",
        "smoke",
        "--profile-dir",
        str(profile_dir),
        "--socket",
        str(socket_path),
        "--idle-exit-seconds",
        "120",
    ]
    if args.encoder:
        command += ["--encoder", args.encoder]
    if args.headless_mode:
        command += ["--headless-mode", args.headless_mode]
    log_path = work / "host.log"
    log = log_path.open("wb")
    print("starting", " ".join(command))
    host = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
    report: dict[str, object] = {}
    try:
        wait_for_file(profile_dir / "host.json", host, 60)
        state_file = json.loads((profile_dir / "host.json").read_text())
        check(state_file["pid"] == host.pid, "host.json names the host pid")
        check(state_file["cdp_port"] > 0, f"CDP port {state_file['cdp_port']} is in host.json")
        check(oct((profile_dir).stat().st_mode & 0o777) == "0o700", "profile dir is 0700")
        check(oct(socket_path.stat().st_mode & 0o777) == "0o600", "host.sock is 0600")

        control = ControlClient(str(socket_path))
        health = control.request("health")
        check(health["profile"] == "smoke", "health answers")
        tab = control.request(
            "tabs.create",
            {
                "session_id": "smoke",
                "url": PAGE.as_uri(),
                "created_by": "user",
                "width": WIDTH,
                "height": HEIGHT,
            },
        )
        check(tab["id"].startswith("btab_") and tab["target_id"] != "", "tab has a CDP target id")
        tab_id = tab["id"]

        viewer = AttachClient(str(socket_path), tab_id, mode="control")
        viewer.wait_for(lambda s: len(s.frames) >= 1, 20, "the first frame")
        types = [m["type"] for m in viewer.state.messages]
        check(
            types[:6] == ["hello", "control", "viewport", "nav", "cursor", "text_input"],
            f"setup order {types[:6]}",
        )
        first = viewer.state.frames[0]
        check(
            first.kind == 1 and first.keyframe and bool(first.flags & 2) and first.seq == 1,
            "first media frame is an IDR with new_stream and seq 1",
        )
        viewer.wait_for(title_is("smoke"), 20, "the page title")
        viewer.wait_for(lambda s: (s.last("nav") or {}).get("loading") is False, 20, "load end")

        # Idle: after the page settles, nothing is encoded.
        viewer.pump(1.5)
        before = len(viewer.state.frames)
        viewer.pump(2.0)
        idle_frames = len(viewer.state.frames) - before
        check(idle_frames == 0, f"idle page encoded {idle_frames} frames in 2 s")
        report["idle_frames_2s"] = idle_frames

        # Take control, click the button, type into the field.
        viewer.send({"type": "control", "op": "take"})
        viewer.wait_for(
            lambda s: (s.last("control") or {}).get("holder") == "this", 5, "control take"
        )
        viewer.pump(0.5)
        frames_before_click = len(viewer.state.frames)
        click_time = time.monotonic()
        viewer.click(200, 440)
        viewer.wait_for(title_is("clicked"), 10, "the click to change the title")
        viewer.wait_for(
            lambda s: any(f.received_at > click_time for f in s.frames[frames_before_click:]),
            10,
            "a frame after the click",
        )
        first_after = next(
            f for f in viewer.state.frames[frames_before_click:] if f.received_at > click_time
        )
        report["click_to_frame_ms"] = round((first_after.received_at - click_time) * 1000, 1)
        check(True, f"a frame arrived {report['click_to_frame_ms']} ms after the click")
        viewer.click(750, 440)
        viewer.type_text("hello")
        viewer.wait_for(title_is("typed:hello"), 10, "typing to change the title")
        check(True, "typing reached the page")
        cursor = viewer.state.last("cursor") or {}
        check(cursor.get("cursor") == "text", f"cursor over the field is text ({cursor})")
        text_input = viewer.state.last("text_input") or {}
        report["text_input"] = text_input
        check(
            text_input.get("mode") == "text", f"focusing the field sends text_input ({text_input})"
        )

        # A JavaScript confirm() while the user holds control is forwarded and answered.
        viewer.click(200, 590)
        viewer.wait_for(lambda s: s.last("dialog") is not None, 10, "the confirm dialog")
        dialog = viewer.state.last("dialog") or {}
        check(
            dialog.get("kind") == "confirm" and dialog.get("message") == "Proceed?",
            f"dialog message {dialog}",
        )
        viewer.send({"type": "dialog_reply", "id": dialog["id"], "accept": True})
        viewer.wait_for(title_is("confirm:true"), 10, "the dialog reply")
        check(viewer.state.last("dialog_closed") is not None, "dialog_closed arrived")

        # target=_blank opens a new host tab in the same session.
        viewer.click(650, 572)
        deadline = time.monotonic() + 10
        popup_tabs: list[dict[str, object]] = []
        while time.monotonic() < deadline and not popup_tabs:
            viewer.pump(0.3)
            popup_tabs = [
                t
                for t in control.request("tabs.list", {"session_id": "smoke"})["tabs"]
                if t["id"] != tab_id
            ]
        check(len(popup_tabs) == 1, f"the popup became a host tab ({popup_tabs})")
        viewer.pump(1.0)

        stats = control.request("tabs.stats", {"tab_id": tab_id})
        report["stats"] = stats
        frames = viewer.state.frames
        report["frames"] = len(frames)
        report["keyframes"] = sum(1 for f in frames if f.keyframe)
        report["bytes"] = sum(len(f.payload) for f in frames)
        check(all(b.seq == a.seq + 1 for a, b in itertools.pairwise(frames)), "seq is contiguous")
        stream_ids = [f.stream_id for f in frames]
        check(stream_ids == sorted(stream_ids), "stream_id never goes backwards")

        stream_path = work / "smoke.h264"
        stream_path.write_bytes(h264_stream(frames))
        report["stream"] = str(stream_path)
        if args.ffmpeg:
            decoded = decode_rgb(args.ffmpeg, stream_path)
            check(len(decoded) == len(frames), f"ffmpeg decoded all {len(frames)} frames")
            # The first IDR can predate the page's first paint; the last frame before the click
            # must show the page.
            before_click = decoded[frames_before_click - 1]
            check(
                near(pixel(before_click, 200, 150), (255, 0, 0)),
                "the frame before the click shows the red block",
            )
            check(
                near(pixel(decoded[-1], 200, 150), (0, 0, 255)), "last frame shows the blue block"
            )
            check(near(pixel(decoded[-1], 1100, 700), (255, 255, 255)), "background is white")
        else:
            print("  skip: no ffmpeg for decoding (pass --ffmpeg)")

        # Closing the tab ends the attach with tab_closed and 4404.
        control.request("tabs.close", {"tab_id": tab_id})
        viewer.wait_for(lambda s: s.closed is not None, 10, "the attach to close")
        check(viewer.state.last("tab_closed") is not None, "tab_closed arrived")
        check(viewer.state.closed is not None and viewer.state.closed.code == 4404, "close 4404")
        viewer.close()

        missing = AttachClient(str(socket_path), "btab_missing", mode="view")
        missing.pump(3)
        check(
            missing.state.closed is not None and missing.state.closed.code == 4404,
            "an unknown tab closes with 4404",
        )
        missing.close()

        control.request("host.shutdown")
        control.close()
        host.wait(timeout=20)
        check(host.returncode == 0, f"host exited with {host.returncode}")
        check(not (profile_dir / "host.json").exists(), "host.json was removed")
    finally:
        if host.poll() is None:
            host.terminate()
            try:
                host.wait(timeout=10)
            except subprocess.TimeoutExpired:
                host.kill()
        log.close()
        shutil.rmtree(socket_dir, ignore_errors=True)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--host", required=True, help="omnigent-browser-host executable")
    parser.add_argument("--encoder")
    parser.add_argument("--ffmpeg", default=shutil.which("ffmpeg"))
    parser.add_argument("--headless-mode", choices=["ozone", "xvfb"])
    parser.add_argument("--keep", help="keep logs and the stream in this directory")
    args = parser.parse_args()
    work = Path(args.keep) if args.keep else Path(tempfile.mkdtemp(prefix="rb-smoke-"))
    work.mkdir(parents=True, exist_ok=True)
    try:
        report = run(args, work)
    except (SmokeFailure, HostError, OSError) as failure:
        print(f"FAIL: {failure}")
        print(f"host log: {work / 'host.log'}")
        return 1
    print(json.dumps(report, indent=2))
    print(f"PASS (logs and stream in {work})")
    if not args.keep:
        shutil.rmtree(work)
    return 0


if __name__ == "__main__":
    os.umask(0o077)
    sys.exit(main())
