# omnigent-browser-host

The remote agent browser host: a windowless Chromium (CEF Alloy, CPU `OnPaint`) that runs on
the agent's machine, one process per browser profile. The runner talks to it over a Unix socket
(`host.sock`); the agent drives it over a loopback CDP port. The design and the protocol
contract are in `apps/apple/docs/remote-browser-design.md` (section 5 is normative), and the
shared protocol fixtures are in `client-core/fixtures/remote_browser/`.

Platforms: Linux x86_64 (headless Ozone, or Xvfb) and macOS arm64 (the local test loop).

## Build

The core (protocol, framing, canvas, BGRA to I420, the encoder process, the streamer) builds
without CEF and has its own tests:

```sh
cmake -S browser-host -B browser-host/build/core && cmake --build browser-host/build/core -j
browser-host/build/core/rb_core_tests
```

The host needs a CEF minimal distribution at the pinned version (156.0.15, the same as the Mac
app's `apps/apple/scripts/fetch-cef.sh`):

```sh
# Linux: fetch, verify SHA-256 and SHA-1, extract under browser-host/third_party/cef (gitignored)
CEF_ROOT=$(browser-host/scripts/fetch-cef-linux.sh)
cmake -S browser-host -B browser-host/build/linux -DCEF_ROOT="$CEF_ROOT"
cmake --build browser-host/build/linux -j
# -> browser-host/build/linux/host/omnigent-browser-host (libcef.so, paks and locales beside it)

# macOS: reuse the Mac app's fetched distribution
CEF_ROOT="$PWD/apps/apple/Vendor/cef/dist/cef_binary_156.0.15+gcf671c0+chromium-156.0.8078.80_macosarm64_minimal"
cmake -S browser-host -B browser-host/build/mac -DCEF_ROOT="$CEF_ROOT"
cmake --build browser-host/build/mac -j
# -> browser-host/build/mac/host/omnigent-browser-host (a launcher for omnigent-browser-host.app)
```

On a machine without internet access to the Spotify CDN, download the archive elsewhere and
place it in `browser-host/third_party/cef/downloads/`; the script verifies it before use.

Build dependencies: CMake 3.21+, a C++20 compiler, libjpeg-turbo headers (`libjpeg-turbo8-dev`,
or Homebrew `jpeg-turbo`). Runtime: the usual headless-Chrome libraries (nss, atk-bridge, gbm,
xkbcommon, asound, pango, cups) and an H.264 encoder (below).

## Running

```
omnigent-browser-host [--profile NAME] [--data-dir D] [--profile-dir P] [--socket S]
                      [--cdp-port N] [--encoder PATH] [--headless-mode ozone|xvfb]
                      [--idle-exit-seconds N] [--no-sandbox] [--encoder-threads N]
                      [--record-dir DIR] [--idle-frame-rate N]
```

| Flag | Default | Meaning |
|---|---|---|
| `--profile NAME` | `default` | Profile name, `[a-z0-9][a-z0-9_-]{0,31}` |
| `--data-dir D` | `$OMNIGENT_DATA_DIR/browser`, else `~/.omnigent/browser` | Shorthand for `--profile-dir D/profiles/NAME` |
| `--profile-dir P` | from `--data-dir` | Profile directory (mode 0700) and CEF `root_cache_path` |
| `--socket S` | `P/host.sock` | Unix socket (mode 0600, same-UID peers only). macOS limits the path to 103 bytes |
| `--cdp-port N` | `0` (pick a free one) | CEF `remote_debugging_port`, bound to 127.0.0.1 |
| `--encoder PATH` | `x264`, then `ffmpeg` on `PATH` | The external H.264 encoder |
| `--headless-mode` | `ozone` | Linux: `ozone` (`--ozone-platform=headless`) or `xvfb` (starts its own Xvfb, `--ozone-platform=x11`) |
| `--idle-exit-seconds N` | `600` | Exit after N s with no tabs and no connections; `0` disables |
| `--no-sandbox` | off | Disable the Chromium sandbox. On Linux the host also turns it off (with a warning) when user namespaces are unavailable |
| `--encoder-threads N` | `1` | Encoder threads per stream |
| `--idle-frame-rate N` | `30` | CEF frame rate (1-60) of tabs nobody watches. At 1 fps Playwright actions wait for animation frames (click plus fill took 2 s instead of 82 ms); idle CPU is the same (M0 doc) |
| `--record-dir DIR` | unset | Enables the `tabs.record` benchmark op, which writes BGRA recordings under DIR |

Files in the profile directory:

- `host.lock`: an exclusive `flock` held for the host's lifetime. A second host for the same
  profile exits with status 69 and "another omnigent-browser-host holds .../host.lock".
- `host.json`: written atomically once the socket listens and CEF is ready, removed on exit:
  `{"pid", "socket", "cdp_port", "version", "profile", "started_at", "encoder": {"path", "kind"}}`.
  `started_at` is RFC 3339 UTC; `encoder.kind` is `x264` or `ffmpeg`.
- `chromium/`: the persistent Chromium profile (cookies persist, including session cookies).
- `chromium.log`: Chromium's own log (warnings and errors).

Exit codes: 0 clean exit, 64 bad arguments, 69 cannot start (lock held, no encoder, socket),
70 CEF failed to initialize, 3 the shutdown watchdog fired.

Shutdown (SIGTERM, SIGINT, `host.shutdown`, idle exit): every tab sends `tab_closed`
(`host_exit`) and closes with 4404, browsers close, the socket closes, `host.json` is removed,
`CefShutdown` runs (bounded to 5 s), and any remaining child process (CEF helpers, the network
service, encoders, Xvfb) is killed before the host exits 0. `tools/shutdown_test.py` checks it.

## Socket protocol

Normative: design doc sections 5.2 (framing), 5.3-5.6 (client protocol) and 5.7 (runner and
host). In short, every frame is `u32 LE payload length, u8 kind, payload` with kind 1 text
(one JSON object), 2 binary (a 24-byte `RB` media header then the payload) and 3 close (`u16 LE`
code then a UTF-8 reason). The first frame on a connection is either the attach preamble
`{"type":"attach","protocol":1,"tab_id","mode":"view"|"control"}` (after which the connection
carries the client protocol unchanged, so the runner splices it to the WebSocket) or
`{"type":"control"}` (request and response ops). Anything else closes with 1002.

Control ops: `health`, `tabs.list`, `tabs.create`, `tabs.navigate`, `tabs.close`,
`tabs.close_session`, `host.shutdown` (section 5.7). Host-specific diagnostics, not part of the
runner contract: `tabs.stats {tab_id}` (frames encoded, encoder CPU, host process tree CPU and
RSS) and, with `--record-dir`, `tabs.record {tab_id, name, max_frames}` and
`tabs.record_stop {tab_id}`.

Host behaviour worth knowing:

- `tabs.create` answers once the tab's CDP `targetId` is known (milliseconds), or after 2 s with
  `target_id: ""`; `tabs.list` reports it later.
- `window.open`, `target=_blank` and modified clicks become new tabs in the opener's session.
  Browsers Chromium creates on its own (DevTools `Target.createTarget`) become tabs with an empty
  `session_id` and `created_by: "agent"`.
- Input (mouse, key, IME, nav, resize, dialog replies) is accepted only from the connection that
  holds control (`control {op: take}`), as section 5.6 requires.
- While the agent owns a tab, JavaScript dialogs are answered by the host (accept; prompts take
  their default) so the page does not stall; the agent's dialog tools arrive with the M2 control
  API. While the user owns it, dialogs go to control connections as `dialog` messages.
- File choosers are cancelled (uploads are out of scope for v1) and reported as `unsupported`.
- With no viewer a tab keeps rendering at `--idle-frame-rate` (30) and encodes nothing; it is
  never hidden (`WasHidden`), so agent screenshots and Playwright keep working at full speed.
  Chromium paints only on change, so an unchanged page costs the same at 1 or 30 fps. Viewers
  set it to the fps cap (15 while the agent owns the tab, 30 while the user does).
- Nothing is streamed before the tab's first real paint, and mouse, key and IME input that
  arrives before it is queued and delivered right after it: Chromium drops input that reaches a
  renderer before its first compositor frame. So the first IDR means "the page is drawn and
  takes input".
- A mouse `down` carries its button's held bit even when the client leaves it out of
  `modifiers`, and so do moves while the button is held.
- `--headless-mode xvfb` starts `Xvfb -extension GLX` (Chromium runs with `--disable-gpu`, and
  Xvfb's GLX init crashes on hosts with NVIDIA EGL libraries).

## Encoder

H.264 Constrained Baseline, `ultrafast`, `zerolatency`, no B-frames, one reference, infinite
GOP, one encoder thread, CRF 24 capped by `--vbv-maxrate` with a two-second VBV buffer, BT.709
limited range. The cap is 1.5 Mbit/s at 1280x720, scaled by pixel count (`quality` low,
medium, high = x0.5, x1, x2). The encoder's nominal rate is 30 fps whatever the owner, so taking
control changes only the pacing cap (15 agent, 30 user) and costs no restart or IDR. After the
last change the host re-encodes the unchanged picture three times (150, 400 and 800 ms later),
so a page that stops scrolling sharpens instead of keeping its rate-limited last frame; then it
encodes nothing. The M0 numbers behind these choices are in
`apps/apple/docs/remote-browser-m0.md`. The host converts damaged regions of the canvas from BGRA to I420 itself, writes raw
frames to the encoder's stdin and reads FLV from its stdout. FLV gives exact access-unit
boundaries over a pipe (raw Annex-B does not: a NAL unit ends only when the next start code
arrives). The host turns FLV back into Annex-B and puts SPS and PPS in front of every IDR.

- **`x264` CLI** (preferred): IDRs on demand without restarting. The host passes a qpfile that
  x264 re-reads before every frame; it ends with a sentinel line far in the future so x264
  never reaches EOF, and the host overwrites the sentinel with `<frame> I` to request an IDR.
  If an IDR request is ever ignored, the host falls back to restarts. x264 buffers stdout, so
  the host preloads a three-line shim (`libomnigent_unbuffered_stdout`) that makes it
  unbuffered.
- **`ffmpeg -c:v libx264`** (fallback, and the VM's encoder): no runtime IDR control, so the
  host restarts the encoder process for each IDR (a new process starts on an IDR).

Settings changes (fps cap, quality, scale, resize, control owner) restart the encoder, which
starts a new stream with an IDR, as section 5.3 requires.

### Encoder licensing

x264 is GPL-2.0-or-later. The host never links, ships or loads libx264 (no `dlopen` either):
it runs the system-installed `x264` or `ffmpeg` command as a child process and talks to it
over pipes only. We never ship an x264 or ffmpeg binary; the agent machine provides it (for
example `apt install x264` or `apt install ffmpeg`). The encoder sits behind the
`EncoderBackend` interface (`src/core/encoder.h`) with the x264/ffmpeg subprocess backend as
the only implementation today, so a BSD OpenH264 backend (which can be shipped and loaded in
process) and hardware backends (VA-API, NVENC, VideoToolbox) can be added without touching the
rest of the host. The stdout shim is our own code, preloaded into the encoder process.

## Tests and tools

- `build/*/rb_core_tests`: unit tests, including `FixturesTest` which round-trips every file in
  `client-core/fixtures/remote_browser/` (messages, runner-host requests and responses,
  `host.json`, binary media frames, socket frames and the H.264 samples) and an encoder test that
  runs the installed x264 and ffmpeg.
- `tools/smoke_test.py --host <binary>`: the end-to-end check (start the host, create a tab,
  attach, IDR first, idle page encodes nothing, click and typing change the page, the stream
  decodes with ffmpeg to the expected pixels, tab close sends 4404, clean shutdown).
- `tools/shutdown_test.py --host <binary>`: SIGTERM leaves no child process and no `host.json`.
- `tools/click_test.py --host <binary> --runs 20`: clicks right after load land every time.
- `tools/idle_cpu.py --host <binary>`: host CPU with open tabs and nobody (or one idle viewer)
  watching.
- `tools/cdp_spike.py --host <binary> --node-modules DIR`: Playwright `connectOverCDP` against
  the host (needs `npm install playwright-core` in DIR's parent).
- `tools/rb_client.py`: a small client (`health`, `list`, `create`, `close`, `watch`,
  `shutdown`) and the library the tests use.
- `tools/encode_bench.cc` (`rb_encode_bench`) and `tools/m0_bench.py`: the M0 encoder and
  render benchmarks (`apps/apple/docs/remote-browser-m0.md`).

## Relation to the Mac app's web host

`apps/apple/WebHost` (the OWL host) and this host share CEF patterns (windowless browser
clients, input, popups, prompts) but not code yet: the OWL host is Objective-C++ bound to its
Mach channel, OWL wire format and IOSurface presenter, and changing it was out of scope for
M1. The overlap (popup handling, JS dialogs, IME, cursor mapping) is copied and adapted here;
extracting a shared `browser-host/core` that both hosts build is a follow-up
(`apps/apple/docs/follow-ups.md`).
