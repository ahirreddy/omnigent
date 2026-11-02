# Remote browser M0 bench

Status: measured 2026-11-01 against the M1 host (`browser-host/`). This replaces the estimates
in [remote-browser-design.md](remote-browser-design.md) section 4.3 and records the defaults the
host now uses.

## Setup

| | Linux VM | Mac |
|---|---|---|
| Machine | `arca_qemu2`: Intel Xeon 6975P-C, 192 vCPU, Ubuntu 24.04 | MacBook Pro, M1 Max, macOS 26 |
| Host | `omnigent-browser-host` 0.1.0, CEF 156.0.15 (Chromium 156.0.8078.80), Alloy windowless, CPU `OnPaint` | same |
| Display | headless Ozone (default) and Xvfb | n/a |
| Encoder | `ffmpeg -c:v libx264` (Ubuntu ffmpeg 6.1.1, libx264 0.164.3108). The x264 CLI cannot be installed: apt is blocked by the Arca policy guard | `x264` CLI 0.165.3222 (Homebrew) |

Both encoders are the same x264 library run as a child process; only the wrapper differs.

Method (`browser-host/tools/m0_bench.py`; reproduce with the commands at the end):

- Six scenario pages (`browser-host/tests/pages/bench/`): `static` (a dense article: headings,
  15 px body text, 12 px red notes, tables), `typing` (about 10 characters per second into a
  textarea), `scroll` (wheel `dy` 60 every 50 ms), `fling` (bursts of 12 wheel events of 320 px
  at 16 ms, then a pause), `video` (a 960x540 VP9 element), `login` (type a username and a
  password and press Enter).
- Viewports 1280x720 and 1920x1080 at DPR 1. Every scenario runs 8 s, driven through the real
  input path (`mouse` and `key` messages on `host.sock`) after `control {op: take}`, so the fps
  cap is 30.
- **render**: a hidden viewer (Chromium renders at the cap, nothing is encoded). CPU is the host
  process tree (browser, renderer, GPU/utility processes, Xvfb when used).
- **live**: a visible viewer that acks every frame. CPU is the whole pipeline: render, BGRA to
  I420, the encoder process and the socket.
- **record** then **encode**: the host records the frames it would encode (BGRA at the 30 fps
  cap); `rb_encode_bench` replays them through the host's encoder backend one frame at a time
  at 5, 15 and 30 fps. Per-frame CPU comes from the encoder process (`/proc/*/task/*/schedstat`
  on Linux, `proc_pid_rusage` on macOS), so the first frame (process start) is reported apart.
- Legibility: SSIM of the decoded stream against the encoder's I420 input, for the whole frame
  and for a 640x360 crop of the article's text column, as a mean over the run and for the last
  frame. VM only (the Mac has no ffmpeg).

## Encoder cost

CPU per frame, steady state, one encoder thread, `ultrafast` + `zerolatency`, Constrained
Baseline, CRF 24. "Core %" is the share of one core if every frame at that rate changes
(encoder CPU plus the BGRA to I420 conversion), which is the sustained worst case.

| Scenario | Size | VM ms p50 / p95 | VM core % at 5 / 15 / 30 fps | Mac ms p50 / p95 | Mac core % at 5 / 15 / 30 fps |
|---|---|---|---|---|---|
| scroll | 1280x720 | 3.5 / 4.0 | 2.6 / 6.9 / 12.6 | 3.5 / 5.4 | 4.2 / 7.5 / 13.7 |
| scroll | 1920x1080 | 6.6 / 7.7 | 5.0 / 13.5 / 26.0 | 6.7 / 8.6 | 7.9 / 14.3 / 28.2 |
| fling | 1280x720 | 3.4 / 4.0 | 2.5 / 6.8 / 12.5 | 3.5 / 4.8 | 2.8 / 7.7 / 13.9 |
| fling | 1920x1080 | 6.7 / 7.9 | 4.9 / 13.7 / 26.1 | 6.4 / 7.7 | 5.4 / 13.5 / 28.2 |
| video | 1280x720 | 2.5 / 3.0 | 2.0 / 5.4 / 10.5 | 2.5 / 3.2 | 2.4 / 5.6 / 11.0 |
| video | 1920x1080 | 4.8 / 5.8 | 3.7 / 10.8 / 21.8 | 4.4 / 5.2 | 3.8 / 10.6 / 20.5 |
| typing | 1280x720 | 2.1 / 3.1 | 1.7 / 4.8 / 9.7 | 1.8 / 2.7 | 1.8 / 5.2 / 10.9 |
| typing | 1920x1080 | 4.6 / 6.3 | 3.6 / 10.6 / 20.6 | 3.8 / 5.0 | 3.6 / 10.1 / 19.5 |

