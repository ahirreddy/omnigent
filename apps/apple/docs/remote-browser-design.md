# Remote agent browser: design and implementation plan

Status: accepted with the user decisions below, 2026-11-01. M0 and M1 in progress.

The remote agent browser is a real Chromium (CEF, Alloy style, windowless)
running on the agent's machine next to the runner. The agent drives it over the
Chrome DevTools Protocol (CDP). The Omnigent Mac and iOS apps show each remote
tab as a local tab, decode its H.264 stream in hardware, and let the user take
over (log in, solve a 2FA prompt) and then hand control back. Cookies persist
on the remote, so the agent stays logged in.

The governing constraint is CPU on small agent machines. Every choice below
starts from the cheapest approach that meets the requirements and leaves room
to spend more CPU or a GPU when the machine has one.

## 1. Decisions at a glance

| Topic | v1 decision | Fallback or later |
|---|---|---|
| Engine | CEF (same pin as the Mac host, 156.0.15), Alloy style, windowless (OSR), CPU `OnPaint` path | `OnAcceleratedPaint` plus hardware encode when a GPU exists |
| Display on Linux | `--ozone-platform=headless`, software compositing (M0: works end to end) | `--headless-mode xvfb` (measured 2-5 points of a core cheaper; needs `-extension GLX` on NVIDIA hosts) |
| Codec | H.264, Constrained Baseline, no B-frames, infinite GOP, IDR on demand | JPEG stills (thumbnails, single frames); HEVC only with a hardware encoder |
| Linux encoder | OpenH264 (BSD) in `SCREEN_CONTENT_REAL_TIME` mode, in process | x264 `ultrafast`/`zerolatency` if the M0 bench shows a large CPU win and licensing approves; VA-API or NVENC when present |
| macOS-runner encoder | Same OpenH264 path in M1 (one code path) | VideoToolbox low-latency hardware H.264 (near-zero CPU) in M5 |
| Encode policy | Damage-driven: encode only when CEF paints and someone is watching; frame-rate cap; at most 2 frames in flight; drop raw frames before the encoder, never encoded ones | CPU governor that lowers fps, then scale |
| Transport | WebSocket through the server relay, same path as terminal attach (`/v1/sessions/{sid}/resources/browsers/{tab}/attach`) | Loopback direct attach (as terminals have); binary tunnel frames; WebRTC only if TCP head-of-line blocking proves to be a problem |
| Protocol owner | Rust core (`omnigent-core::remote_browser`): framing, state, reconnect, acks, input encoding, key mapping | |
| Client render | Swift: `AVSampleBufferDisplayLayer` fed with `CMSampleBuffer`s (hardware decode, iOS and macOS) | `VTDecompressionSession` → `CVPixelBuffer` → `CAMetalLayer` if latency or control demands it |
| Host process | One `omnigent-browser-host` per OS user per machine, started on demand, tabs tagged by session; it speaks the client protocol over a Unix socket | |
| Agent control | The existing five `browser_*` tools, executed on the runner against the host. CEF `remote_debugging_port` on loopback for Playwright or browser-use, given to the agent as `OMNIGENT_BROWSER_CDP_URL` | A CDP proxy that scopes targets per session and holds input while the user has control |
| Human handoff | New `browser_request_human` tool that creates an elicitation with a `browser_handoff` extra. It reuses the decision dock, inbox badge and desktop notification, and deep-links to the remote tab | |
| Cookies | Persistent `CefRequestContext` per profile under `$OMNIGENT_DATA_DIR/browser/profiles/<profile>`, `persist_session_cookies` | Profile sync for ephemeral sandboxes (open question) |
| Passwords | Deferred. Alloy has no Chrome password-manager UI | |
| Tabs | New `AppTabContent.remoteBrowser(sessionID:, tabID:)`, 1:1 with a host tab | |
| Takeover | Owner state `agent` / `user`; owner-only control (same rule as terminal write attach); viewers are read-only | |

### User decisions (2026-11-01)

These override the table above where they differ.

- **Encoder: x264, installed on the agent machine, run as a separate process.** The host pipes
  raw frames to the system `x264` (or `ffmpeg -c:v libx264`) and reads the Annex-B stream back.
  We never ship, link or `dlopen` libx264: a separate process keeps GPL terms off the host, and
  requiring the package on the VM keeps distribution (and codec patents) off our side.
  `ultrafast`, `zerolatency`, Constrained Baseline, no B-frames. OpenH264 remains an optional
  backend; VideoToolbox on macOS runners stays a later option.
- **Profiles: per machine, chosen per user or agent.** A machine has named profiles; a session
  or agent picks one (default `default`).
- **Isolation: one browser process per profile.** Each profile runs in its own
  `omnigent-browser-host` instance with its own `root_cache_path`, its own loopback
  `remote_debugging_port` and its own `host.sock`. Raw DevTools access is therefore scoped to
  one profile's tabs, which removes the need for a CDP proxy in v1. This replaces "one host per
  OS user": the CEF cache lock is per profile directory, so instances never share a cache.
- **Platforms: Linux x86_64 and macOS runners.** Linux x86_64 is the production target (test
  VM: `ssh arca_qemu2.ssh`). A macOS runner build of the same host is the local test loop: the
  Mac can act as the "remote" for itself, exercising capture, x264 encode, the relay and
  hardware decode end to end on one machine.

## 2. Reference conversation

The shared ChatGPT conversation ("Remote Headless Browsing") was readable in a
browser. It has three turns.

1. Run the browser beside the agent and make the app an attachable viewer.
   Replace Atlas-style local surface sharing (CALayerHost) with capture,
   encode, network and decode. CEF OSR supplies `OnPaint` with dirty rects,
   `OnAcceleratedPaint`, `SendMouse*`/`SendKeyEvent`, and in-process
   `ExecuteDevToolsMethod`. Keep the browser alive when no viewer is attached
   and stop encoding while nobody watches. Do not call `WasHidden(true)`,
   because it stops painting. One input owner at a time (Observe, Take control,
   Resume agent), and the agent re-inspects the page on resume. Do not resize
   the remote viewport on attach. Composite popups. Clipboard, IME, uploads,
   prompts and audio each need their own messages. Validate Linux OSR with
   `--ozone-platform=headless`. It suggests starting with JPEG or PNG frames
   for occasional takeover, and it names headless Chromium with
   `Page.startScreencast` as a simpler server-side alternative.
2. Codecs. Sunshine plus Moonlight is the closest OSS reference; Selkies
   (x264 or OpenH264) and Neko (x264 with WebRTC) are references for remote
   browsers. Start with CPU H.264 (x264 superfast or ultrafast with
   zerolatency, or OpenH264), WebRTC transport, and VideoToolbox decode. AV1 is
   worth a later benchmark. 4:2:0 versus 4:4:4 matters for colored text, with
   AVC444 as a later trick. Keep queues shallow: replace a stale raw frame with
   the newest one, never drop encoded P-frames without recovery, render the
   cursor on the client, and do no work while idle.
3. Sunshine and Moonlight latency techniques: no B-frames or lookahead, a
   single-frame VBV budget (bitrate divided by fps), GPU-resident capture when
   hardware exists, FEC over UDP, IDR on loss, bounded decode queues that flush
   and request an IDR, freshness over smoothness, and 1 ms mouse-move
   coalescing.

Where it agrees with this design: OSR with damage rects, an independent
browser lifecycle, encoding only while watched, single-owner control with
re-inspection on hand-back, a fixed viewport, client-side cursor, CPU H.264
with VideoToolbox decode, IDR on attach, shallow queues that keep the newest
frame, input coalescing, and 4:2:0 first.

Where it differs:

- **First stream format.** The conversation suggests JPEG frames first. The
  requirement is video with hardware decode, so v1 is H.264 and JPEG remains
  for stills. On dense text, measured 1080p JPEG frames are 0.5–0.7 MB each
  (section 4.2), so JPEG cannot carry scrolling.
- **Engine.** Its "headless Chromium with CDP screencast" alternative is ruled
  out by the CEF Alloy requirement. Neko's documentation also says screencast
  "should not be used as a primary video stream".
- **Transport.** It recommends WebRTC (GStreamer `webrtcsink` or libwebrtc) with
  UDP, FEC and NACK. v1 reuses the authenticated server WebSocket relay that
  terminals already use. Over reliable TCP there is no loss to repair, so
  FEC, NACK and periodic IDRs fall away. The cost is head-of-line blocking on
  lossy links. WebRTC stays an option if measurements demand it.
- **Encoder default.** It cites Sunshine's `superfast`. The CPU budget and the
  Apache-2.0 license point to OpenH264 or x264 `ultrafast`; M0 picks between
  them.

## 3. Architecture

```
 Agent machine (Linux VM/container or macOS), one OS user = one host owner
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ host daemon ──spawns──> runner (per session, Python)                     │
 │                          │  browser_* tools, browser_request_human       │
 │                          │  /resources/browsers REST + WS attach route   │
 │                          │  env OMNIGENT_BROWSER_CDP_URL ──> agent shell │
 │                          │                     (Playwright, browser-use) │
 │                          ▼ Unix socket ($DATA/browser/host.sock, 0600)    │
 │  omnigent-browser-host (C++, singleton per OS user, started on demand)   │
 │   ├─ CEF browser process (Alloy, windowless, ozone headless)             │
 │   │   ├─ CefRequestContext per profile ($DATA/browser/profiles/<name>)   │
 │   │   └─ CefBrowser per tab ── OnPaint(BGRA, dirty rects, popups)        │
 │   ├─ TabManager   tab_id <-> CefBrowser <-> CDP targetId, session tag    │
 │   ├─ FrameSink    canvas + popup composite + damage accumulation         │
 │   ├─ Scheduler    fps cap, in-flight window, IDR on demand, idle = 0     │
 │   ├─ Encoder      OpenH264 | (x264) | (VideoToolbox) | JPEG stills       │
 │   ├─ Control      owner = agent | user; input gate                       │
 │   └─ remote_debugging_port on 127.0.0.1 (CDP for the agent) ◄────────────┼─ agent tools
 └──────────────┬───────────────────────────────────────────────────────────┘
                │ runner WS tunnel (existing; ws.open / ws.frame / ws.close)
 ┌──────────────▼───────────────────────────────────────────────────────────┐
 │ Omnigent server: WS /v1/sessions/{sid}/resources/browsers/{tab}/attach   │
 │   auth = session auth; view needs LEVEL_READ, control needs LEVEL_OWNER  │
 │   shuttles frames (same code path as terminal_attach._shuttle_ws_frames) │
 │   elicitations (browser_handoff), session events, resource inventory     │
 └──────────────┬───────────────────────────────────────────────────────────┘
                │ wss (URLSessionWebSocketTask via the host-trait transport)
 ┌──────────────▼───────────────────────────────────────────────────────────┐
 │ Apple app (macOS, iOS)                                                   │
 │  Rust client-core: remote_browser::{attach, codec, state, input, flow}   │
 │    reconnect/backoff, acks, Annex-B → AVCC + SPS/PPS, nav/control state  │
 │  Swift: RemoteBrowserView (AVSampleBufferDisplayLayer, local cursor),    │
 │    input capture (InputTranslator on macOS, gestures/UIKeyInput on iOS), │
 │    AppTabContent.remoteBrowser tab, banner, decision card, notification  │
 └──────────────────────────────────────────────────────────────────────────┘
```

Why the host terminates the client protocol: the host speaks the same
messages as the client, framed over the Unix socket as `u32 length, u8 kind
(text|binary|close), payload` (section 5.2). The runner's attach route then becomes a dumb splice
(the same job `_shuttle_ws_frames` does for terminals), and no WebSocket
library is needed in C++. The protocol lives in exactly two places: the C++
host and the Rust core.

