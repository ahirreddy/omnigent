#!/usr/bin/env python3
"""M0 bench for omnigent-browser-host (design doc section 12, "M0 bench").

For each scenario (static, typing, scroll, fling, video, login) and viewport it runs the host
and drives the page through the real input path, then measures:

- render: Chromium's software rendering CPU (host process tree, no encoder), at the 30 fps cap;
- live: the whole pipeline with a visible viewer (render + conversion + encoder + socket);
- record: a raw BGRA recording, replayed by rb_encode_bench at 5, 15 and 30 fps for per-frame
  encoder cost, bitrate and, where ffmpeg is available, SSIM (full frame and a text crop).

    m0_bench.py --host BIN --bench BIN --out DIR [--encoder PATH] [--video FILE]
                [--headless-mode ozone|xvfb] [--viewports 1280x720,1920x1080]
                [--scenarios static,typing,...] [--phases render,live,record,encode]
                [--seconds 8] [--ffmpeg PATH]

Results are appended to DIR/results.jsonl, one JSON object per measurement.
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
from collections.abc import Callable
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rb_client import AttachClient, ControlClient, HostError

PAGES = Path(__file__).resolve().parent.parent / "tests" / "pages" / "bench"
SCENARIOS = ["static", "typing", "scroll", "fling", "video", "login"]
PAGE_FOR = {
    "static": "static",
    "typing": "typing",
    "scroll": "scroll",
    "fling": "scroll",
    "video": "video",
    "login": "login",
}
TYPING_TEXT = (
    "The remote browser streams damage-driven H.264 to the client while the agent works. "
    "Typing should cost a few rows per frame, not a whole frame. "
)


class Host:
    """One omnigent-browser-host process with a private profile and socket."""

    def __init__(self, args: argparse.Namespace, work: Path, record_dir: Path | None) -> None:
        self.socket_dir = Path(tempfile.mkdtemp(prefix="rb-bench-"))
        self.profile_dir = work / "profile"
        self.socket = self.socket_dir / "host.sock"
        command = [
            args.host,
            "--profile-dir",
            str(self.profile_dir),
            "--socket",
            str(self.socket),
            "--idle-exit-seconds",
            "0",
        ]
        if args.encoder:
            command += ["--encoder", args.encoder]
        if args.headless_mode:
            command += ["--headless-mode", args.headless_mode]
        if record_dir is not None:
            command += ["--record-dir", str(record_dir)]
        if getattr(args, "idle_frame_rate", None):
            command += ["--idle-frame-rate", str(args.idle_frame_rate)]
        self.log = (work / "host.log").open("ab")
        self.process = subprocess.Popen(command, stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 60
        while not (self.profile_dir / "host.json").exists():
            if self.process.poll() is not None or time.monotonic() > deadline:
                raise HostError(f"host did not start; see {work / 'host.log'}")
            time.sleep(0.1)
        self.control = ControlClient(str(self.socket))

    def stop(self) -> None:
        try:
            self.control.request("host.shutdown")
            self.control.close()
            self.process.wait(timeout=30)
        finally:
            if self.process.poll() is None:
                self.process.kill()
            self.log.close()
            shutil.rmtree(self.socket_dir, ignore_errors=True)


def drive(scenario: str, viewer: AttachClient, width: int, height: int, seconds: float) -> None:
    """Injects the scenario's input for `seconds` (pumping the connection meanwhile)."""
    end = time.monotonic() + seconds
    center_x, center_y = width / 2, height / 2
    if scenario == "typing":
        index = 0
        while time.monotonic() < end:
            viewer.type_text(TYPING_TEXT[index % len(TYPING_TEXT)])
            index += 1
            viewer.pump(0.1)  # About 10 characters per second.
    elif scenario == "scroll":
        while time.monotonic() < end:
            viewer.wheel(center_x, center_y, 60)
            viewer.pump(0.05)
    elif scenario == "fling":
        burst = 0
        while time.monotonic() < end:
            direction = -1 if burst % 4 == 3 else 1  # Mostly down, sometimes back up.
            for _ in range(12):
                viewer.wheel(center_x, center_y, 320 * direction)
                viewer.pump(0.016)
            viewer.pump(0.35)
            burst += 1
    elif scenario == "login":
        viewer.type_text("agent@example.com")
        viewer.press("Tab", "Tab", None)
        viewer.type_text("hunter2-secret")
        viewer.press("Enter", "Enter", "\r")
        while time.monotonic() < end:
            viewer.pump(0.1)
    else:
        while time.monotonic() < end:
            viewer.pump(0.1)