- Full-frame BGRA to I420: 1.0 ms at 720p and 2.3 ms at 1080p (VM and Mac). The host converts
  only damaged rects, so typing pays a few rows per frame.
- Encode wall time (submit to access unit back) p50 / p95 at 720p: VM 8 / 9 ms with ffmpeg,
  Mac 4 / 12 ms with the x264 CLI (the Mac p95 has macOS scheduling spikes). At 1080p: VM
  16 / 19 ms, Mac 7 / 30 ms. The design's "encode p95 ≤ 15 ms" holds at 720p.
- Start-up: the first frame of a new encoder process takes 35-45 ms on the VM (ffmpeg) and
  90-220 ms on the Mac (x264).
- The section 4.3 estimates (720p 4-7 ms, 1080p 8-15 ms per frame on a 3 GHz vCPU) were
  pessimistic for these cores: the measured cost is about 3.5 and 6.6 ms. Expect a small cloud
  vCPU to be 1.3-2x slower.

Bitrate at the default cap (1.5 Mbit/s at 720p, scaled by pixels), 15 fps: scroll 0.86 /
2.0 Mbit/s (720p / 1080p), video 1.2 / 1.8, typing 0.2 / 0.37, static and login under 0.05
(two or three frames in total).

## Whole pipeline

Host process tree CPU, % of one core, with a visible viewer, the final defaults (below) and
the 30 fps user cap. The encoder's share is in parentheses.

| Scenario | VM 720p | VM 1080p | Mac 720p | Mac 1080p | Frames/s (VM 720p) |
|---|---|---|---|---|---|
| static (idle) | 3.7 (0.2) | 3.8 (0.3) | 1.1 (0.1) | 0.7 (0.2) | 0.5 |
| typing | 11.0 (2.1) | 15.6 (5.0) | 7.1 (1.6) | 8.5 (3.5) | 10 |
| scroll | 27.1 (8.7) | 50.9 (17.0) | 20.9 (7.4) | 33.5 (14.3) | 30 |
| fling | 19.1 (5.5) | 30.8 (11.0) | 15.5 (4.3) | 24.2 (8.3) | 17 |
| video | 22.8 (7.6) | 32.6 (15.0) | 16.6 (6.0) | 23.5 (11.5) | 30 |
| login | 3.5 (0.2) | 4.0 (0.5) | 0.7 (0.2) | 0.9 (0.3) | 1 |

- Chromium's software rendering costs more than the encoder in every active scenario: about
  two thirds of the total. That cost exists with or without streaming.
- The M1 exit criterion "720p15 active ≤ 15% of one vCPU for the encoder" holds: scroll at
  15 fps is 6.9% (VM) and 7.5% (Mac).
- An idle page encodes nothing: 0 frames in 2 s once settled (smoke test). After a change the
  host sends three refinement frames over 0.8 s, then stops.
- Idle host with 3 tabs and nobody watching: 3.4% of a core on the VM, 0.9% on the Mac, at
  1 fps and at 30 fps alike (`tools/idle_cpu.py`). Chromium paints only on change.
- Input to encoded frame on the socket (click to the first frame after it, measured by
  `tools/smoke_test.py`): 12-14 ms on the VM, 16-33 ms on the Mac.
- Memory: the host process tree for one tab sums to 0.65 GB RSS on the Mac and 1.1 GB on the
  VM (shared pages counted per process, so this overstates it).

## Chromium render cost by display backend

Host process tree CPU, % of one core, hidden viewer (no encoding), 30 fps cap.