Why there is one host per OS user and not one per runner: CEF (version 120 and
later) takes a process-singleton lock on `root_cache_path`, and the CEF
headers warn that multiple instances writing one cache path corrupt it. A
login shared across sessions on one machine therefore needs one process. A
host also has a single Omnigent owner (`host_owner_scope` in
`omnigent/server/host_registry.py`), so one process per OS user does not mix
users. The host outlives runner restarts, so tabs survive a session resume.
It exits after 10 minutes with no tabs.

## 4. Encoding

### 4.1 Candidates

| Option | Encode CPU | Apple decode | Bandwidth on browser content | License | Verdict |
|---|---|---|---|---|---|
| H.264 OpenH264, screen-content real-time | Low. Has scroll, background and scene-change detection modules. Constrained Baseline only | Hardware on every iPhone, iPad and Mac | About 20% lower BD-rate than x264 ultrafast/zerolatency on 1080p screen content (Fluendo) | BSD-2; Cisco binary carries the MPEG LA royalty if downloaded separately | **v1 default** |
| H.264 x264 `ultrafast` + `zerolatency` | Lowest software H.264 per frame (fewest tools); exact gap to OpenH264 unmeasured | Hardware | Baseline for comparison | GPL (or commercial) | M0 comparator; ship only if it is much cheaper and licensing allows |
| H.264 VA-API, NVENC, VideoToolbox | About 0 CPU | Hardware | Similar to x264 fast presets | Platform | M5 auto-detect; VideoToolbox low-latency mode for macOS runners |
| HEVC x265 `ultrafast` | About 1.4× the encode time of the LCEVC-H.264 entries in the Fluendo set; 4 frames of delay | Hardware on Apple Silicon | About 33% lower BD-rate than x264 ultrafast | GPL | Only with a hardware encoder |
| AV1 SVT-AV1 RTC | Highest of these | Hardware only on A17 Pro / M3 and newer | Best | BSD | No (decode coverage, CPU) |
| CDP `Page.startScreencast` | JPEG produced in the browser at ack pace | ImageIO | High (JPEG per frame) | n/a | No. Neko says screencast should not be a primary stream |
| Dirty-rect JPEG or WebP tiles from `OnPaint` | JPEG cheap (measured below); WebP 10× slower | ImageIO | Good for typing, terrible for scrolling (full repaint) | BSD | Stills and thumbnails only |

### 4.2 Measured still-image costs (this machine, M1 Max, one core)

Synthetic browser-like frame (dense text plus an app screenshot), from
`/private/tmp/claude-502/remote-browser/` (`cjpeg` libjpeg-turbo 3.1.0, `cwebp`
1.5.0):

| Encoder | 1920×1080 | 1280×720 |
|---|---|---|
| JPEG q80, `-dct int` | 6.5 ms, 705 KB | 3.5 ms, 270 KB |
| JPEG q60 | 6.0 ms, 519 KB | 3.3 ms, 192 KB |
| WebP lossy q75, `-m 0` | 59 ms, 481 KB | 28 ms, 211 KB |
| WebP lossless `-z 0` | 37 ms, 194 KB | 23 ms, 319 KB |

Takeaway: JPEG is cheap per frame, but 15 fps of dense 1080p text is 60–85
Mbit/s. That is fine for a one-off frame and wrong for a stream. WebP costs
too much CPU. Expect a small x86 vCPU to be 1.3–2× slower than an M1 Max core.

### 4.3 Measured H.264 encoder CPU per stream

Measured in M0 ([remote-browser-m0.md](remote-browser-m0.md) has the raw numbers and the
commands). x264 `ultrafast` + `zerolatency`, Constrained Baseline, one thread, run as a child
process: ffmpeg + libx264 0.164 on the Linux VM (Xeon 6975P), the x264 CLI 0.165 on an M1 Max.
The two cost the same within 10%.

CPU per frame, steady state (the first frame of a new encoder process adds 35-45 ms on Linux):

| Content | 1280×720 | 1920×1080 |
|---|---|---|
| Scrolling text | 3.5 ms | 6.6 ms |
| Video element | 2.5 ms | 4.8 ms |
| Typing | 2.1 ms | 4.6 ms |
| BGRA→I420, full frame (the host converts damaged rects only) | 1.0 ms | 2.3 ms |

Share of one core when every frame changes (encoder plus conversion):

| Resolution | 5 fps | 15 fps | 30 fps |
|---|---|---|---|
| 1280×720 | 2.6% | 6.9% | 12.6% |
| 1920×1080 | 5.0% | 13.5% | 26% |
| Idle page (no damage) | 0 | 0 | 0 |
| Typing | about ⅔ of the active figures | | |

The earlier estimates (720p 4–7 ms, 1080p 8–15 ms) were pessimistic for these cores; expect a
small cloud vCPU to be 1.3–2× slower than these numbers.

As predicted, Chromium's software rendering costs more than the encoder in every active
scenario, about two thirds of the whole pipeline. Whole pipeline at 720p with the 30 fps user
cap (host process tree, encoder in parentheses), Linux VM: static 3.7% (0.2), typing 11% (2.1),
scroll 27% (8.7), fling 19% (5.5), video 23% (7.6). At 1080p scrolling is 51%. The Mac is about
25% lower.

### 4.4 Encode policy

- **Damage-driven.** CEF calls `OnPaint` only when content changes, at up to
  `windowless_frame_rate`. With no viewer attached, encode nothing but keep the frame rate at
  30 (`--idle-frame-rate`), and never `WasHidden(true)`: it stops painting, which breaks agent
  screenshots. M0 measured a 1 fps idle rate making a Playwright `click` plus `fill` take
  2018 ms instead of 82 ms (Playwright waits for animation frames), while idle CPU was the same
  at 1 and 30 fps because Chromium paints only on change. With a viewer, the pacing cap is
  15 fps while the agent owns the tab and 30 fps while the user does (configurable). Nothing is
  streamed before the tab's first paint, and input that arrives before it is queued until then:
  Chromium drops input that reaches a renderer before its first compositor frame.
- **Coalescing.** FrameSink keeps one persistent BGRA canvas, applies dirty
  rects, composites `PET_POPUP` (select dropdowns), and accumulates damage.
  The scheduler encodes the latest canvas when (a) damage is non-empty,
  (b) fewer than `max_in_flight` frames (default 2, and 512 KB) are unacked,
  and (c) the fps cap allows. Otherwise it waits. Raw frames are replaced,
  never queued. Encoded frames are never dropped.
- **GOP.** Infinite GOP with no periodic IDR, because the transport is
  reliable. IDR goes out on attach, on `keyframe_request`, on resize, and on
  encoder reconfiguration. Each IDR starts a new `stream_id`. The encoder's nominal rate is
  30 fps for both owners and only the pacing cap changes, so taking control is not an encoder
  change and sends no IDR. The x264 CLI produces IDRs in-stream: it re-reads its `--qpfile`
  before every frame, and the host overwrites a sentinel line at the end with `<frame> I`.
  `ffmpeg -c:v libx264` has no runtime control, so the host restarts it (the new process's
  first frame is the IDR, 35–45 ms on the VM).
- **Rate control.** CRF 24 capped by `vbv-maxrate`: 1.5 Mbit/s at 720p, scaled by pixel count
  (1080p about 3.4 Mbit/s); quality presets low, medium, high = ×0.5, ×1, ×2. The VBV buffer
  is two seconds of the cap, not the 1–2 frames first planned: with a 2-frame buffer the IDR of
  a static text page is capped at a few KB and stays blurry while the page does not change
  (text SSIM 0.75 at 720p), and with two seconds it is sharp (0.99). The ack window still
  bounds what is in flight.
- **Refinement.** 150, 400 and 800 ms after the last change the host re-encodes the unchanged
  picture (three small P-frames), so a page that stops scrolling sharpens (text SSIM at the end
  of a scroll 0.67 → 0.76) instead of keeping its rate-limited last frame. Then it encodes
  nothing.
- **DPR.** Encode at DPR 1 by default; a Retina client upscales. DPR 2 is an
  explicit "sharp text" setting that quadruples pixels.
- **Governor (M5).** Track encode-time p95 against a host-wide CPU budget
  (default 0.5 vCPU across all streams). Over budget, lower fps first, then
  scale (0.75 or 0.5) for passive viewers. Never degrade the tab that is
  under user control first.
- **Cursor.** Not in the video. The host forwards `OnCursorChange` types,
  matching the OWL `CursorChanged` and `OWLCursor` enum, and the client draws
  the native cursor locally.

### 4.5 Client decode

- **v1:** Rust converts Annex-B to AVCC and extracts SPS/PPS. Swift builds a
  `CMVideoFormatDescription`
  (`CMVideoFormatDescriptionCreateFromH264ParameterSets`), wraps each access
  unit in a `CMSampleBuffer` with `kCMSampleAttachmentKey_DisplayImmediately`,
  and enqueues it on an `AVSampleBufferDisplayLayer` (via
  `sampleBufferRenderer` on newer OSes). This is the path Moonlight iOS uses.
  It decodes in hardware on both platforms. On `.failed` status or
  `requiresFlushToResumeDecoding` (iOS background), flush and send a
  `keyframe_request`.
- **Fallback:** `VTDecompressionSession` (require hardware via
  `kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder`) →
  `CVPixelBuffer` → `CAMetalLayer`, if `AVSampleBufferDisplayLayer` adds
  measurable latency (Moonlight-qt has reports of this) or we need
  pixel-exact scaling.
- **JPEG stills** (tab-overview thumbnails, `codec=jpeg`) go to `CGImage` and
  layer contents.

## 5. Transport and protocol

**Status: protocol v1, frozen 2026-11-01.** This section is the contract between the host
(C++), the runner and server (Python), the Rust core and the Swift client. Fixtures for every
message and frame are in `client-core/fixtures/remote_browser/` (see its `README.md`); every
implementation tests against them. Changes go through the Rust core owner. Additive changes
(a new optional field, a new message type, a new `features` string) keep v1. Anything else is
v2 (section 5.9).

Conventions:

- "MUST", "SHOULD" and "MAY" carry their usual meaning.
- All multi-byte integers in binary layouts are **little-endian**.
- JSON is UTF-8. Field names are `snake_case`. An optional field is either absent or `null`;
  receivers treat both the same. Receivers ignore unknown fields.
- Coordinates and sizes are viewport CSS pixels unless a field says otherwise. A JSON number
  may be fractional; the host rounds to the nearest integer where CEF needs one.
- Identifiers: tab ids match `[A-Za-z0-9_-]{1,128}` and are opaque to clients. Profile names
  match `[a-z0-9][a-z0-9_-]{0,31}`; `default` is the default profile.

### 5.1 Path

`client ⇄ wss server /v1/sessions/{sid}/resources/browsers/{tab}/attach?mode=view|control&v=1 ⇄ runner WS tunnel channel ⇄ runner WS route ⇄ <profile>/host.sock`

- **Query.** `mode` is `view` (default when absent) or `control`. `v` is the highest protocol
  major the client speaks (`1`). `omnigent_slice_key` is added on sharded deployments, as for
  terminals. Credentials (`Authorization`, `X-Databricks-Org-Id`) ride as handshake headers,
  never in the query.
- **Server.** Add a route beside `terminal_attach.py` that reuses
  `_shuttle_ws_frames`, `WrongReplicaWSError`/4400, and the
  `require_access` auth helper. `mode=view` needs `LEVEL_READ`; `mode=control` needs
  `LEVEL_OWNER` (refused with close 4403 after the upgrade, or HTTP 403 before it). Generalize
  `_RUNNER_PATH_RE` in `omnigent/server/_runner_ws_tunnel.py` to accept
  `/resources/browsers/{id}/attach`, and *only* that path, so CDP can never
  be routed through the server. Text frames stay text and binary frames stay binary end to
  end.