def measure(
    host: Host,
    scenario: str,
    width: int,
    height: int,
    seconds: float,
    visible: bool,
    before_drive: Callable[[str], None] | None = None,
) -> dict[str, Any]:
    page = (PAGES / f"{PAGE_FOR[scenario]}.html").as_uri()
    tab = host.control.request(
        "tabs.create",
        {
            "session_id": "bench",
            "url": page,
            "created_by": "user",
            "width": width,
            "height": height,
        },
    )
    tab_id = tab["id"]
    viewer = AttachClient(str(host.socket), tab_id, mode="control", visible=visible)
    viewer.wait_for(
        lambda s: (
            (s.last("nav") or {}).get("loading") is False
            and (s.last("nav") or {}).get("title", "").startswith("bench")
        ),
        30,
        "load",
    )
    viewer.send({"type": "control", "op": "take"})
    viewer.wait_for(lambda s: (s.last("control") or {}).get("holder") == "this", 5, "take")
    if scenario == "video":
        viewer.wait_for(
            lambda s: (s.last("nav") or {}).get("title") == "bench-video-playing",
            20,
            "video playing",
        )
    viewer.pump(1.5)  # Let the first paint and the IDR settle.
    if before_drive is not None:
        before_drive(tab_id)
    start = host.control.request("tabs.stats", {"tab_id": tab_id})
    frames_before = len(viewer.state.frames)
    bytes_before = sum(len(f.payload) for f in viewer.state.frames)
    started = time.monotonic()
    drive(scenario, viewer, width, height, seconds)
    elapsed = time.monotonic() - started
    end = host.control.request("tabs.stats", {"tab_id": tab_id})
    if before_drive is not None:
        recorded = host.control.request("tabs.record_stop", {"tab_id": tab_id})["frames"]
    else:
        recorded = None
    frames = viewer.state.frames[frames_before:]
    host_cpu = end["host_tree_cpu_s"] - start["host_tree_cpu_s"]
    encoder_cpu = end["encoder_cpu_s"] - start["encoder_cpu_s"]
    result = {
        "scenario": scenario,
        "width": width,
        "height": height,
        "seconds": round(elapsed, 2),
        "host_tree_cpu_core_pct": round(host_cpu / elapsed * 100, 1),
        "encoder_cpu_core_pct": round(encoder_cpu / elapsed * 100, 1),
        "render_cpu_core_pct": round((host_cpu - encoder_cpu) / elapsed * 100, 1),
        "frames": len(frames),
        "fps": round(len(frames) / elapsed, 1),
        "kbps": round(
            (sum(len(f.payload) for f in viewer.state.frames) - bytes_before) * 8 / 1000 / elapsed,
            1,
        ),
        "keyframe_mode": end["keyframe_mode"],
        "rss_mb": round(end.get("host_tree_rss_bytes", 0) / 1e6),
    }
    if recorded is not None:
        result["recorded_frames"] = recorded
    if scenario == "login":
        result["login_done"] = (viewer.state.last("nav") or {}).get("title") == "bench-login-done"
    viewer.close()
    host.control.request("tabs.close", {"tab_id": tab_id})
    return result