| Scenario | VM Ozone 720p | VM Xvfb 720p | VM Ozone 1080p | VM Xvfb 1080p | Mac 720p | Mac 1080p |
|---|---|---|---|---|---|---|
| static | 6.2 | 2.5 | 4.7 | 3.0 | 1.0 | 0.3 |
| typing | 10.6 | 7.8 | 10.9 | 9.4 | 5.2 | 4.5 |
| scroll | 15.1 | 13.9 | 24.1 | 18.6 | 10.4 | 12.3 |
| fling | 13.7 | 10.2 | 16.1 | 13.7 | 10.0 | 12.0 |
| video | 16.3 | 11.9 | 15.5 | 11.4 | 7.0 | 7.9 |
| login | 5.2 | 3.1 | 5.0 | 2.7 | 0.4 | 0.5 |

- Both backends work end to end (smoke test, click test). Xvfb (its own process included) is
  2-5 points cheaper per scenario in this run; live totals show the same gap (scroll 720p
  27.8% vs 32.7%).
- Xvfb's GLX initialisation segfaults on hosts with NVIDIA EGL libraries (this VM); the host
  starts it with `-extension GLX`, which Chromium does not need with `--disable-gpu`.
- Decision: keep headless Ozone as the default (no X server to install or supervise) and offer
  `--headless-mode xvfb`. Re-measure on a small cloud VM before changing the default.

## Legibility and rate control

Text-crop SSIM, VM, 15 fps, scroll and static recordings. "End" is the last frame: for scroll
that is the moment scrolling stops, for static the picture that stays on screen.

| VBV buffer | Refinement | static 720p (end) | static 1080p (end) | scroll 720p mean / end | scroll 1080p mean / end | scroll 720p kbit/s |
|---|---|---|---|---|---|---|
| 2 frames | none | 0.756 | 0.797 | 0.685 / 0.668 | 0.730 / 0.701 | 862 |
| 2 frames | 3 frames | 0.840 | 0.878 | 0.686 / 0.760 | 0.732 / 0.817 | 873 |
| 1 s | none | 0.951 | 0.976 | 0.699 / 0.670 | 0.747 / 0.721 | 981 |
| 1 s | 3 frames | 0.968 | 0.988 | 0.700 / 0.762 | 0.748 / 0.827 | 987 |
| 2 s | none | 0.991 | 0.991 | 0.704 / 0.671 | 0.753 / 0.731 | 1121 |
| 2 s | 3 frames | 0.992 | 0.994 | 0.705 / 0.766 | 0.754 / 0.820 | 1123 |

- With the design's 1-2 frame VBV, the IDR of a static text page is capped at a few KB and
  stays blurry for as long as the page does not change (nothing else is ever sent). A
  two-second buffer lets that one frame be sharp; the average stays under `vbv-maxrate`.
- Refinement frames (the unchanged picture re-encoded 150, 400 and 800 ms after the last change)
  fix the end of a scroll, where the last frame was encoded under motion. They cost three small
  P-frames.
- During fast scrolling text is soft at these caps (SSIM 0.7) and sharpens when it stops.
  Typing and video stay at 0.99+ throughout. If text during scrolling matters, raise the cap
  (`quality: high`) before touching anything else; at 5 fps the same cap gives 0.82 at 720p.

## Keyframes on demand

- **x264 CLI**: in-stream IDRs without restarting. x264 re-reads its `--qpfile` before every
  frame and gives up at EOF, so the host keeps a sentinel line far in the future at the end and
  overwrites it with `<frame> I` to request an IDR. Verified by `EncoderX264...` in
  `rb_core_tests`: the requested frame comes back as an IDR with SPS and PPS. A missed request
  would switch the backend to restarts.
- **ffmpeg + libx264**: no runtime control, so the host restarts the encoder; the new process's
  first frame is the IDR, 35-45 ms on the VM.
- x264 writes stdout through stdio and never flushes, so over a pipe frames sat in the buffer.
  The host preloads a three-line shim that makes stdout unbuffered. Both encoders write FLV,
  which gives exact frame boundaries; the host converts it back to Annex-B.

## Playwright `connectOverCDP` (Alloy, windowless)

`browser-host/tools/cdp_spike.py` with `playwright-core` 1.56.1 on the VM:

| Check | Result |
|---|---|
| `chromium.connectOverCDP("http://127.0.0.1:<port>")` | Works, 41 ms; one context with the host's tabs as pages |
| `page.goto`, `page.screenshot`, `click`, `fill` on a host tab | Work. Screenshot via CDP is fine in OSR |
| Same `click` + `fill` with no viewer at 1 fps (`--idle-frame-rate 1`) | 2018 ms (Playwright waits for animation frames) vs 82 ms at 30 fps |
| `context.newPage()`, `browser.newContext().newPage()` | Fail: Playwright throws `Cannot read properties of undefined (reading '_page')` |
| Raw `Target.createTarget` | Succeeds, but Chromium creates a Chrome-style, *not* windowless browser through `GetDefaultClient`. The host registers it as a tab (`session_id: ""`, `created_by: agent`), but it never paints, so it cannot stream |

Conclusions:

- The design's top unknown resolves to "no": under Alloy OSR, CDP-created targets are not
  usable remote tabs. Agent-created pages go through our own `browser_tabs open` op (M2), or a
  CDP proxy that implements `Target.createTarget` by creating a host tab and returning its
  `targetId` (the host already reports `target_id` per tab).
- Tabs nobody watches must keep a normal frame rate, or every Playwright action waits about a
  second per animation frame. The host's default `--idle-frame-rate` is 30, not the design's 1:
  idle CPU is the same, because Chromium paints only on change.

## Defaults the host uses

- H.264 Constrained Baseline: `ultrafast`, `zerolatency`, `keyint infinite`, no scenecut, no
  B-frames, one reference, one thread, CRF 24, BT.709 limited range.
- Rate control: `vbv-maxrate` 1.5 Mbit/s at 1280x720 scaled by pixel count (quality low,
  medium, high = x0.5, x1, x2), `vbv-bufsize` two seconds of `vbv-maxrate`.
- Nominal encoder rate 30 fps; the pacing cap is 15 fps while the agent owns the tab and 30 while
  the user does, so taking control needs no restart and no IDR.
- Three refinement frames (150, 400, 800 ms) after the last change, then nothing.
- IDR on new viewer, visibility, `keyframe_request`, resize and encoder change: x264 in-stream
  through the qpfile, ffmpeg by restart.
- Tabs nobody watches render at 30 fps and encode nothing.
- Display: headless Ozone; Xvfb available.

## Open items

- Re-run the render and live phases on a small cloud VM (2-4 vCPU) before fixing the CPU budget
  and the display default; this VM's cores are fast and it has 192 of them.
- The Mac's x264 wall-time p95 spikes (12-30 ms) look like macOS scheduling the child at a
  lower QoS; consider raising the encoder's QoS on macOS runners.
- `Target.createTarget` support (CDP proxy) is M2 work.
- OpenH264 was not measured (the user chose x264); the backend interface is ready for it.

## Reproduce

```sh
# Linux VM (CEF fetched with browser-host/scripts/fetch-cef-linux.sh)
cmake -S browser-host -B browser-host/build/linux -DCEF_ROOT=<cef dist> && cmake --build browser-host/build/linux -j
python3 browser-host/tools/m0_bench.py --host browser-host/build/linux/host/omnigent-browser-host \
  --bench browser-host/build/linux/rb_encode_bench --out /tmp/rb-m0/ozone --video video.webm --headless-mode ozone
python3 browser-host/tools/m0_bench.py ... --out /tmp/rb-m0/xvfb --headless-mode xvfb --phases render,live
python3 browser-host/tools/m0_bench.py ... --out /tmp/rb-m0/variants --phases encode --fps 15 \
  --vbv-frames 2,15,30 --refine 0,3 --recordings "[stv]*_*.bgra"   # with recordings/ from the first run
python3 browser-host/tools/idle_cpu.py --host <binary> --idle-frame-rate 1   # and 30
python3 browser-host/tools/cdp_spike.py --host <binary> --node-modules <dir with playwright-core>

# Mac (reuses apps/apple/Vendor/cef)
python3 browser-host/tools/m0_bench.py --host browser-host/build/mac/host/omnigent-browser-host \
  --bench browser-host/build/mac/rb_encode_bench --out <dir> --video video.webm
```

The video fixture is generated, not checked in:
`ffmpeg -f lavfi -i testsrc2=size=960x540:rate=30 -t 12 -c:v libvpx-vp9 -b:v 1500k -deadline realtime -cpu-used 8 video.webm`.