- **Runner.** Resolves the tab to its profile's host (section 5.7), opens `host.sock`, sends
  the `attach` preamble with the mode the server authorized, and then splices frames both
  ways without parsing them. Close codes pass through in both directions.
- **Tunnel costs.** Binary rides as base64 inside JSON `ws.frame` text frames
  (+33%), and the channel queues are unbounded asyncio queues on a tunnel
  shared with all runner traffic. At ≤3 Mbit/s that is acceptable *only*
  because the host bounds in-flight bytes end to end with acks. Binary tunnel
  frames are M5.
- **Direct attach.** Same-machine clients can use the existing loopback
  direct-attach listener (`omnigent/runner/direct_attach.py`), which already
  carries an owner-gated token. M5.
- **Latency targets.** Input-to-photon p50 ≤ network RTT + 60 ms and p95 ≤
  RTT + 120 ms at 720p. Encode p95 ≤ 15 ms. Client frame age at most one
  frame.

### 5.2 Framing

**WebSocket (client ⇄ server ⇄ runner).**

- **Text frames** carry one JSON object each, with a string `type`. Unknown types are ignored
  (Rust surfaces them as a notice). Maximum 1 MiB.
- **Binary frames** carry media: the 24-byte header below, then the payload. Maximum 16 MiB
  including the header; a larger frame closes the connection with 1009.

**Media header** (`RB` v1, 24 bytes, little-endian):

| Offset | Size | Field | Value and rules |
|---|---|---|---|
| 0 | u16 | `magic` | `0x4252`, so the bytes on the wire are `52 42` ("RB") |
| 2 | u8 | `version` | `1`. A receiver drops a frame with another version and reports it |
| 3 | u8 | `kind` | `1` H.264 access unit, `2` JPEG still, `3` JPEG thumbnail. Other values: ack, then ignore |
| 4 | u16 | `flags` | bit 0 `keyframe` (IDR access unit), bit 1 `new_stream` (first frame of `stream_id`). Other bits are 0 on send and ignored on receive. Kinds 2 and 3 send 0 |
| 6 | u16 | `header_len` | Bytes before the payload: `24` in v1. A receiver accepts any value ≥ 24 and skips the extra bytes; a value < 24 or > the frame length is malformed |
| 8 | u32 | `seq` | Per connection: 1 for the first binary frame, +1 for every binary frame of any kind. Acked by the client |
| 12 | u32 | `stream_id` | Kind 1: the H.264 stream, which starts at 1 and increments on every IDR. Kinds 2 and 3: 0 |
| 16 | u64 | `pts_us` | Host monotonic capture time in µs (not wall clock). Non-decreasing within a stream |

**Payloads.**

- **Kind 1.** Exactly one access unit in Annex-B byte stream format (3- or 4-byte start
  codes), Constrained Baseline (`profile_idc` 66 with `constraint_set1_flag`), progressive,
  4:2:0, 8-bit, no B-frames, one reference frame, any number of slices. A keyframe access unit
  MUST carry its SPS and PPS before the first IDR slice. It MAY carry an access unit
  delimiter (type 9), SEI (6) and filler (12); the client drops those. `keyframe` is set iff
  the access unit is IDR, and in v1 every IDR also sets `new_stream` and a new `stream_id`.
  A delta frame always carries the current `stream_id`.
- **Kinds 2 and 3.** One baseline JPEG (JFIF, 4:2:0). The image dimensions come from the JPEG
  itself. A still shows the full viewport; a thumbnail is at most 320 px wide.

**Receiver rules (client).** A malformed binary frame (short, bad magic, bad `header_len`) is
dropped and reported; the connection continues, and the client sends `keyframe_request`
(`reason: "gap"`) if a stream was active. A delta whose `stream_id` is not the current stream
is dropped, and the client sends `keyframe_request` once per stream. A keyframe whose SPS or
PPS differs from the previous stream's is a **format change**: the client rebuilds its
decoder format description before decoding it.

**Unix socket (runner ⇄ host).** Every frame is a 5-byte prefix and then the payload:

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | u32 | `len` | Payload length in bytes, excluding these 5 bytes. Maximum 16 MiB; larger closes with 1009 |
| 4 | u8 | `kind` | `1` text (one UTF-8 JSON object), `2` binary (one media frame, header included), `3` close |
| 5 | `len` | payload | For `3`: u16 close code, then a UTF-8 reason (0–123 bytes) |

A close frame is the last frame in its direction; the sender then shuts the socket. EOF
without a close frame means 1011. The runner maps WebSocket text, binary and close frames to
kinds 1, 2 and 3 one to one.

### 5.3 Session setup and versioning

1. The client opens the WebSocket. On open, both sides send `hello` at once; neither waits
   for the other's.
2. The host sends nothing but `hello`, `error` and `pong` until it has the client's `hello`.
   Then it sends, in order: `control`, `viewport`, `nav`, `cursor`, `text_input`, any open
   `dialog` (control-mode connections only), and, if the client is visible, an IDR.
3. The client checks `hello.protocol`. If it does not speak it, it closes with 4426. The host
   does the same for the client's `hello.protocol`. In v1 both send `protocol: 1`.
4. `hello.mode` from the host is authoritative: the mode the runner's `attach` preamble
   carried. When the client's `hello.mode` asks for more than that, the host uses its own and
   the client follows the host's.
5. A connection never receives a delta before its first IDR. A new viewer, a newly visible
   viewer, a reconnect, a `keyframe_request`, a resize and an encoder change each produce an
   IDR, which starts a new `stream_id` for every viewer of the tab. A control `take` or
   `release` is not an encoder change and produces no IDR. The host sends no media before the
   tab's first paint, so a new tab's first IDR can come later than the setup messages.
6. `features` lists optional capabilities as strings. v1 defines none; receivers ignore
   unknown ones.

### 5.4 Messages

Every message is a JSON object with `type`. Types marked *(control)* are accepted only on a
`mode=control` connection; *(holder)* additionally needs this connection to hold control
(section 5.6). The host answers a refused message with a non-fatal `error`
(`control_not_permitted` or `not_in_control`) at most once per second per type, and drops it.

**Shared value types.**

- `viewport`: `{w: u32, h: u32, dpr: number}`. CSS px and device pixel ratio.
- `rect`: `{x, y, w, h}` numbers in viewport CSS px.
- `modifiers`: an integer bitset defined by this protocol (the host maps it to CEF
  `EVENTFLAG_*`). Bit 0 shift, 1 ctrl, 2 alt (option), 3 meta (command), 4 caps lock, 5 num
  lock, 6 left mouse button down, 7 middle button down, 8 right button down. Other bits are 0
  on send and ignored on receive.
- `control_state`: `{owner: "agent" | "user", holder: "this" | "other" | null, user_id?: string,
  handoff?: {id: string, reason: string}}`. `holder` is per connection: `"this"` when this
  connection holds control, `"other"` when another connection does, and `null` when
  `owner` is `agent` or nobody holds the user's control (grace period, section 5.6).
  `handoff` is set while an agent `browser_request_human` handoff is pending.
- `settings`: `{max_fps: u32, quality: "low" | "medium" | "high", scale: number (0.25–1),
  codec: "auto" | "h264" | "jpeg"}`.

**Host → client.**

| `type` | Fields | When |
|---|---|---|
| `hello` | `protocol: 1`, `tab_id`, `profile`, `host_version`, `mode: "view" \| "control"`, `codecs: ["h264", "jpeg"]`, `viewport`, `control: control_state`, `settings`, `window: {max_frames: 2, max_bytes: 524288}`, `features: []` | First frame |
| binary kind 1 | H.264 access unit | On damage, within the window, while visible |
| binary kind 2 / 3 | JPEG still / thumbnail | In reply to `still_request`, or as the stream when `codec` is `jpeg` |
| `nav` | `url`, `title`, `loading: bool`, `progress: number (0–1)`, `can_go_back`, `can_go_forward`, `favicon_url?` | After setup and on every change |
| `cursor` | `cursor` (a CSS `cursor` keyword: `default`, `pointer`, `text`, `crosshair`, `wait`, `progress`, `help`, `move`, `not-allowed`, `grab`, `grabbing`, `none`, `ew-resize`, `ns-resize`, `nesw-resize`, `nwse-resize`, `col-resize`, `row-resize`, `zoom-in`, `zoom-out`, `copy`, `alias`, `cell`, `context-menu`, `vertical-text`, `all-scroll`, or `custom`), `custom?: {png_base64, hotspot_x, hotspot_y, scale}` | After setup and on change. Unknown keywords render as `default` |
| `text_input` | `mode` (`none`, `text`, `tel`, `url`, `email`, `numeric`, `decimal`, `search`), `caret_rect?: rect` | After setup and on change. Unknown modes act as `text` |
| `control` | `control_state` fields, `reason?` (`take`, `release`, `handoff`, `holder_left`, `grace_expired`, `agent`) | After setup and on every transition, to every connection |
| `dialog` | `id`, `kind` (`alert`, `confirm`, `prompt`, `beforeunload`, `file_chooser`), `message`, `default_text?`, `origin?` | While a JS dialog is open and the user owns the tab (control-mode connections only) |
| `dialog_closed` | `id` | The dialog was answered (by any connection) or dismissed by the page |
| `viewport` | `viewport` fields | After setup and after a resize is applied |
| `settings` | `settings` fields | After a `settings` change is applied |
| `stats` | `fps`, `kbps`, `encode_ms_p50`, `encode_ms_p95`, `in_flight_frames`, `in_flight_bytes`, `host_cpu` (cores, e.g. 0.12) | Every 1 s while this connection asked with `settings {stats: true}` |
| `pong` | `nonce` | Reply to `ping` |
| `error` | `code`, `message`, `fatal: bool` | `code`: `invalid_message`, `unsupported`, `control_not_permitted`, `not_in_control`, `no_dialog`, `navigation_failed`, `internal`. When `fatal`, a close follows |
| `tab_closed` | `reason` (`closed`, `crashed`, `host_exit`) | Then close 4404 |

**Client → host.**

| `type` | Fields | Gate | Notes |
|---|---|---|---|
| `hello` | `protocol: 1`, `client` (for example `omnigent-apple/0.1 macOS`), `decoders: ["h264", "jpeg"]`, `mode`, `visible: bool`, `features: []` | | First frame |
| `ack` | `seq` | | Cumulative: acknowledges every binary frame with `seq` ≤ this. Sent on receipt, before decode |
| `keyframe_request` | `reason` (`decoder_error`, `flush`, `gap`, `user`) | | The host answers with an IDR within one frame interval; requests coalesce |
| `visibility` | `visible` | | `false` stops video to this connection (`nav` and the rest continue); `true` gets an IDR |
| `still_request` | `kind` (`still`, `thumbnail`) | | One kind 2 or 3 frame in reply |
| `mouse` | `kind` (`move`, `down`, `up`, `wheel`, `leave`), `x`, `y`, `button?` (`left`, `middle`, `right`; required for `down` and `up`), `clicks?` (1–3, for `down` and `up`), `modifiers`, `dx?`, `dy?` (wheel only, CSS px, DOM `WheelEvent.deltaX/Y` sign: positive `dy` scrolls the content down) | holder | Rust coalesces moves and sums wheel deltas; it never drops or reorders `down` and `up` |
| `key` | `kind` (`rawkeydown`, `keyup`, `char`), `code` (DOM `KeyboardEvent.code`, `"Unidentified"` when unknown), `key` (DOM `KeyboardEvent.key`), `text?` (for `char`, the characters to insert), `modifiers`, `repeat: bool` | holder | The host maps `code` to `windows_key_code` and the native code. A typed character is `rawkeydown`, `char`, `keyup` |
| `ime` | `op` (`set_composition`, `commit`, `finish`, `cancel`), `text?`, `selection?: {start, end}` (UTF-16 offsets in `text`), `replacement?: {start, end}` (UTF-16 offsets in the field) | holder | `ImeSetComposition`, `ImeCommitText`, `ImeFinishComposingText`, `ImeCancelComposition` |
| `nav` | `op` (`navigate`, `back`, `forward`, `reload`, `stop`), `url?` (required for `navigate`) | holder | |
| `resize` | `viewport` fields | holder | Explicit "Fit to window" only; attaching never resizes. Bounds: w and h 200–3840, dpr 1–3 |
| `control` | `op` (`take`, `release`) | control | Section 5.6 |
| `dialog_reply` | `id`, `accept: bool`, `text?` | holder | |
| `settings` | `max_fps?`, `quality?`, `scale?`, `codec?` (control), `stats?: bool` (any mode, per connection) | see fields | Persisted per tab on the host |
| `ping` | `nonce` (string) | | Every 10 s |

