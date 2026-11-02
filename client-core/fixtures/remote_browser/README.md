# Remote browser protocol v1 fixtures

Shared by the host (C++), the runner and server (Python), the Rust core and the Swift client.
The contract is section 5 of `apps/apple/docs/remote-browser-design.md`. Every message and
frame type in it has at least one example here. Rust consumers: `omnigent-protocol`
`remote_browser::fixture_tests` and `omnigent-core` `remote_browser::codec` tests.

## Layout

- `messages/host_to_client/*.json`, `messages/client_to_host/*.json`: one WebSocket text frame
  each (section 5.4). `hello_view_handoff.json` and `cursor_unknown.json` carry unknown fields,
  features and values that a receiver must accept; `unknown_type.json` is a message type a
  receiver must ignore. `*_v1_1.json` are the protocol v1.1 additions (design doc section 16):
  `hello_v1_1` with every feature, a control-scoped mobile `viewport`, `clipboard`, `selection`
  and `scroll` from the host; the client's `hello` asking for the reports, scoped and mobile
  `resize`, `edit` and `touch`.
- `runner_host/*.json`: the runner ⇄ host connection preambles, control requests and
  responses, and a `host.json` example (section 5.7).
- `rest/*.json`: `{request: {method, path, body}, status, body}` for one REST call
  (section 5.10).
- `h264/<name>.annexb`: an H.264 Annex-B elementary stream, IDR first with SPS/PPS inline, then
  deltas. Every access unit starts with an access unit delimiter and has several slices.
  `h264/<name>.frames.json` lists each access unit's `offset`, `length`, `keyframe`,
  `pts_us` and NAL types, plus the stream's `width`, `height` and SPS/PPS (hex, no start code).
  - `testsrc_1280x800`: 30 frames, 1 IDR + 29 deltas.
  - `testsrc_640x400`: 8 frames; its IDR is a format change after `testsrc_1280x800`.
- `jpeg/`: a 1280x800 still and a 320x200 thumbnail.
- `binary_frames/*.bin`: complete WebSocket binary frames (24-byte `RB` header, then payload).
  `binary_frames/index.json` gives each file's decoded header and where its payload comes from
  (`frame_index` into a `.frames.json`, or a JPEG file). Entries with `valid: false` must be
  rejected with the named error (`bad_magic`, `truncated`, `bad_header_len`,
  `unsupported_version`). `unknown_kind.bin` is valid but of a kind receivers ignore after
  acking; `extended_header.bin` has `header_len` 32.
- `unix_socket/*.bin`: complete runner ⇄ host socket frames (`u32` LE length, `u8` kind,
  payload). `unix_socket/index.json` describes each one.

## How the media was made

Encoded on the Linux x86_64 test VM (`ssh arca_qemu2.ssh`, Ubuntu `ffmpeg 7:6.1.1-3ubuntu5`
with `libx264-164 0.164.3108`, the encoder family the host runs), from ffmpeg's `testsrc`
pattern:

```sh
X264="keyint=infinite:min-keyint=infinite:scenecut=0:aud=1:repeat-headers=1:bframes=0:ref=1"
ffmpeg -nostdin -f lavfi -i testsrc=size=1280x800:rate=15 -frames:v 30 -pix_fmt yuv420p \
  -c:v libx264 -preset ultrafast -tune zerolatency -profile:v baseline -crf 32 \
  -x264-params "$X264" -f h264 testsrc_1280x800.annexb
ffmpeg -nostdin -f lavfi -i testsrc=size=640x400:rate=15 -frames:v 8 -pix_fmt yuv420p \
  -c:v libx264 -preset ultrafast -tune zerolatency -profile:v baseline -crf 32 \
  -x264-params "$X264" -f h264 testsrc_640x400.annexb
ffmpeg -nostdin -f lavfi -i testsrc=size=1280x800:rate=15 -frames:v 1 -pix_fmt yuvj420p \
  -c:v mjpeg -q:v 8 still_1280x800.jpg
ffmpeg -nostdin -f lavfi -i testsrc=size=320x200:rate=15 -frames:v 1 -pix_fmt yuvj420p \
  -c:v mjpeg -q:v 8 thumbnail_320x200.jpg
```

Derived files:

- Access units are split at each access unit delimiter (NAL type 9). An access unit runs from
  its delimiter's start code to the next delimiter's start code.
- `pts_us` of frame `i` is `1_000_000 + round(i * 1_000_000 / 15)`.
- Each `binary_frames/*.bin` is `struct.pack("<HBBHHIIQ", 0x4252, 1, kind, flags, header_len,
  seq, stream_id, pts_us)`, then `header_len - 24` zero bytes, then the payload. The values
  are in `index.json`.
- Each `unix_socket/*.bin` is `struct.pack("<IB", len(payload), kind)` and then the payload.
  The close payload is `struct.pack("<H", code)` and then the UTF-8 reason.

The Rust fixture tests rebuild every `.bin` from these rules and compare bytes, so the files
and this description cannot drift apart.