## Appendix: raw encode matrix

Default rate control of the bench (2-frame VBV, no refinement), one thread. CPU ms are steady state;
"first" is the first frame's wall time (encoder start-up). SSIM is VM only. The Mac run predates the
split of the first frame, so its percentiles include it (it dominates p95 for static and login).

### Linux VM, ffmpeg + libx264 0.164

| Scenario | Size | fps | Frames | CPU ms p50 / p95 | Wall ms p50 / p95 | First ms | kbit/s | SSIM mean | Text SSIM mean / end |
|---|---|---|---|---|---|---|---|---|---|
| fling | 1280x720 | 5 | 27 | 3.96 / 4.75 | 8.9 / 10.1 | 37 | 964 | 0.897 | 0.827 / 0.850 |
| fling | 1280x720 | 15 | 56 | 3.44 / 3.95 | 8.8 / 9.9 | 35 | 669 | 0.801 | 0.691 / 0.707 |
| fling | 1280x720 | 30 | 85 | 3.11 / 3.43 | 8.5 / 9.6 | 35 | 504 | 0.718 | 0.540 / 0.515 |
| fling | 1920x1080 | 5 | 27 | 7.23 / 8.81 | 17.9 / 21.2 | 38 | 2162 | 0.947 | 0.871 / 0.855 |
| fling | 1920x1080 | 15 | 54 | 6.67 / 7.89 | 16.8 / 20.2 | 38 | 1445 | 0.890 | 0.736 / 0.751 |
| fling | 1920x1080 | 30 | 88 | 6.29 / 7.52 | 16.6 / 18.9 | 37 | 1177 | 0.847 | 0.633 / 0.626 |
| login | 1280x720 | 5 | 3 | 3.67 / 3.67 | 7.0 / 7.0 | 35 | 43 | 1.000 | 0.999 / 1.000 |
| login | 1280x720 | 15 | 3 | 4.41 / 4.41 | 7.5 / 7.5 | 34 | 34 | 0.999 | 0.996 / 1.000 |
| login | 1280x720 | 30 | 3 | 3.57 / 3.57 | 9.0 / 9.0 | 35 | 21 | 0.997 | 0.989 / 0.995 |
| login | 1920x1080 | 5 | 3 | 6.75 / 6.75 | 15.2 / 15.2 | 35 | 38 | 1.000 | 0.999 / 1.000 |
| login | 1920x1080 | 15 | 3 | 7.22 / 7.22 | 16.1 / 16.1 | 35 | 36 | 1.000 | 0.999 / 1.000 |
| login | 1920x1080 | 30 | 3 | 7.52 / 7.52 | 15.8 / 15.8 | 34 | 31 | 0.998 | 0.988 / 1.000 |
| scroll | 1280x720 | 5 | 39 | 4.00 / 4.56 | 9.5 / 11.8 | 36 | 1224 | 0.886 | 0.820 / 0.812 |
| scroll | 1280x720 | 15 | 82 | 3.48 / 4.03 | 8.4 / 9.1 | 37 | 862 | 0.796 | 0.685 / 0.668 |
| scroll | 1280x720 | 30 | 159 | 3.19 / 3.55 | 5.8 / 8.3 | 35 | 835 | 0.703 | 0.520 / 0.497 |
| scroll | 1920x1080 | 5 | 39 | 7.44 / 8.47 | 10.4 / 19.7 | 39 | 2744 | 0.941 | 0.862 / 0.869 |
| scroll | 1920x1080 | 15 | 83 | 6.56 / 7.72 | 16.5 / 18.5 | 38 | 1960 | 0.886 | 0.730 / 0.701 |
| scroll | 1920x1080 | 30 | 160 | 6.20 / 7.56 | 15.8 / 18.4 | 37 | 1884 | 0.843 | 0.615 / 0.596 |
| static | 1280x720 | 5 | 2 | 3.98 / 3.98 | 9.7 / 9.7 | 37 | 132 | 0.939 | 0.888 / 0.890 |
| static | 1280x720 | 15 | 2 | 3.92 / 3.92 | 6.6 / 6.6 | 35 | 47 | 0.850 | 0.753 / 0.756 |
| static | 1280x720 | 30 | 2 | 3.92 / 3.92 | 8.0 / 8.0 | 34 | 24 | 0.785 | 0.637 / 0.643 |
| static | 1920x1080 | 5 | 2 | 7.56 / 7.56 | 15.9 / 15.9 | 37 | 298 | 0.973 | 0.926 / 0.928 |
| static | 1920x1080 | 15 | 2 | 8.06 / 8.06 | 18.1 / 18.1 | 36 | 103 | 0.915 | 0.791 / 0.797 |
| static | 1920x1080 | 30 | 2 | 7.42 / 7.42 | 19.4 / 19.4 | 37 | 53 | 0.878 | 0.709 / 0.711 |
| typing | 1280x720 | 5 | 34 | 2.14 / 3.21 | 7.3 / 8.6 | 35 | 196 | 1.000 | 1.000 / 1.000 |
| typing | 1280x720 | 15 | 81 | 2.07 / 3.08 | 6.8 / 8.4 | 35 | 205 | 0.998 | 1.000 / 1.000 |
| typing | 1280x720 | 30 | 82 | 2.04 / 3.07 | 7.0 / 8.6 | 35 | 194 | 0.995 | 1.000 / 1.000 |
| typing | 1920x1080 | 5 | 37 | 4.45 / 6.43 | 14.7 / 17.2 | 39 | 354 | 1.000 | 1.000 / 1.000 |
| typing | 1920x1080 | 15 | 81 | 4.57 / 6.25 | 14.3 / 17.0 | 37 | 370 | 0.999 | 1.000 / 1.000 |
| typing | 1920x1080 | 30 | 82 | 4.40 / 6.19 | 12.2 / 17.0 | 37 | 308 | 0.997 | 1.000 / 1.000 |
| video | 1280x720 | 5 | 38 | 2.79 / 3.39 | 8.0 / 9.4 | 36 | 1127 | 0.998 | 0.998 / 0.999 |
| video | 1280x720 | 15 | 95 | 2.52 / 3.02 | 7.6 / 8.7 | 35 | 1156 | 0.994 | 0.994 / 0.998 |
| video | 1280x720 | 30 | 157 | 2.43 / 2.78 | 7.5 / 9.0 | 36 | 964 | 0.988 | 0.989 / 0.997 |
| video | 1920x1080 | 5 | 38 | 4.94 / 6.22 | 15.6 / 17.0 | 36 | 1415 | 0.999 | 0.999 / 0.999 |
| video | 1920x1080 | 15 | 96 | 4.78 / 5.83 | 15.0 / 17.3 | 36 | 1780 | 0.998 | 0.997 / 0.999 |
| video | 1920x1080 | 30 | 160 | 4.78 / 5.57 | 10.4 / 17.8 | 44 | 1654 | 0.997 | 0.994 / 0.998 |