### 5.5 Acks and flow control

- The host keeps, per connection, the frames with `seq` greater than the last ack. It sends a
  binary frame only while fewer than `window.max_frames` (2) are unacked **and** fewer than
  `window.max_bytes` (512 KiB) are unacked. A single frame larger than `max_bytes` may go out
  when nothing is unacked.
- Encoding is gated on the window of every visible viewer of the tab: the encoder runs only
  when all of them have room. Raw frames are replaced while waiting, never queued; encoded
  frames are never dropped.
- A viewer whose oldest unacked frame is 10 s old is closed with 1013 (try again later). It
  reconnects and gets an IDR; the other viewers stop waiting for it.
- The client acks every binary frame on receipt, in order, including kinds it ignores and
  malformed frames whose `seq` it can read. It may send one cumulative ack for several frames
  that arrived together. Decoding is never on the ack path: the client's renderer keeps a
  bounded, latest-wins queue and, when it has to drop a frame, drops to the next IDR and sends
  `keyframe_request` (`flush`).
- Input runs the other way, is small, and is coalesced by Rust: mouse moves and wheel events
  go out at most once per 16 ms, the latest move (and the summed wheel delta) winning. Any
  other input first flushes the pending move or wheel, so order is kept.

### 5.6 Control ownership

- **Owner** is `agent` or `user` per tab. Only a `mode=control` connection (session owner) can
  take control. Among those, one connection is the **holder**: the host accepts holder-gated
  messages only from it.
- **Take.** `control {op: take}` on a control-mode connection makes it the holder and the
  owner `user`, even if another connection held control (the same user on another device takes
  over; the old holder sees `holder: "other"`). The fps cap rises to 30. A take is not an
  encoder change: no IDR follows it, and clients must not wait for one (an idle page sends no
  frame at all). On a view connection the host answers `error {code: control_not_permitted}`.
- **Release.** `control {op: release}` from the holder sets the owner to `agent` and `holder`
  to null. From anyone else it is answered with `not_in_control`.
- **Holder leaves.** When the holder's connection ends without a release, the owner stays
  `user` with `holder: null` for a 60 s grace period (`reason: holder_left`), so a reconnect
  does not hand the page back to the agent mid-login. Any control connection may `take` during
  the grace period. At its end the owner becomes `agent` (`reason: grace_expired`).
- **Rust's part.** Rust tracks whether the user wants control. After a reconnect it re-sends
  `take` when the user held control and had not released it. It sends holder-gated input only
  when `holder` is `"this"` and reports anything else as dropped (`not_in_control`), so the host
  rarely sees refused input. A pending `handoff` does not change ownership; the client's first
  click on the video sends `take`.
- **Handoffs.** The host learns of handoffs from the runner (host control API) and reflects
  them in `control_state.handoff`. Resolving the elicitation is a REST call by the client
  (section 6), not a message on this socket.

### 5.7 Runner ⇄ host

**Profiles and processes.** Each profile runs its own `omnigent-browser-host` with its own
directory `$OMNIGENT_DATA_DIR/browser/profiles/<profile>/` (mode 0700; the CEF
`root_cache_path`), its own loopback CDP port and its own socket. The runner starts the host
for a profile on demand and finds it through `host.json`.

**CLI.**

| Flag | Default | Meaning |
|---|---|---|
| `--profile NAME` | `default` | Profile name |
| `--data-dir D` | `$OMNIGENT_DATA_DIR/browser` | Shorthand: `--profile-dir D/profiles/NAME` and `--socket D/profiles/NAME/host.sock` |
| `--profile-dir P` | from `--data-dir` | Profile directory (CEF `root_cache_path`) |
| `--socket S` | `P/host.sock` | Unix socket path (mode 0600) |
| `--cdp-port N` | `0` | Loopback DevTools port; 0 picks a free one |
| `--encoder PATH` | search `PATH` for `x264`, then `ffmpeg` | External H.264 encoder process |
| `--headless-mode ozone\|xvfb` | `ozone` | Linux display backend |
| `--idle-exit-seconds N` | `600` | Exit after N seconds with no tabs and no connections |
| `--no-sandbox` | off | Disable the Chromium sandbox (logged as a warning) |

- `P/host.lock`: an exclusive `flock` held for the host's lifetime. A second host for the
  same profile exits with an error.
- `P/host.json`, written atomically (temp file and rename) once the socket listens, removed on
  clean exit: `{pid, socket, cdp_port, version, profile, started_at, encoder: {path, kind}}`.
  `started_at` is RFC 3339 UTC; `encoder.kind` is `x264` or `ffmpeg`.
- The socket accepts only the host's own UID (`SO_PEERCRED` / `getpeereid`).

**Connections.** Every connection uses the Unix framing in section 5.2. Its first frame is a
text frame, and it decides the connection type:

- **Attach:** `{"type": "attach", "protocol": 1, "tab_id", "mode": "view" | "control"}`.
  After it, the connection carries exactly the client protocol (sections 5.3–5.6), and the
  runner splices it to the WebSocket. An unknown tab closes with 4404; an unsupported
  `protocol` closes with 4426. On a `view` attach the host drops control-gated messages.
- **Control:** `{"type": "control"}`. After it, the runner sends requests and the host
  answers each one:
  - Request: `{"type": "request", "id": string, "op": string, "args": object}`.
  - Response: `{"type": "response", "id", "ok": true, "result": ...}` or `{"type": "response",
    "id", "ok": false, "error": {"code", "message"}}`, where `code` is `not_found`,
    `invalid_input`, `unavailable` or `internal`.
  - Responses may arrive out of order; `id` matches them.

Any other first frame closes with 1002.

**Tab record:** `{id, session_id, url, title, loading, owner, needs_attention, profile,
created_by: "agent" | "user", target_id, can_go_back, can_go_forward}`.

**Ops.**

| `op` | `args` | `result` |
|---|---|---|
| `health` | `{}` | `{version, profile, cdp_port, tabs: u32}` |
| `tabs.list` | `{session_id?}` | `{tabs: [tab record]}` |
| `tabs.create` | `{session_id, url?, created_by, width?, height?, dpr?}` (default 1280×800 at DPR 1) | tab record |
| `tabs.navigate` | `{tab_id, url}` | tab record |
| `tabs.close` | `{tab_id}` | `{closed: true}` (`not_found` when unknown) |
| `tabs.close_session` | `{session_id}` | `{closed: u32}` |
| `host.shutdown` | `{}` | `{}`, then the host closes its tabs and exits |

The tool operations (navigate, evaluate, snapshot, screenshot, click, type, `set_control`,
handoff state) are added to this op table by the host and runner owners in M2 and M3.

### 5.8 Close codes

| Code | Sent by | Meaning | Client (Rust) result |
|---|---|---|---|
| 1000 | either | Normal close (client detach, or the server ended the attach) | Closed |
| 1001, 1005, 1006, 1011, 1012, 1014 | server, runner, host, transport | Going away, no status, dead TCP, internal failure, restart, bad gateway | Reconnect with backoff |
| 1013 | host | Viewer stalled (section 5.5) | Reconnect with backoff |
| 1002 | either | Protocol violation | Failed (unrecoverable) |
| 1008 | server | Unauthenticated (`authentication required`) or not authorized | Failed: sign in, or access denied |
| 1009 | either | Frame too large | Failed (unrecoverable) |
| 4400 | server | Wrong replica for the slice key | One immediate keyless redial, then Failed |
| 4403 | server, runner | `mode=control` not permitted for this caller | Failed: access denied (a `view` attach may still work) |
| 4404 | server, runner, host | Tab or session gone (after `tab_closed`, or unknown tab) | Closed: tab ended |
| 4426 | either | Protocol version unsupported | Failed: protocol unsupported |
| 4500 | server | Server-side relay failure | Failed: server error |
| other | | | Closed with the code |

Watchdog: the client sends `ping` every 10 s and closes with 1000 and reconnects after 30 s
with no inbound frame of any kind. The host may close a connection silent for 60 s with 1001.
A handshake answered 401 needs sign-in, 403 is access denied, 404 retries a bounded number of
times, as for terminals.

**Reconnect.** Rust reuses the `TerminalAttach` backoff (500 ms base, 30 s cap, about five
minutes of attempts). Each reconnect gets a new `hello`, a new `seq` space and an IDR. The
browser and tab state live on the host, so a reconnect loses nothing.

### 5.9 Versioning

- `v` in the query is the highest major the client speaks; `protocol` in both `hello`s is the
  major in use. v1 hosts and clients send `protocol: 1`.
- Additive fields, message types, binary kinds, flag bits, header bytes (via `header_len`) and
  `features` strings do not bump the version. Receivers ignore what they do not know.
- A breaking change bumps the major. The host then serves N and N−1 for one release, choosing
  the highest major that is ≤ the client's `v`.
- The binary header `version` changes only with a protocol major.
- Protocol v1.1 (section 16) is a set of `features` on top of v1: viewport ownership, mobile
  emulation, edit commands, selection and scroll reports, and touch input.

### 5.10 REST and resources

Browser tabs are session resources (`ResourceType "browser"` in
`omnigent/entities/session_resources.py` and `schemas.py`), shaped like terminals:

```json
{"object": "session.resource", "id": "btab_7f3a9c2e", "type": "browser",
 "session_id": "…", "name": "GitHub", "metadata": {"url": "https://github.com/login",
 "title": "Sign in to GitHub", "loading": false, "owner": "agent", "needs_attention": false,
 "profile": "default", "created_by": "agent", "can_go_back": true, "can_go_forward": false,
 "thumbnail_url": null}}
```

- `GET /v1/sessions/{sid}/resources/browsers` lists tabs as a `PaginatedList` (`object:
  "list"`, `data`, `has_more`, `first_id`, `last_id`; `limit` 1–1000, `after`, `order`).
- `POST /v1/sessions/{sid}/resources/browsers` with `{"url"?, "profile"?}` (default profile
  `default`) creates a tab and returns its resource. 400 for an invalid profile name or URL,
  403 without edit access, 503 when the browser host is not installed or cannot start
  (`{"error": {"code": "browser_unavailable", "message"}}`).
- `DELETE /v1/sessions/{sid}/resources/browsers/{id}` closes a tab:
  `{"id", "object": "session.resource.deleted", "deleted": true}`; 404 when it is already gone.
- `GET /v1/sessions/{sid}/resources/browser_profiles` (optional; 404 means only `default`):
  `{"object": "list", "data": [{"name": "default", "running": true}], "has_more": false}`.
- Session event `browser.tab.updated` (debounced 250 ms) carries the same resource object, so
  background tabs and other devices update the tab strip without an attach. Planned for M2.

## 6. Agent control (CDP)

- **CDP endpoint.** The host sets CEF `remote_debugging_port` (1024–65535) to a
  free loopback port and writes `DevToolsActivePort` in the cache dir. The
  runner injects `OMNIGENT_BROWSER_CDP_URL=http://127.0.0.1:<port>` into the
  harness environment. Playwright (`chromium.connectOverCDP(url)`),
  browser-use and raw CDP clients attach to it. Playwright documents CDP
  attach as "significantly lower fidelity" than its own protocol. That is
  acceptable, but test it.