def ssim(
    ffmpeg: str, stream: Path, reference: Path, width: int, height: int, crop: str | None
) -> tuple[float, float] | None:
    """(mean SSIM, last-frame SSIM) of the decoded stream against the encoder's input."""
    with tempfile.NamedTemporaryFile(suffix=".log") as stats:
        measure_filter = f"ssim=stats_file={stats.name}"
        # Pair frames by index: the H.264 stream carries its own frame rate in the VUI, which
        # would otherwise misalign it against the raw reference.
        align = "settb=AVTB,setpts=N/25/TB"
        crop_step = "" if crop is None else f",{crop}"
        graph = f"[0:v]{align}{crop_step}[a];[1:v]{align}{crop_step}[b];[a][b]{measure_filter}"
        result = subprocess.run(
            [
                ffmpeg,
                "-v",
                "info",
                "-f",
                "h264",
                "-i",
                str(stream),
                "-f",
                "rawvideo",
                "-pix_fmt",
                "yuv420p",
                "-s",
                f"{width}x{height}",
                "-i",
                str(reference),
                "-lavfi",
                graph,
                "-f",
                "null",
                "-",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        lines = Path(stats.name).read_text().splitlines()
    if result.returncode != 0 or not lines:
        print(f"  ssim failed: {result.stderr[-400:]}")
        return None
    values = [float(line.split("All:")[1].split()[0]) for line in lines if "All:" in line]
    return sum(values) / len(values), values[-1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--host", required=True)
    parser.add_argument("--bench", required=True, help="rb_encode_bench binary")
    parser.add_argument("--out", required=True)
    parser.add_argument("--encoder")
    parser.add_argument("--video", help="VP9 WebM for the video scenario")
    parser.add_argument("--headless-mode", choices=["ozone", "xvfb"])
    parser.add_argument("--viewports", default="1280x720,1920x1080")
    parser.add_argument("--scenarios", default=",".join(SCENARIOS))
    parser.add_argument("--phases", default="render,live,record,encode")
    parser.add_argument("--seconds", type=float, default=8)
    parser.add_argument("--fps", default="5,15,30")
    parser.add_argument("--ffmpeg", default=shutil.which("ffmpeg"))
    parser.add_argument("--label", default="")
    parser.add_argument("--vbv-frames", default="2", help="comma list for the encode phase")
    parser.add_argument("--refine", default="0", help="comma list of refinement frame counts")
    parser.add_argument("--recordings", help="glob of recordings to encode (default: all)")
    args = parser.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    if args.video:
        shutil.copy(args.video, PAGES / "video.webm")
    results = (out / "results.jsonl").open("a")
    phases = args.phases.split(",")
    scenarios = args.scenarios.split(",")
    viewports = [tuple(int(v) for v in item.split("x")) for item in args.viewports.split(",")]
    record_dir = out / "recordings"
    record_dir.mkdir(exist_ok=True)

    def emit(entry: dict[str, Any]) -> None:
        entry["label"] = args.label
        entry["headless_mode"] = args.headless_mode or "default"
        results.write(json.dumps(entry) + "\n")
        results.flush()
        print(json.dumps(entry))

    for phase in ("render", "live", "record"):
        if phase not in phases:
            continue
        host = Host(args, out, record_dir if phase == "record" else None)
        try:
            for width, height in viewports:
                for scenario in scenarios:
                    if scenario == "video" and not (PAGES / "video.webm").exists():
                        continue
                    name = f"{scenario}_{width}x{height}.bgra"

                    def start_recording(tab_id: str, name: str = name, host: Host = host) -> None:
                        host.control.request(
                            "tabs.record",
                            {
                                "tab_id": tab_id,
                                "name": name,
                                "max_frames": int(args.seconds * 30) + 30,
                            },
                        )

                    result = measure(
                        host,
                        scenario,
                        width,
                        height,
                        args.seconds,
                        visible=phase == "live",
                        before_drive=start_recording if phase == "record" else None,
                    )
                    result["phase"] = phase
                    emit(result)
        finally:
            host.stop()

    if "encode" in phases:
        pattern = args.recordings or "*.bgra"
        variants = [
            (int(fps), float(vbv), int(refine))
            for fps in args.fps.split(",")
            for vbv in args.vbv_frames.split(",")
            for refine in args.refine.split(",")
        ]
        for recording in sorted(record_dir.glob(pattern)):
            scenario, size = recording.stem.split("_")
            width, height = (int(v) for v in size.split("x"))
            for fps, vbv, refine in variants:
                tag = f"{recording.stem}_{fps}_v{vbv:g}_r{refine}"
                stream = out / f"{tag}.h264"
                reference = out / f"{tag}.yuv"
                command = [
                    args.bench,
                    "--input",
                    str(recording),
                    "--fps",
                    str(fps),
                    "--out",
                    str(stream),
                    "--vbv-frames",
                    str(vbv),
                    "--refine",
                    str(refine),
                ]
                if args.encoder:
                    command += ["--encoder", args.encoder]
                if args.ffmpeg:
                    command += ["--yuv-out", str(reference)]
                run = subprocess.run(command, capture_output=True, text=True, check=False)
                if run.returncode != 0:
                    print(f"  encode bench failed for {recording.name}: {run.stderr[-400:]}")
                    continue
                entry = json.loads(run.stdout.strip().splitlines()[-1])
                entry.update({"phase": "encode", "scenario": scenario})
                if args.ffmpeg and reference.exists():
                    full = ssim(args.ffmpeg, stream, reference, width, height, None)
                    # Dense text in the article column: a 640x360 crop near the top left.
                    crop = f"crop=640:360:{(width - 900) // 2 + 24}:24"
                    text = ssim(args.ffmpeg, stream, reference, width, height, crop)
                    if full is not None and text is not None:
                        entry["ssim"], entry["ssim_last"] = full
                        entry["ssim_text"], entry["ssim_text_last"] = text
                    reference.unlink()
                stream.unlink()
                emit(entry)
    results.close()
    return 0


if __name__ == "__main__":
    os.umask(0o077)
    sys.exit(main())