### Mac, x264 CLI 0.165

| Scenario | Size | fps | Frames | CPU ms p50 / p95 | Wall ms p50 / p95 | First ms | kbit/s | SSIM mean | Text SSIM mean / end |
|---|---|---|---|---|---|---|---|---|---|
| fling | 1280x720 | 5 | 24 | 4.14 / 5.34 | 10.9 / 47.8 | n/a | 771 | n/a | n/a |
| fling | 1280x720 | 15 | 43 | 3.54 / 4.80 | 6.9 / 30.2 | n/a | 459 | n/a | n/a |
| fling | 1280x720 | 30 | 69 | 3.29 / 4.46 | 4.7 / 20.2 | n/a | 362 | n/a | n/a |
| fling | 1920x1080 | 5 | 26 | 7.76 / 11.61 | 13.1 / 25.0 | n/a | 1843 | n/a | n/a |
| fling | 1920x1080 | 15 | 44 | 6.41 / 7.70 | 12.0 / 34.6 | n/a | 1054 | n/a | n/a |
| fling | 1920x1080 | 30 | 70 | 6.75 / 8.45 | 11.3 / 46.5 | n/a | 832 | n/a | n/a |
| login | 1280x720 | 5 | 3 | 2.60 / 12.02 | 4.6 / 60.5 | n/a | 27 | n/a | n/a |
| login | 1280x720 | 15 | 3 | 2.24 / 12.41 | 3.3 / 89.2 | n/a | 26 | n/a | n/a |
| login | 1280x720 | 30 | 3 | 2.33 / 12.66 | 2.9 / 78.5 | n/a | 22 | n/a | n/a |
| login | 1920x1080 | 5 | 3 | 4.98 / 15.14 | 39.9 / 75.2 | n/a | 34 | n/a | n/a |
| login | 1920x1080 | 15 | 3 | 5.17 / 14.96 | 16.0 / 51.7 | n/a | 34 | n/a | n/a |
| login | 1920x1080 | 30 | 3 | 5.52 / 14.88 | 11.3 / 27.4 | n/a | 31 | n/a | n/a |
| scroll | 1280x720 | 5 | 39 | 3.99 / 5.40 | 8.2 / 85.0 | n/a | 1225 | n/a | n/a |
| scroll | 1280x720 | 15 | 84 | 3.54 / 5.39 | 7.2 / 53.7 | n/a | 881 | n/a | n/a |
| scroll | 1280x720 | 30 | 154 | 3.16 / 4.28 | 6.9 / 49.6 | n/a | 765 | n/a | n/a |
| scroll | 1920x1080 | 5 | 38 | 7.71 / 9.62 | 27.9 / 204.0 | n/a | 2667 | n/a | n/a |
| scroll | 1920x1080 | 15 | 84 | 6.72 / 8.62 | 13.8 / 248.3 | n/a | 1975 | n/a | n/a |
| scroll | 1920x1080 | 30 | 144 | 6.38 / 7.58 | 13.2 / 63.7 | n/a | 1658 | n/a | n/a |
| static | 1280x720 | 5 | 2 | 13.59 / 13.59 | 80.9 / 80.9 | n/a | 136 | n/a | n/a |
| static | 1280x720 | 15 | 2 | 14.05 / 14.05 | 91.0 / 91.0 | n/a | 46 | n/a | n/a |
| static | 1280x720 | 30 | 2 | 12.49 / 12.49 | 138.8 / 138.8 | n/a | 24 | n/a | n/a |
| static | 1920x1080 | 5 | 2 | 17.59 / 17.59 | 177.7 / 177.7 | n/a | 310 | n/a | n/a |
| static | 1920x1080 | 15 | 2 | 15.82 / 15.82 | 227.7 / 227.7 | n/a | 108 | n/a | n/a |
| static | 1920x1080 | 30 | 2 | 15.89 / 15.89 | 113.6 / 113.6 | n/a | 54 | n/a | n/a |
| typing | 1280x720 | 5 | 39 | 1.90 / 2.88 | 4.6 / 43.5 | n/a | 181 | n/a | n/a |
| typing | 1280x720 | 15 | 79 | 1.77 / 2.67 | 5.2 / 19.5 | n/a | 192 | n/a | n/a |
| typing | 1280x720 | 30 | 80 | 2.03 / 3.58 | 5.1 / 23.4 | n/a | 183 | n/a | n/a |
| typing | 1920x1080 | 5 | 39 | 3.90 / 5.54 | 11.5 / 42.2 | n/a | 348 | n/a | n/a |
| typing | 1920x1080 | 15 | 80 | 3.82 / 5.03 | 10.7 / 47.1 | n/a | 366 | n/a | n/a |
| typing | 1920x1080 | 30 | 80 | 3.57 / 5.49 | 25.2 / 67.2 | n/a | 312 | n/a | n/a |
| video | 1280x720 | 5 | 36 | 2.87 / 4.07 | 13.6 / 160.0 | n/a | 1070 | n/a | n/a |
| video | 1280x720 | 15 | 89 | 2.46 / 3.20 | 6.9 / 51.1 | n/a | 1090 | n/a | n/a |
| video | 1280x720 | 30 | 148 | 2.34 / 2.99 | 5.9 / 43.8 | n/a | 919 | n/a | n/a |
| video | 1920x1080 | 5 | 37 | 4.70 / 5.49 | 12.2 / 106.4 | n/a | 1370 | n/a | n/a |
| video | 1920x1080 | 15 | 87 | 4.38 / 5.24 | 8.7 / 34.7 | n/a | 1640 | n/a | n/a |
| video | 1920x1080 | 30 | 140 | 4.15 / 4.91 | 5.9 / 23.4 | n/a | 1462 | n/a | n/a |