- **Built-in tools.** `browser_navigate`, `browser_snapshot`, `browser_click`,
  `browser_type` and `browser_screenshot` already exist (in
  `omnigent/tools/builtins/browser.py` and the `_BROWSER_TOOLS` branch of
  `omnigent/runner/tool_dispatch.py`). Today they route to the app's local
  agent browser through `/browser/action_request`. When the session's browser
  target is `remote`, the runner instead calls the host control API: the host
  runs `ExecuteDevToolsMethod` on that tab's browser, which scopes it to the
  session. The snapshot JS (`[ref=N]`, `__omni_refs__`, `__omni_snapshot_id__`)
  in `AgentBrowserScripts.swift` is ported verbatim, with a parity test.
  Screenshots use `Page.captureScreenshot`. The tool results keep their
  current shape, so the agent sees no difference.
- **Target mapping.** On tab creation the host calls `Target.getTargetInfo`
  through the tab's DevTools client and stores
  `tab_id ↔ CefBrowser ↔ targetId ↔ session_id`. Tools accept an optional `tab`
  argument and default to the session's most recently focused tab.
  `browser_tabs` (list, open, close, select) is added in M2.
- **Agent-created tabs.** Pages created through CDP (`Target.createTarget`,
  Playwright `newPage()`) and `window.open` popups must become host tabs.
  `window.open`, `target=_blank` and modified clicks do (`OnBeforePopup` creates windowless
  host tabs in the opener's session). M0 measured CDP with Playwright `connectOverCDP`
  (`playwright-core` 1.56.1) against the host:
  - Connect (41 ms), `goto`, `screenshot`, `click` and `fill` all work on host tabs.
  - `context.newPage()` and `browser.newContext().newPage()` fail (Playwright throws
    `Cannot read properties of undefined (reading '_page')`).
  - Raw `Target.createTarget` succeeds, but Chromium creates the browser through
    `CefBrowserProcessHandler::GetDefaultClient` as a Chrome-style, non-windowless browser.
    The host registers it as a tab, but it never paints, so it cannot stream.

  **Decision for M2:** agents create tabs through our own `browser_tabs open` op (the host
  control API's `tabs.create`), or through a CDP proxy that turns `Target.createTarget` into a
  host tab and returns its `targetId`. Raw CDP target creation is not supported until then.
- **While the user has control:**
  - Built-in tools fail fast with
    `{"ok": false, "error": "user_in_control", "hint": "wait for hand-back"}`.
  - `browser_request_human` blocks, as below.
  - Raw CDP is not gated in v1. The framework prompt tells the agent not to act
    while a handoff is open. A CDP proxy that holds `Input.*` and
    `Page.navigate` during user control comes later (section 11).
- **Human handoff tool.** `browser_request_human(reason, tab?)`:
  - The runner creates an elicitation (`mode: "form"`, `message: reason`)
    with the extra `browser_handoff: {tab_id, url, title}`. It reuses
    `_elicitation_registry`, the timeout policy, `pending_elicitations`
    replay, the sidebar badge and `AttentionNotification(kind: Approval)`.
  - The tool blocks until the user hands back or declines. It returns
    `{status: "completed" | "declined" | "timeout", url, title}`, and the
    framework instruction tells the agent to re-snapshot.
- **Prompt.** Extend the framework-owned `EMBEDDED_BROWSER_PRIORITY_INSTRUCTION`
  in `omnigent/runtime/prompt.py` with the remote variant: "for logins,
  CAPTCHAs, 2FA or payment, call `browser_request_human`; never ask for
  credentials in chat."

## 7. Takeover UX

- **States.**
  - `agent`: the agent owns the tab. Viewers watch at 15 fps.
  - `user`: input is accepted from the owning user's attach.
  - A pending handoff decorates the `agent` state.
  - "Paused" is not a separate state: an idle agent is just `agent` with no
    actions in flight.
- **Banner** (in the tab, above the video):
  - Agent browsing: "Agent is browsing · Take over".
  - Handoff pending: "Agent needs you: Please log in to github.com · Take over"
    (accent style, plus a dock card).
  - User in control: "You're in control · Hand back to agent".
  - Read-only viewer: "Viewing <owner>'s agent browser".
- **Take over.**
  - The client sends `control {op: take}`. The host switches the owner to
    `user` and broadcasts `control`. From then on the host accepts input only
    from that connection. The fps cap rises to 30.
  - Clicking into the video while the agent owns the tab shows the banner
    prompt rather than silently stealing control. While a handoff is pending,
    the first click takes control.
- **Hand back.**
  - The client sends `control {op: release}`. The host sets the owner to
    `agent`.
  - If a handoff was pending, the client also resolves the elicitation with
    `accept`, and the agent's tool returns.
  - "I can't do this" resolves it with `decline`.
- **Who.** Taking control requires `LEVEL_OWNER`, the same rule as terminal
  write attach: input carries no per-user attribution and acts as the owner's
  logged-in browser. Others attach with `mode=view` (`LEVEL_READ`).
- **Input mapping, macOS.**
  - Reuse `InputTranslator` (`OmnigentWebLayer/InputTranslation.swift`), which
    already produces NSEvent-free `MouseInput` and `KeyInput` values with CEF
    modifier bits and 40-px line scrolling.
  - Reuse the `NSTextInputClient` code in `WebSurfaceView+TextInput.swift`
    for IME.
  - Swift hands these to Rust as FFI records. Rust maps the macOS `kVK_*`
    code to a DOM `code` with the Chromium `keycode_converter` table (mac
    column), then serializes and coalesces.
- **Input mapping, iOS.**
  - Tap: move, then down and up at the scaled point.
  - Long press: right click.
  - One-finger pan: wheel with pixel deltas (natural scrolling).
  - Pinch: local zoom of the video only.
  - Keyboard: a hidden `UIKeyInput`/`UITextInput` view is shown when the host
    sends `text_input.mode != none` or the user taps a keyboard button. v1
    sends committed text only; marked-text IME comes in M3.
  - Hardware keyboard: `UIPress.key` HID usage to DOM `code`, via the same
    table's USB column.
- **Viewport.** Fixed per tab (default 1280×800 CSS px at DPR 1). The client
  letterboxes and scales. "Fit to window" (owner only) sends `resize`.
  Attaching never resizes. The agent's coordinates stay valid unless someone
  deliberately resizes.

## 8. Cookies and profiles

- **Layout.**
  - `root_cache_path = $OMNIGENT_DATA_DIR/browser/` (default `~/.omnigent/browser/`,
    mode 0700).
  - Each profile gets a `CefRequestContext` with
    `cache_path = …/profiles/<profile>` and `persist_session_cookies = true`,
    the same pattern as `Profile-<key>` in `WebHost/Sources/OWLHost.mm`.
  - Default profile: `default`, shared by every session of the host's single
    owner on that machine. Log in once and every session is logged in.
  - Sessions may request a named profile (`profile: "work"`) or `ephemeral`
    (empty `cache_path`, in memory).
- **Isolation.**
  - Between Omnigent users: a host has one owner, and the host process and
    profile dir belong to that OS user.
  - Between sessions of the same owner: shared by design on the default
    profile, isolated with named or ephemeral profiles. The raw CDP port can
    still see every tab on the host (section 10).
- **Security.**
  - On a headless Linux machine there is no keyring, so Chromium falls back to
    the "basic" store, which Chromium's docs call plain text (unencrypted)
    for passwords. Treat the cookie DB the same way: anyone who can read the
    OS user's files can reuse the sessions.
  - Mitigations: 0700 permissions, never sync off-box in v1, and a
    "Clear browsing data" or "Sign out everywhere" action per profile from
    the client.
- **Ephemeral sandboxes.** Managed or warm-pool sandboxes that are recreated
  per session lose profiles. Persisting them needs profile export to server
  storage (open question).
- **Passwords: deferred.** Chrome's password manager is Chrome-layer UI. In
  Alloy, WebUI such as `chrome://settings` has crashed (CEF issue #3763,
  fixed with an allowlist), and save-password bubbles have no host UI. The
  engine-decision doc rates passwords and autofill "partial" even locally. The
  cheap path, if wanted later, is client-side: the user picks a Keychain item
  on their device and the client types it as `ime commit`. The secret never
  rests on the remote.

## 9. Tabs and UI

- **Model.**
  - Add `AppTabContent.remoteBrowser(sessionID: String, tabID: String)` in
    `OmnigentAppUI/Tabs/AppTab.swift` (it plugs into the exhaustive
    `sessionID`, `kind`, `focusesExisting` and `destination` switches).
  - Add `TabKind.remoteBrowser` in
    `OmnigentUI/Sources/OmnigentUIComponents/Tabs/TabsState.swift` (label
    "Remote browser", a globe icon with a server badge).
  - Persisted through the existing `TabPersistence` JSON. Older builds drop an
    unknown kind leniently, so no migration is needed.
- **Hosting.** A `RemoteBrowserTabHost` follows the `BrowserTabHosting` shape
  (content, status, snapshot, close, attach/detach), backed by
  `RemoteBrowserStore`. It is deliberately *not* a `BrowserEngine`: engines
  are profile-local, their kinds are persisted, and `BrowserTab` has a large
  local surface (print, find, view source). The remote tab reuses the browser
  chrome components (omnibox, back/forward/reload, progress) instead.
- **Lifecycle.**
  - **User opens one:** NewTabPage gets a "Remote browser on <host>" launcher
    for sessions whose runner advertises a browser host. It calls `POST` and
    opens the tab next to the session's chat or local browser tabs.
  - **Agent opens one:** the client mirrors the session's remote tab list
    (resources plus `browser.tab.updated`) and adds background local tabs
    grouped after the session's chat tab. Policy is an open question.
  - **Close:** closing the local tab sends `DELETE` to the remote tab. If the
    agent is mid-action, ask for confirmation.
  - **Restore:** reattach on restore. On 4404, show "This remote tab ended ·
    Reopen <last URL>", which creates a new remote tab. Cookies make that
    cheap.
  - **Popups:** `window.open` creates a host tab, which appears as a local
    tab, as local browser popups do today.
- **Overview.** `TabOverview` shows a JPEG thumbnail (kind 3, about 320 px,
  sent only when content changes) and an owner badge (Agent, You, Needs you).
  Status comes from `TabAdapter`.
- **Settings.**
  - Per tab, in the tab menu: fps cap, quality, scale, sharp text (DPR 2),
    codec (auto or JPEG low-power).
  - Per server defaults live in app preferences. The host-wide CPU budget is
    in `~/.omnigent/config.yaml` (`browser.encoder_cpu_budget`).
- **Notifications.**
  - A handoff elicitation already triggers `AttentionNotification` (Approval)
    and the desktop notification through `DesktopNotificationCenter`. Title it
    "Agent needs you in the browser" with the reason as the body.
  - Add `DeepLinkRoute.remoteBrowser(sessionID, tabID)` in `DeepLink.swift`
    and `omnigent-ffi/src/deeplink.rs`, so a tap focuses or opens the remote
    tab and arms Take over.
  - iOS has no push notifications today (risk 12).

## 10. Security

- **Stream auth.** The stream uses the server's session auth, as terminals do:
  the Rust core copies `Authorization` and `X-Databricks-Org-Id` from the live
  connection onto the WS handshake. `mode=view` requires `LEVEL_READ`;
  `mode=control` requires `LEVEL_OWNER`. The runner and host re-check
  `mode` (defense in depth). A view connection's input is dropped at the
  server and at the host.
- **Server relay.** The relay forwards only the attach path regex. CDP and the
  host control API are never reachable through the server or the tunnel.
- **Host socket.** `host.sock` sits in the 0700 data dir with mode 0600, and
  connections are accepted only from the same UID (`SO_PEERCRED` on Linux,
  `getpeereid` on macOS).
- **CDP.**
  - Bound to 127.0.0.1 only. Chromium's DevTools HTTP handler rejects
    non-local `Host` headers, which blocks DNS rebinding.
  - The port is unauthenticated, so any process of any user on the machine
    can attach. That is acceptable for single-tenant agent VMs and
    containers, where same-user processes can read the profile anyway. It is
    not acceptable on shared multi-user machines.
  - The port spans all sessions' tabs on the host. Hardening (M5+):
    `--remote-debugging-pipe` into the host plus a per-session token proxy
    that filters `Target.*` to the session's tabs and gates input during user
    control.
- **Chromium sandbox.** Use the namespace sandbox where unprivileged user
  namespaces exist. Containers without them need `--no-sandbox`; log a
  warning and surface it in host diagnostics.
- **Owner only.** Takeover is owner-only, as above.

## 11. Packaging

- **Linux CEF.**
  - Spotify CDN `linux64` and `linuxarm64` *minimal* distributions at the same
    version as the Mac pin (`scripts/fetch-cef.sh`, 156.0.15). Verify them by
    SHA, as the Mac fetch does.
  - Built in CI into `omnigent-browser-host-<ver>-linux-<arch>.tar.zst`
    (libcef.so, resources, locales, the host binary, and libopenh264 fetched
    from Cisco at install time).
  - Hundreds of MB, so it is not in the Python wheel. `omnigent browser
    install` downloads it to `$OMNIGENT_DATA_DIR/browser/runtime/<ver>/`. The
    runner advertises `browser_host: available | not_installed` in its hello
    and resources.
- **Headless.**
  - Flags: `--ozone-platform=headless --disable-gpu --disable-gpu-compositing`,
    windowless rendering, and `shared_texture_enabled = false` (CPU `OnPaint`).
  - Fallback: `--headless-mode xvfb` starts the host's own Xvfb
    (`-displayfd`, `-extension GLX`) and uses `--ozone-platform=x11`. Xvfb's GLX
    initialisation segfaults on hosts with NVIDIA EGL libraries, and Chromium does not need
    GLX with `--disable-gpu`. CEF issue #3902 (a headless-Ozone key-event crash, closed with a
    workaround of setting `size` on `cef_key_event_t`) and #4166 (incomplete OSR frames) show
    the headless path is lightly trodden.
  - M0: both modes pass the end-to-end smoke test. Xvfb measured 2–5 points of a core cheaper
    per scenario on the VM. Headless Ozone stays the default (no X server to install or
    supervise); re-measure on a small cloud VM before changing it.
  - Runtime libraries are the usual headless-Chrome set (nss, atk-bridge, gbm,
    xkbcommon, asound, pango, cups, x11/xcomposite/xdamage/xrandr stubs).
    Confirm with `ldd` in M0, and publish an apt line plus a Dockerfile layer
    for sandbox images.
- **Shared C++ core.** Move the portable handler code (`OWLBrowserClient`
  handlers, `OWLBrowserInput`, `OWLBrowserPopups`, `OWLNavigationRules`,
  `OWLWire`, `OWLJSON`) to `.cc` under a shared `browser-host/core/`. That is
  roughly 60–70% of the current host by the research estimate. The Mac OWL
  host keeps its Mach channel and IOSurface presenter. The remote host adds
  FrameSink, Encoder, Scheduler, the socket server and TabManager. One CMake
  build covers Linux and macOS.
- **macOS runners.** The same host binary, built as a plain executable with
  helper bundles and no app UI. It uses the CPU `OnPaint` plus OpenH264 path
  in M1, then VideoToolbox (`kVTVideoEncoderSpecification_EnableLowLatencyRateControl`,
  hardware H.264) in M5. Later, an `OnAcceleratedPaint` IOSurface could feed
  VideoToolbox with zero copies.

## 12. Work items by component

Each item is sized for one implementation agent. Dependencies are in brackets.

**A. Remote browser host (C++)**
1. Extract the portable CEF core from `apps/apple/WebHost/Sources` into
   `browser-host/core/` with a CMake build on Linux and macOS, without
   changing the Mac host's behavior.
2. Host main: CEF init (Alloy, windowless, headless flags, `root_cache_path`,
   `remote_debugging_port`), singleton `flock`, `host.sock` server with
   length-prefixed framing, and idle exit.
3. TabManager: create, close and list tabs; profiles to request contexts;
   target-id mapping; session tags; popups become tabs; crash produces
   `tab_closed`.
4. FrameSink and Scheduler: canvas, dirty rects, popup compositing, damage
   accumulation, fps cap, in-flight window, IDR on demand, stats.
5. Encoder interface plus OpenH264 backend (dlopen the Cisco binary;
   `SCREEN_CONTENT_REAL_TIME`; dynamic bitrate and fps; forced IDR) and a JPEG
   still/thumbnail backend (libjpeg-turbo).
6. Input: DOM `code` to `windows_key_code`/native mapping, mouse, wheel, IME,
   `cef_key_event_t.size` set correctly (#3902); cursor and `text_input`
   events; dialog forwarding.
7. Control arbiter and host control API (tool operations: navigate, evaluate,
   snapshot, screenshot, click and type through CDP; `set_control`;
   settings).

**B. Runner (Python)** [A2]
1. `omnigent/runner/browser_host.py`: locate or install the runtime, spawn or
   attach to the singleton, health checks, advertise availability in hello.
2. Resource routes: list, create and delete browsers; a WS attach route that
   splices to `host.sock`; session-end cleanup of the session's tabs.
3. Tool dispatch: remote target for the five `browser_*` tools (snapshot JS
   port plus a parity test), `browser_tabs`, `browser_request_human`
   (elicitation with `browser_handoff`), and `OMNIGENT_BROWSER_CDP_URL` in the
   harness env.
4. Session setting `browser_target: app | remote` plus a default rule (open
   question 2).

**C. Server**
1. Browser attach WS route reusing the `terminal_attach` shuttle and auth
   (view = read, control = owner); `_RUNNER_PATH_RE` extended to exactly
   that path.
2. `ResourceType "browser"`, the resource proxy routes, and the
   `browser.tab.updated` event schema.
3. Elicitation `browser_handoff` extra in `ElicitationRequestParams`
   (documented in `API.md`), and the framework prompt addition in
   `omnigent/runtime/prompt.py`.

**D. Rust core** (`client-core`)
1. `omnigent-protocol::remote_browser`: serde models for every message in
   section 5.4, plus the binary header codec, with fixtures.
2. `omnigent-core::remote_browser::attach`: a sans-IO state machine modeled
   on `TerminalAttach` (inputs, outputs, close-code table, backoff, ping
   watchdog, ack emission).
3. `codec` and `state`: Annex-B to AVCC with SPS/PPS extraction; tab state
   (nav, control, cursor, text input, viewport, stats); input coalescing; the
   mac and USB-HID to DOM `code` tables.
4. `client/browsers.rs` REST plus attach request (credential headers,
   `omnigent_slice_key`), `DecisionKind::BrowserHandoff`, the deep-link route,
   and attention text.
5. `omnigent-ffi::remote_browser` driver plus a `RemoteBrowserListener`
   foreign trait (`on_state`, `on_video(VideoFrame{stream_id, keyframe,
   pts_us, params?, avcc})`, `on_still`, `on_closed`). Use bounded channels
   with a latest-wins policy for video, not the unbounded queues that the
   terminal path uses.

**E. Swift transport and renderer** [D5]
1. `OmnigentRemoteBrowser` package: `RemoteBrowserStore` (owns the driver)
   and `RemoteBrowserView` (NSView/UIView) with an
   `AVSampleBufferDisplayLayer` renderer (format description from parameter
   sets, DisplayImmediately, flush-and-IDR on failure), JPEG still layer,
   local cursor, letterboxing and scaling, and a coordinate mapping to
   viewport CSS px.
2. macOS input: adapt `InputTranslator` and the `NSTextInputClient` code to
   emit FFI input records.
3. iOS input: gestures, `UIKeyInput`, hardware keys.
4. Stats HUD (debug).

**F. Tabs and UI** [E1]
1. `AppTabContent.remoteBrowser`, `TabKind`, `TabAdapter`, the
   `ConnectedServerView` content switch, NewTabPage launcher, restore, and the
   "ended · Reopen" state.
2. Browser chrome for the remote tab (omnibox, navigation, progress), the
   control banner, Take over / Hand back, and Fit to window.
3. Decision card for `BrowserHandoff` ("Open browser"), inbox item,
   notification deep link, and the overview thumbnail with owner badge.
4. Settings UI (per tab and per server defaults).

**G. Packaging and CI**
1. Linux CEF fetch with SHA pin; host build for linux x86_64 and arm64 plus
   macOS arm64; artifact publishing; `omnigent browser install`; Docker layer
   for sandbox images; `ldd` dependency check.
2. Headless smoke test in CI: boot the host, load a fixture page, receive one
   IDR, decode it with ffmpeg (CI only), and assert pixel content.

**M0 bench (prerequisite, one agent)**
Record BGRA frame sequences from CEF (static page, typing, smooth scroll,
fling scroll, a video element, a login form). On a 2-vCPU x86 VM and an arm64
VM, measure OpenH264 against x264 ultrafast/zerolatency against JPEG:
ms/frame p50/p95, bitrate, and text legibility (SSIM or VMAF on text crops).
Also measure CEF software-render CPU per scenario. Spike headless Ozone
against Xvfb, Playwright `connectOverCDP` (including `newPage`), and
`Target.createTarget` under Alloy OSR. The results replace section 4.3 and
pick the default encoder.

## 13. Milestones

| Milestone | Scope | Exit criteria |
|---|---|---|
| **M0 Spike** (about 1 week) | Bench and spikes above | Default encoder chosen with data; headless mode chosen; CDP fidelity known |
| **M1 Vertical slice** | A1–A6 (OpenH264, Linux and macOS CPU path), B1–B2, C1, D1–D3 and D5, E1–E2, F1 (user-created tab only), F2 (navigation only). Persistent `default` profile is on from day one (it is just `cache_path`) | A remote page renders in a local Mac tab; mouse, scroll and keyboard work; idle page uses 0% encoder CPU; 720p15 active ≤ 15% of one vCPU for the encoder; reconnect recovers with an IDR; input-to-photon p50 ≤ RTT + 60 ms |
| **M2 Agent CDP** | A3 target mapping, A7, B3–B4, C2, D4 (REST), F1 agent-opened tabs, iOS view plus tap, scroll and keyboard (E3) | Agent tools and Playwright drive the remote tab while the user watches live on Mac and iOS; tool results match the local agent browser |
| **M3 Handoff and takeover** | Control arbiter end to end, `browser_request_human`, C3, D4 decision kind and deep link, F2 banner, F3, full macOS IME, iOS marked text | "Please log in" → notification → tap opens tab → Take over → log in → Hand back → the agent continues with the new state; viewers cannot take control |
| **M4 Cookies and profiles** | Named and ephemeral profiles, Clear data, host survives runner restart, tab restore after host restart, session-end cleanup, profile permission checks | Logged in after a runner or host restart and in a new session on the same machine |
| **M5 Settings and efficiency** | F4 settings, CPU governor, VideoToolbox encoder on macOS runners, VA-API/NVENC probing, thumbnails, direct attach, binary tunnel frames, CDP proxy (per-session scope, input gate) | Settings change fps, quality and scale live; encoder CPU stays within budget under load |

## 14. Risks

1. **Linux OSR maturity.** Headless Ozone with OSR has recent crash and
   incomplete-frame bugs (#3902, #4166). Mitigation: keep Xvfb as the
   fallback, pin the CEF version, run the CI smoke test.
2. **Chromium software rendering may dominate CPU.** Without a GPU,
   rasterization and compositing during scroll can cost more than the
   encoder. Mitigation: the 720p/DPR 1 default, fps caps, measurement in M0.
3. **Unmeasured encoder costs.** The section 4.3 numbers are estimates.
   OpenH264 may be 1.5–3× x264 ultrafast per frame, and one issue reports far
   worse in some configurations. Mitigation: M0 decides; the encoder sits
   behind an interface.
4. **Licensing and patents.** x264 is GPL. H.264 patent coverage needs
   Cisco's separately downloaded binary with the user able to turn it off,
   plus attribution. Mitigation: OpenH264 via Cisco download, and legal
   review before any x264 backend.
5. **CDP fidelity under Alloy.** Playwright `newPage`/`Target.createTarget` may
   not work, and Playwright already calls CDP attach lower fidelity.
   Mitigation: M0 spike, plus our own `browser_tabs` tool.
6. **Shared host blast radius.** One CEF process holds every session's tabs: a
   crash takes them all down, and raw CDP sees them all. Mitigation:
   auto-restart with tab restore (M4), and the CDP proxy (M5).
7. **Tunnel contention.** Video shares the runner tunnel, with unbounded
   queues, base64 framing and head-of-line blocking. Mitigation: the ack
   window bounds bytes, bitrate caps, binary frames (M5), and direct attach.
8. **Sandboxing in containers.** The Chromium sandbox may be unavailable.
   Mitigation: detect it, warn, and document the required capabilities.
9. **Cookies are effectively plaintext on headless Linux.** Mitigation: 0700
   directories, the clear-data action, and documentation.
10. **`AVSampleBufferDisplayLayer` latency or quirks.** Mitigation: the
    `VTDecompressionSession` + Metal fallback.
11. **Text legibility.** 4:2:0 at DPR 1 softens small colored text.
    Mitigation: the sharp-text setting (DPR 2, QP cap); AVC444-style tricks
    much later.
12. **No iOS push.** Handoffs only notify on macOS (local notifications). An
    iOS user who is not in the app misses "Please log in".
13. **Unhandled browser surfaces.** JS dialogs, file choosers, downloads and
    permission prompts can stall a page. Mitigation: the `dialog` message
    while the user has control; auto-policies plus tool errors while the
    agent does; downloads land in the session workspace (M3+).
14. **Memory.** Each Chromium tab costs about 100–300 MB, which matters on
    small machines. Mitigation: a tab cap per session, and discarding
    background agent tabs.

## 15. Open questions for the user

1. **Profile scope.** One shared `default` profile per machine (log in once for
   every session), per agent, or per session? For managed sandboxes that are
   recreated per session, should profiles sync through the server?
2. **Default browser target.** Use the remote browser automatically for
   remote or sandbox runners and keep the app-local agent browser for local
   runners? Or always remote when the host is installed?
3. **Agent-opened tabs.** Should every remote tab the agent opens appear as a
   background local tab (strict 1:1), or only when the user opens the
   session's browser?
4. **Encoder licensing.** Is a downloaded Cisco OpenH264 binary acceptable?
   Would a GPL x264 backend (system-installed, not shipped) be acceptable if
   it is much cheaper?
5. **Viewport.** Keep a fixed agent viewport with letterboxing (proposed), or
   resize to the user's window on takeover?
6. **Takeover rights.** Owner only (proposed, matching terminals), or anyone
   with edit access?
7. **Raw CDP.** Expose it to every agent shell by default, or only when an
   agent opts in? Is all-tabs visibility on the machine acceptable until the
   proxy lands?
8. **Runner platforms for M1.** Linux x86_64 only, or also arm64 and macOS?
   Must containers without user namespaces be supported?
9. **Scope.** Are audio, clipboard sync, file upload and downloads out of
   scope for v1?
10. **Passwords.** Defer entirely, or plan client-side Keychain fill (the
    secret never stored on the remote)?
11. **iOS push for handoffs.** Is APNs push in scope, or is macOS-only
    notification acceptable for now?

## 16. iOS viewport modes and touch (protocol v1.1)

Status: implemented 2026-11-01. Everything here is additive to v1 (section 5.9): `protocol` stays
`1`, and each addition is negotiated through a `features` string. A v1 peer never receives a
v1.1 message, and a v1.1 client degrades to v1 behaviour against a v1 host (16.7).

### 16.1 Viewport modes

The remote tab's toolbar has a viewport menu. The mode is a client preference, remembered per
device, and it only acts while this client holds control.

| Mode | Remote viewport | Local view |
|---|---|---|
| **Keep remote size** (default) | Unchanged: the agent's size (default 1280×800) | Letterboxed to fit; pinch zoom, pan, double-tap zoom |
| **Fit to window** | The view's size in CSS px at DPR 1, desktop layout, following resizes. For wide Mac and iPad panes, where a 1280×800 page is a band in the middle | Fills the view; zoom as Keep |
| **Set remote size** | A preset (1280×800, 1440×900, 1920×1080, 1024×768, 390×844) or a custom W×H, at DPR 1 or 2 | Same as Keep |
| **Mobile size** (iPhone and iPad) | Exactly the view: CSS px = view points, DPR = screen scale. Follows rotation, size classes, split view and the keyboard (debounced 150 ms) | Fills the view; pinch zoom (no double-tap delay) |

**Mobile size and mobile site.** Mobile size turns on mobile *layout* by default: Chromium's
`Emulation.setDeviceMetricsOverride {mobile: true}` (the meta viewport, overlay scroll bars,
text autosizing) and `Emulation.setTouchEmulationEnabled` (`pointer: coarse`,
`maxTouchPoints`), so responsive sites lay out as they do on a phone. The mobile **user agent**
is a separate toggle, "Request Mobile Website", off by default, because it changes what servers
send: some redirect to an `m.` host, and that page stays with the agent after hand-back.
Turning it on reloads the page; turning mobile size on or off never reloads (that would lose
form state mid-handoff). The user agent is Chrome for Android at the host's Chromium major,
which is honest about the engine.

### 16.2 Who owns the remote size

- The **agent's viewport** is the tab's own: set at `tabs.create`, by a v1 `resize`, or by a
  `resize` with `scope: "tab"`. Agent tools, screenshots and coordinates assume it.
- A **user viewport** is a `resize` with `scope: "control"`. It belongs to the connection that
  holds control and lasts while it does. The host keeps the agent's viewport beside it.
- **Hand-back restores the agent's size** (and turns emulation off). Release, the end of the
  grace period, and a `take` by another connection all restore it. The agent re-inspects the
  page after a handoff anyway, but a page re-laid out at 390 px (mobile menus, hidden columns,
  a different DOM) would break its plan and its coordinates; the desktop layout is what agents
  handle best. While the holder is gone during the grace period, the user viewport stays, so a
  reconnect mid-login does not reflow the page.
- A client that wants the agent's size back while it still holds control sends a
  `scope: "control"` resize equal to the agent's viewport with emulation off; the host then
  drops the user viewport.
- **Several viewers.** The viewport is per tab (one renderer), so every viewer sees the holder's
  viewport, letterboxed into its own view. A Mac watching an iPhone that holds control sees a
  phone-shaped page, marked by `viewport.scope: "control"` and `viewport.mobile`. When the Mac
  takes control, the host restores the agent's viewport and the Mac then applies its own mode.

### 16.3 Zoom and pan

- Zoom is a client-side transform of the video layer: the fit rectangle scaled by z (1–5×)
  about the pinch centroid, then offset by the pan. Input maps through the same transform (view
  point to unzoomed point to CSS px), so a tap lands on the pixel under the finger at any zoom.
  `RemoteZoomState` holds the math and has unit tests.
- One-finger pan moves the zoomed view first; what the view cannot absorb at its edge scrolls
  the page (scroll chaining, as Safari does between the visual and layout viewports). Two
  fingers always scroll the page. Pinch beyond the limits rubber-bands and snaps back.
- Double-tap zooms to 2.5× at the tap, or back to fit. It is off in Mobile size, as Safari turns
  it off for `width=device-width` pages, so taps there have no double-tap delay.
- **Crispness.** The video is encoded at the viewport's DPR, so 2.5× zoom of a DPR 1 stream is
  soft. Asking the host for a higher DPR or a region stream while zoomed is not cheap: Chromium's
  software raster is two thirds of the host's CPU (section 4.3), and it renders the whole
  viewport at the DPR whatever is encoded. DPR 2 doubles the scroll cost (720p scroll 27% → about
  51% of a core on the VM). So zooming never changes the stream; Set remote size offers DPR 2
  ("sharp text") as an explicit choice.

### 16.4 Scrolling

Two ways to scroll a remote page from touch, both implemented on the host and measured with
`browser-host/tools/scroll_bench.py`: the same flick (a 300 CSS px drag in 100 ms, 3000 px/s)
on a 10,000 px page at 1280×800 with the 30 fps cap, a fresh tab per trial, median of 5. Linux
is the VM (headless Ozone, ffmpeg + libx264); Mac is an M1 Max with the x264 CLI.

| | Wheel deltas with local momentum | CEF touch events (`SendTouchEvent`) |
|---|---|---|
| How | The client runs `UIScrollView`'s deceleration (rate 0.998/ms) and sends a wheel delta every display frame; Rust coalesces to 16 ms | Touch start, moves and end go to Chromium, whose gesture detector scrolls and flings |
| Host CPU while the page moves (process tree, % of a core) | Linux 28% (0.85 CPU-s over 3.0 s); Mac 29% (0.93 over 3.2 s) | Linux 34% (0.50 over 1.4 s); Mac 51% (0.07 over 0.14 s) |
| First input to the first scroll report / first video frame | Linux 4 / 14 ms; Mac 2 / 12 ms | Linux 23 / 33 ms; Mac 19 / 24 ms |
| Distance and duration | 1766 px over 3.0 s on both: the drag plus `UIScrollView` momentum | Linux 1995 px over 1.4 s (Chromium's fling); Mac 296 px over 0.14 s: a macOS host never flings a touch scroll, with or without mobile emulation |
| After it | Normal | On a macOS host the tab then ignores wheel events (the touch gesture never ends), so the two cannot be mixed |
| Momentum curve | iOS, computed locally | Chromium's Android fling, from host-side velocity |
| Network jitter | Changes only when deltas arrive | Skews the fling: CEF stamps touches on arrival, so jitter becomes velocity error |
| Rubber-band | Local, from the host's scroll reports | None on desktop Chromium |
| Page touch handlers (carousels, maps) | Not invoked | Invoked |

**Decision: wheel deltas with local momentum.** It costs less per second of motion, its first
frame comes about 20 ms sooner, it behaves the same on Linux and macOS hosts (touch does not
fling on macOS), and it gives the iOS deceleration curve the user asked for instead of
Chromium's shorter Android fling, local rubber-banding at the page's edges, and a fling that
network jitter cannot distort.
Touch stays in the protocol (`touch` feature) for a later "touch events" toggle for pages that
need real touches; the Apple client does not use it in v1.1. The host adds
`--disable-smooth-scrolling`, so each delta scrolls at once instead of starting a 150 ms
animation that would stack on the client's own momentum.

Gestures, all modes: tap clicks; one finger scrolls (with chaining when zoomed); two fingers
scroll; momentum continues after release with `UIScrollView`'s rate; at the top or bottom of
the page (from `scroll` reports) the video rubber-bands locally and springs back; a two-finger
tap right-clicks. In Keep and Set remote size, a one-finger drag that starts on the page's
right or bottom edge (the classic scroll bar's 16 CSS px, at least 22 points) is a mouse drag,
so the scroll bar thumb can be grabbed and dragged; long press and drag is a mouse drag anywhere.
Mobile size has overlay scroll bars, so the client draws an iOS scroll indicator from the
`scroll` reports, and dragging it scrubs the page.

### 16.5 Copy and paste

- **Never the remote OS clipboard.** CEF's `CefFrame::Copy()`/`Paste()` use the system
  clipboard: on a macOS runner that is the user's real pasteboard, and on Linux it would be
  shared by every tab. The host instead reads and writes text through the page:
  - `copy` and `cut` run a script in the main world that takes the selection (the focused
    field's `selectionStart`..`selectionEnd`, else `getSelection()`), dispatches a synthetic
    `copy` event so pages that rewrite copied text still can, and returns the text; `cut` then
    deletes it with `execCommand('delete')`. Password fields return nothing. When the
    selection is inside an iframe, the host falls back to the text of CEF's
    `OnTextSelectionChanged`.
  - `paste` dispatches a synthetic `paste` event carrying the text; if the page does not cancel
    it, `execCommand('insertText')` inserts it (undoable, fires `input`), and if that fails,
    CDP `Input.insertText`.
  - `select_all`, `undo`, `redo` and `delete` use the focused frame's `CefFrame` editing
    commands, which do not touch the clipboard.
- The host answers `copy` and `cut` with `clipboard {op, text}` to the requesting connection
  only; the client writes it to `UIPasteboard`. Paste reads `UIPasteboard` only when the user
  picks Paste (no paste prompt).
- **Long press** selects the word under the finger (a double click at the point), and dragging
  after it extends the selection by word (Chromium's double-click drag). The edit menu
  (`UIEditMenuInteraction`) then appears at the selection rectangle from the host's
  `selection` report (16.6), or at the finger before the report arrives: Cut, Copy, Paste and
  Select All, filtered by whether the focus is editable and whether anything is selected.
  Hardware ⌘C, ⌘X, ⌘V, ⌘A, ⌘Z go to the same edit commands instead of being sent as keys (a
  Linux page would see Meta+C, and a macOS runner would copy to its own pasteboard).

### 16.6 Protocol additions

Features in the host's `hello`: `viewport_scope`, `mobile_emulation`, `edit`, `selection`,
`scroll_metrics`, `touch`. Features in the client's `hello`: `selection` and `scroll_metrics`
(the reports it wants). The host sends `selection` and `scroll` only to connections that asked,
and a client sends a v1.1 message only when the host announced its feature.

Client → host:

| `type` | Fields | Gate | Feature |
|---|---|---|---|
| `resize` | v1 fields, plus `scope?: "tab" \| "control"` (absent: `tab`, the v1 meaning) and `mobile?: "off" \| "layout" \| "site"` (absent: `off`; anything else forces `scope: control`) | holder | `viewport_scope`, `mobile_emulation` |
| `edit` | `op` (`copy`, `cut`, `paste`, `select_all`, `undo`, `redo`, `delete`), `text?` (required for `paste`, at most 512 KiB UTF-8) | holder | `edit` |
| `touch` | `kind` (`start`, `move`, `end`, `cancel`), `id` (u32, stable per finger), `x`, `y`, `radius?`, `pressure?` (0–1), `modifiers` | holder | `touch` |

Host → client:

| `type` | Fields | When |
|---|---|---|
| `viewport` | v1 fields, plus `scope: "tab" \| "control"`, `mobile: "off" \| "layout" \| "site"`, and `agent?: viewport` (the agent's viewport while `scope` is `control`) | As in v1; v1 clients ignore the extra fields |
| `clipboard` | `op` (`copy`, `cut`), `text` | Reply to `edit copy` or `edit cut`, to that connection only |
| `selection` | `editable: bool`, `collapsed: bool`, `length` (UTF-16 units), `rect?: rect` | When the selection or caret changes (at most every 100 ms, trailing), to connections with `selection` |
| `scroll` | `x`, `y` (the main frame's scroll offset), `content_w`, `content_h`, `viewport_w`, `viewport_h` (layout viewport), all CSS px | After setup and on scroll, load and resize (at most every 33 ms, trailing), to connections with `scroll_metrics` |

Rules: a `resize` equal to the current viewport (same size, DPR, scope and emulation) changes
nothing and sends no IDR. `edit` with nothing selected answers `clipboard` with empty text. A
refused or malformed v1.1 message gets the v1 `error` codes. Fixtures for every new message are
in `client-core/fixtures/remote_browser/messages/` (`*_v1_1.json` names, plus
`hello_v1_1.json`).

### 16.7 Negotiation and fallbacks

- v1 client, v1.1 host: the client's `hello` lists no features, so it gets no `selection` or
  `scroll`; its `resize` is tab-scoped exactly as before. The extra `viewport` fields are
  ignored.
- v1.1 client, v1 host: the host's `hello` lists no features. Rust then sends a user viewport as
  a plain `resize` and remembers the agent's viewport, restoring it itself before `release`
  (only a client that disconnects without releasing leaves its size behind). Mobile emulation,
  `edit`, `touch` and the reports are unavailable; Rust reports the call as unsupported and the
  client hides those menu items.

### 16.8 Notices and keyframes

- Notices carry `user_facing`. Only actionable ones reach the UI, in plain words, for five
  seconds: a page that failed to load, a view-only tab, an unsupported action, an old host.
  Internal host errors, unknown or malformed frames and video drops go to the log.
- x264 reads its qpfile with `fscanf(" %99[^\n]\n")`, whose trailing whitespace directive
  buffers the start of the next line, and closes the file at EOF. So the host pads every line
  with 16 KiB of leading spaces (each seek then leaves stdio's buffer and re-reads the file),
  and a keyframe asked for on the frame right after a forced IDR, which x264 cannot see, is
  asked for again on the next frame instead of switching the encoder to restarts.
- The macOS host loads the CEF framework before creating `NSApplication`. AppKit starts App
  Intents' process registration on a worker queue, and CEF's static initializers racing it
  crashed the host at launch (`EXC_BREAKPOINT`); `tools/soak_test.py` launches the host
  repeatedly and fails on any new crash report.

### 16.9 Client architecture

- **Rust core** owns the wire models, the negotiation, and the viewport request: the client
  states the viewport it wants (`set_viewport`), and the attach machine sends it when this
  connection gains control, re-sends it after a reconnect, drops duplicates, and restores the
  agent's viewport for a v1 host. Snapshots carry the viewport scope and emulation, the scroll
  metrics, the selection and the host's v1.1 capabilities; `on_clipboard` delivers copied text.
- **Swift** (`OmnigentRemoteBrowser`): `RemoteViewportMode` (the menu's model and persistence),
  `RemoteZoomState` and `RemoteScrollPhysics` (pure math, unit-tested), the iOS touch
  controller (gestures above, momentum on a `CADisplayLink`), the edit menu and pasteboard, and
  a keyboard proxy (`UIKeyInput`) that shows the software keyboard while a remote field has
  focus.

### 16.10 iOS chrome

The iPhone and iPad tab follows Safari on iOS 26 (`RemoteBrowserTouchLayout`); the Mac keeps
the local browser's toolbar.

- **iPhone.** The app's navigation bar is hidden for the tab. A floating Liquid Glass address
  pill sits at the top (the page menu, the domain with a lock for HTTPS, reload or stop, and the
  loading progress along its edge); tapping the domain opens the full address, selected, with
  Clear, Cancel and Go. A floating toolbar at the bottom holds back, forward, share, Take Over or
  Hand Back, and the app's tab overview. The page runs under the toolbar and the home
  indicator. The page menu holds Sessions (the way back to the list), control, Copy Link, Reset
  Zoom, the Viewport submenu (16.1), Request Mobile or Desktop Website, and the profile.
- **iPad.** The app's tab strip stays; one bar under it holds back, forward, the pill, share and
  control.
- **Collapse on scroll** (iPhone, while this client holds control): the host's `scroll`
  reports drive it, since the page is not a local scroll view (`RemoteChromeCollapse`). 24 CSS
  px down past the first 44 collapses the pill to the domain and hides the toolbar; 24 px up, the
  top of the page, a new page or a tap on the domain brings them back. A report whose viewport
  height changed is a resize, not a scroll, so the bars' own resize never toggles them. In the
  modes that follow the view, collapsing resizes the remote by the pill's height, as Safari's
  bars change `innerHeight`.
- **Theme colour.** The status bar area and the pill take the colour of the page's top edge,
  sampled on the client from the displayed frame (`AVSampleBufferVideoRenderer`'s displayed pixel
  buffer, 300 ms after video arrives) when most of the top rows share one colour
  (`RemoteEdgeColor`). No protocol change.
- **Handoff.** When the agent asks for the user, a slim banner above the toolbar says why, with
  Take Over; the control button stays pink after it is dismissed.

## Sources

- Reference conversation: https://chatgpt.com/share/6ae7abe0-24e8-8328-be92-1b4424cda23d
- OpenH264 (BSD, real-time, Constrained Baseline, dynamic rate and IDR): https://github.com/cisco/openh264
- OpenH264 usage types (`SCREEN_CONTENT_REAL_TIME`): https://github.com/cisco/openh264/blob/master/codec/api/wels/codec_app_def.h
- OpenH264 processing modules (scroll, background and scene-change detection): https://github.com/cisco/openh264/tree/master/codec/processing/src
- OpenH264 slow-encode report: https://github.com/cisco/openh264/issues/2962
- Cisco binary and MPEG LA conditions: http://www.openh264.org/BINARY_LICENSE.txt
- Screen-content encoder comparison (BD-rate and time: OpenH264, x264, x265): https://fluendo.com/blog/benchmarking-remote-desktop-coding-tools-for-daas-and-vdi/
- WebRTC screen-share CPU and bandwidth (H.264, VP8, VP9, AV1): https://www.gethopp.app/blog/screensharing-encoders-compared
- Neko capture docs (x264 zerolatency pipelines, screencast not for primary stream, client cursor): https://neko.m1k1o.net/docs/v3/configuration/capture
- Sunshine software-encoder defaults (superfast, zerolatency): https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html
- Moonlight iOS renderer (AVSampleBufferDisplayLayer): https://github.com/moonlight-stream/moonlight-ios/blob/master/Limelight/Stream/VideoDecoderRenderer.m
- Moonlight-qt AVSampleBufferDisplayLayer latency discussion: https://github.com/moonlight-stream/moonlight-qt/issues/1885
- VideoToolbox low-latency encoding (WWDC21): https://developer.apple.com/videos/play/wwdc2021/10158/
- AV1 codec type and hardware-decode check: https://developer.apple.com/documentation/coremedia/kcmvideocodectype_av1
- Chromium VideoToolbox decoder (AV1 hardware gate): https://chromium.googlesource.com/chromium/src/+/HEAD/media/gpu/mac/video_toolbox_video_decoder.cc
- `DisplayImmediately` sample attachment: https://developer.apple.com/documentation/coremedia/cmsamplebuffer/persampleattachmentsdictionary/key/displayimmediately
- CDP Page domain (`startScreencast`, experimental): https://chromedevtools.github.io/devtools-protocol/tot/Page/
- Playwright `connectOverCDP` (lower fidelity note): https://playwright.dev/docs/api/class-browsertype
- CEF settings (`root_cache_path` singleton, `persist_session_cookies`, `remote_debugging_port`): https://github.com/chromiumembedded/cef/blob/master/include/internal/cef_types.h
- CEF headless-Ozone OSR key crash: https://github.com/chromiumembedded/cef/issues/3902
- CEF OSR incomplete frames: https://github.com/chromiumembedded/cef/issues/4166
- CEF Alloy WebUI and password-manager crash: https://github.com/chromiumembedded/cef/issues/3763
- CEF builds (Linux minimal distributions): https://cef-builds.spotifycdn.com/index.html
- Chromium Linux password storage (basic store is plain text): https://chromium.googlesource.com/chromium/src/+/HEAD/docs/linux/password_storage.md
- Chromium Ozone overview (headless platform): https://github.com/chromium/chromium/blob/main/docs/ozone_overview.md
- Local measurements (JPEG and WebP): scratch dir `/private/tmp/claude-502/remote-browser/` (`bench.sh`, frames)
