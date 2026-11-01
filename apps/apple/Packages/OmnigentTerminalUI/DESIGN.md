# OmnigentTerminalUI: session terminals on libghostty

Session terminals render with libghostty (Ghostty's terminal core and Metal renderer) on macOS,
iPhone and iPad. Every Omnigent terminal is remote: its bytes arrive over the attach WebSocket,
and keystrokes and resizes go back over it. That holds for user shells and for a native
harness's own TUI (Claude Code, Codex, Pi). Both platforms use one code path for this.

Pieces:

- **`client-core` `omnigent-core::terminal`** (Rust, sans-IO). Terminal REST, the attach
  codec, the `TerminalAttach` state machine (reconnect, close codes, auth), the terminal
  inventory, and harness-terminal discovery.
- **`Packages/OmnigentGhosttyKit`**. One `binaryTarget` wrapping `GhosttyKit.xcframework`
  (macOS universal, iOS device and iOS simulator slices), plus the link settings. The macOS and
  iOS terminal UI both depend on it.
- **`Packages/OmnigentTerminalUI`**. The `TerminalConnection` protocol,
  `TerminalSurfaceController` (one libghostty surface), the AppKit and UIKit surface views,
  `SessionTerminalView`, `TerminalListView`, settings, and `TerminalGalleryView`.
- **`scripts/fetch-ghostty.sh`**. Fetches and verifies the pinned libghostty source, builds it
  with the pinned Zig, and stages the xcframework in the gitignored `Vendor/ghostty/out/`.

## 1. Which libghostty

Two things are needed, on both platforms:

1. A surface that renders bytes the embedder supplies, with the encoded input handed back, and
   no local pty.
2. An iOS slice of the full GhosttyKit, meaning the surface plus the Metal renderer, not just
   `libghostty-vt`.

| Option | External byte I/O | iOS full-surface slice | Maintenance |
|---|---|---|---|
| **Upstream ghostty-org/ghostty** (v1.4.0, main at 2fc8d02, 2026-10-31) | **No.** `termio/backend.zig` has one backend, `exec` (a pty plus a child process). `ghostty_surface_config_s` has no I/O mode, and nothing exports `processOutput`. | **No.** `src/build/Config.zig` fails the build for iOS unless it is `-Demit-lib-vt`: "The full Ghostty build no longer supports iOS". | Lowest, but it does not meet the requirements. |
| **Upstream `libghostty-vt`** (`-Demit-lib-vt`, iOS and macOS xcframework) | Yes: it is a pure VT state machine with key, mouse and paste encoders. | Yes. | It has **no renderer**: `render.h` exposes render *state* (rows, cells, dirty flags). We would have to write and own a Metal or Core Text renderer, fonts, shaping, cursor and selection painting. That is not "Ghostty's renderer". |
| **Upstream plus a patch set we carry** | We would port a `manual` termio backend (`termio/Manual.zig`, about 150 lines), the `io_mode` and `io_write_cb` surface config, and `ghostty_surface_process_output`. | We would have to restore iOS in the full build, which upstream removed on purpose: the iOS apprt, `NullPty`, external-render plumbing in `renderer/Thread.zig` and the xcframework slices. | High. It is a fork in all but name, rebased by us. |
| **manaflow-ai/ghostty** (MIT fork used by cmux) | **Yes**: `GHOSTTY_SURFACE_IO_MANUAL` and `GHOSTTY_SURFACE_IO_MANUAL_MIRROR`, `io_write_cb` and `io_write_userdata`, and `ghostty_surface_process_output()`. | **Yes**: `-Demit-xcframework -Dxcframework-target=universal` emits `macos-arm64_x86_64`, `ios-arm64` and `ios-arm64-simulator`, with iOS "external render" support (`ghostty_surface_render_now`). | Medium. It is about 790 commits ahead of and about 1,900 behind upstream, and maintained for cmux's own iOS and macOS apps. Its fork-only API is marked "delete when upstream exposes …", so names can churn when we bump. |

**Decision: pin the manaflow-ai fork** at commit `2c1a19d7e4fae25ed2224da65592215c9013c785`
(2026-10-12). It is the only option that gives Ghostty's own renderer on iOS with embedder-owned
I/O today. Mitigations:

- `fetch-ghostty.sh` verifies the source tarball's SHA-256.
- Before building, it checks that every fork symbol we use is in `ghostty.h`
  (`REQUIRED_SYMBOLS`), so an incompatible bump fails loudly before any Swift compiles.
- All fork-specific calls are in four files: `GhosttyRuntime`, `TerminalSurfaceController`
  (and its two extensions) and the two surface views. A move to upstream (once it exposes
  embedder I/O) or to our own patch set touches only those.
- The tarball is the GitHub archive of an exact commit. If the fork goes away, mirror that
  tarball (the checksum is unchanged) and point `fetch-ghostty.sh` at the mirror.

Only Omnigent's own code and MIT-licensed Ghostty code are used. cmux itself (GPL-3.0-or-later,
with BUSL-1.1 server parts) was not read or copied. The only facts taken from it are the
architectural ones relayed in the task: one shared GhosttyKit binary for macOS and iOS, raw
bytes fed to `ghostty_surface_*` on iOS, and a C++ runtime link.

### Licenses

- Ghostty and the manaflow-ai fork are MIT, Copyright (c) 2024 Mitchell Hashimoto and Ghostty
  contributors. `fetch-ghostty.sh` stages the license as `Vendor/ghostty/out/LICENSE`. The apps
  must ship it in their acknowledgements; see `THIRD_PARTY_NOTICES.md`.
- `Platform/HIDKeyCodes.swift` is generated from Ghostty's `src/input/keycodes.zig`, which is
  derived from Chromium's `dom_code_data.inc` (BSD-3-Clause).
- Files adapted from Ghostty's `macos/` sources carry an attribution header.

## 2. Getting GhosttyKit

- **No verifiable prebuilt.** Releases are source tarballs, `Ghostty.dmg`, and on the rolling
  `tip` release a `ghostty-vt.xcframework.zip` (lib-vt only, no renderer). `tip` is replaced on
  every push, so its digest cannot be pinned. Neither upstream nor the fork publishes the full
  GhosttyKit xcframework, so we build it from source.
- **Toolchain.** The fork's `build.zig.zon` sets `minimum_zig_version` to `0.16.0` (upstream
  v1.4.0 needs 0.17.0). The script runs `mise install zig@0.16.0` and checks that Zig matches
  `build.zig.zon`. The Xcode Metal toolchain is required
  (`xcodebuild -downloadComponent MetalToolchain`); without it the shader step fails. Zig
  fetches its own dependencies and verifies them by their `build.zig.zon` hashes.
- **Build.** `zig build -Doptimize=ReleaseFast -Demit-xcframework=true
  -Dxcframework-target=universal -Demit-macos-app=false -Demit-docs=false
  -Dversion-string=<zon>+omnigent.<sha>`. The explicit version string stops Ghostty from
  running `git describe` on the enclosing Omnigent checkout. A cold build took 6 min 54 s on an
  M-series Mac, and a rerun with an unchanged stamp takes 0.8 s. The output is about 516 MB of
  static libraries; only the linked code ends up in the app.
- **CI.** Cache `apps/apple/Vendor/ghostty/{downloads,zig-cache,out}` keyed on the hash of
  `scripts/fetch-ghostty.sh`, and install the Metal toolchain before the step.
- **Linking.** The static library carries C++ objects (glslang, SPIRV-Cross), so
  `OmnigentGhosttyKit` links `libc++` plus Metal, QuartzCore, CoreText, CoreGraphics,
  CoreVideo, IOSurface, Foundation, AppKit and Carbon on macOS, and UIKit on iOS.
- **Simulator arch.** The fork builds the simulator slice for arm64 only (its build forces an
  Apple CPU model). An app target must set `EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64`, or
  build for a concrete arm64 simulator. A `generic/platform=iOS Simulator` build of an app
  fails to link otherwise.

## 3. Remote I/O

Spike result: a surface in `GHOSTTY_SURFACE_IO_MANUAL_MIRROR` mode renders a remote byte stream
and returns correctly encoded input. The tests in `Tests/OmnigentTerminalUITests` prove each
point on macOS and on the iPhone simulator, and the gallery shows a live local-server zsh on
both.

```
WebSocket ──binary──► Rust TerminalAttach ──AttachOutput::Output──► TerminalConnection.output
   ▲                                                                       │
   │                                          TerminalSurfaceController.feed │ ghostty_surface_process_output
   │                                                                       ▼
   │                                                          Ghostty parser + Metal renderer
   │                                                                       │ io_write_cb (termio thread)
   └──binary◄── AttachInput::Input ◄── TerminalConnection.send ◄──────────┘
```

- **Output.** `ghostty_surface_process_output(surface, bytes, len)` takes the renderer mutex
  and is thread-safe. We call it on the main actor from the connection's output stream. A
  `TerminalOutput.resetScreen` (the Rust machine's `ResetScreen`, emitted on every reattach)
  feeds `ESC c` (RIS). The server's next frame is a `capture-pane` seed of the current screen
  that starts with `CSI H CSI 2J`.
- **Input.** Ghostty encodes keys, IME commits, paste and mouse reports according to the modes
  the remote program set through its output: DECCKM, the kitty keyboard flags,
  modifyOtherKeys, bracketed paste and the SGR mouse modes. It then calls `io_write_cb` on its
  I/O thread. `SurfaceInputSink` passes the bytes through an `AsyncStream` to the main actor,
  and from there to `TerminalConnection.send`. The Rust machine sends each call as one binary
  frame, and the server injects it into tmux byte-exact with `send-keys -H`.
- **Why `MANUAL_MIRROR`.** tmux is the pane's real terminal and already answers terminal
  queries. The capture's `tmux-replies` frame lists 44 of them, including `da1`, `da2`,
  `dsr:6`, `decrqm:*`, `decrqss:*`, `osc:10` and `osc:11`. `MANUAL_MIRROR` suppresses Ghostty's
  parser-generated replies, so a program never gets two answers to one query. The web client
  does the same per query (`TerminalQueryReplies.ts`). The cost: a query tmux does not answer
  (for example `osc:4` on this tmux) gets no reply, and the program times out, which is safe.
  A double answer would be typed into the program.
- **Resize.** The view reports points and scale; the controller calls
  `ghostty_surface_set_size`, then reads `ghostty_surface_size()` for the grid. On a change it
  calls `TerminalConnection.resize`, which feeds the Rust `AttachInput::Resize`. The machine
  de-dupes the size, holds it until the socket opens, and sends
  `{"type":"resize","cols":N,"rows":M}` first on every attach. Verified live: zsh reports
  `tput cols` = 110 and `lines` = 39 for a 900x600 pt Mac window.
- **Scrollback.** It is local to the Ghostty surface (`scrollback-limit`; the setting offers
  2, 10 and 50 MB). It covers everything streamed since the attach. tmux history from before
  the attach is not replayed: the server seeds only the visible screen, as on the web. A
  reattach resets it.
- **Clipboard.** `clipboard-read` and `clipboard-write` (OSC 52) are denied. tmux copy-mode
  selections arrive as `clipboard-write` frames (`TerminalOutput.clipboardWrite`), and the view
  asks before writing the local clipboard. User copy and paste go through Ghostty's bindings and
  the platform pasteboard.
- **Threading.** One `ghostty_app_t` per process, ticked on the main thread after each
  `wakeup_cb`. Action and clipboard callbacks arrive on the app thread (main). They regain
  main-actor isolation with `MainActor.assumeIsolated`, and log rather than race if ever called
  elsewhere. `io_write_cb` runs on the surface's I/O thread and touches only a `Sendable` sink.

Rejected alternatives:

- **`libghostty-vt` with our own renderer.** It is not Ghostty's renderer, and it would mean a
  large new rendering surface to maintain.
- **A local pty pair bridged to the socket.** iOS has no pty (`NullPty`) or subprocess. In the
  Mac App Store sandbox it needs a helper binary. It also adds a line discipline that must be
  kept raw, and needs a side channel for size. It would mean two code paths.

## 4. iOS and iPadOS

The fork's iOS surface works with the same manual I/O. One difference found in the spike: on
iOS the fork renders in **external render mode**. Ghostty does not present frames from its own
thread there. It emits `GHOSTTY_ACTION_RENDER`, and the embedder calls
`ghostty_surface_render_now` on the main thread. `TerminalSurfaceUIView` drives this from a
`CADisplayLink` that runs only while a frame is pending, so bursts coalesce into one frame per
refresh. While the view is focused, a 0.5 s tick keeps the cursor blinking. Without it, only
the first frame shows.

Input:

- **Software keyboard.** `UIKeyInput` plus a minimal `UITextInput` covering only the text being
  composed, so IMEs (Japanese, Chinese, Korean) compose with Ghostty preedit and commit through
  `ghostty_surface_text_input`. Autocorrect, smart quotes and predictions are off.
- **Accessory row** (`TerminalAccessoryBar`): esc, sticky ctrl and alt, tab, arrows,
  `~ | / - backtick`, paste and hide keyboard. Arrows and esc go through Ghostty's encoder
  (`press(_:)`), so application cursor mode and the kitty protocol apply. Ctrl plus a letter
  sends the real chord.
- **Hardware keyboards** (iPad, simulator). `pressesBegan` and `pressesEnded` translate
  `UIKey.keyCode` (HID usage) to the macOS keycode libghostty expects on both platforms
  (`HIDKeyCodes`), with modifiers. Non-text keys and Ctrl, Alt or Cmd chords go straight to
  `ghostty_surface_key`; plain text goes through the text system so IMEs work.
- **Touch.** A one-finger pan scrolls the scrollback with precise deltas and momentum (or sends
  wheel reports when the program tracks the mouse). A tap focuses, or clicks in mouse-tracking
  TUIs. A long press with drag selects, with Shift forced so selection works over
  mouse-tracking TUIs, then shows the edit menu (Copy, Paste, Select All).
- **Pasteboard privacy.** A paste the user starts (edit menu, accessory button) reads
  `UIPasteboard` without a prompt. `controller.paste(_:)` takes explicit text for programmatic
  paste.

The Mac uses the identical surface and connection path. Only the view classes differ:
`TerminalSurfaceNSView` handles `NSTextInputClient` IME, the mouse, the scroll wheel with
momentum, `performKeyEquivalent` for Ghostty bindings (Cmd-C, Cmd-V, Cmd-F, Cmd-A), and a
context menu. On macOS Ghostty renders on its own thread.

## 5. The harness TUI terminal (native sessions)

How the web does it:

- `web/src/shell/AppShell.tsx`: `terminalFirst = sessionLabels["omnigent.ui"] === "terminal"`,
  and `agentTerminal = findAgentTerminal(terminals)`.
- `web/src/hooks/useTerminals.ts` defines `AGENT_TERMINAL_IDS`: `terminal_claude_main`,
  `terminal_codex_main`, `terminal_pi_main`, `terminal_tui_main` (the embedded Omnigent REPL of
  SDK sessions) and the other native harnesses.
- The Terminal view attaches to that terminal through the same
  `/v1/sessions/{id}/resources/terminals/{tid}/attach` socket as a shell.
- While no agent terminal exists, the "starting" spinner comes from `terminal_pending` (the
  snapshot field or the `session.terminal_pending` event) plus runner liveness.
- An interactive attach requires owner level (`readOnly={!isOwnerLevel(permissionLevel)}`;
  the server's `_authorize_terminal_attach` requires `LEVEL_OWNER` = 4 for writes). Anyone else
  attaches read-only, and the server drops their input.

The core models exactly this (`terminal/session.rs`):

- `TerminalInventory::harness_terminal(labels, terminal_pending)` returns `NotTerminalFirst`,
  `StartingUp`, `Unavailable` (stopped, so offer Resume) or `Ready { terminal }`.
- `attach_options(permission_level, host_id)` returns `read_only` for anything below owner and
  `slice_key` = the session's host id. A wrong-replica 4400 retries once without the slice key.

Fidelity, verified with the synthesized harness TUI and the recorded REPL:

- Full-screen redraws, the alternate screen (`?1049`), hidden and shown cursor, truecolor and
  256-color, curly underline, and box drawing: Ghostty's renderer handles them natively.
- Mouse reporting (`?1000` and `?1006`): Ghostty encodes SGR reports, and the iOS tap and
  scroll paths forward to them when the program captures the mouse.
- Bracketed paste (`?2004`): `paste` wraps it, as the test shows.
- Kitty keyboard and modifyOtherKeys: Ghostty's encoder follows the program's flags.
  Escape becomes `CSI 27 u` under flag 1, as the test shows.

Caveat: on a reattach the server's `capture-pane` seed restores the picture but not the
program's terminal modes (alternate screen, mouse, kitty flags). The web client has the same
gap. TUIs usually re-emit their modes on the next redraw; a follow-up could send a size nudge
on reattach to force a redraw.

## 6. Hand-off

### Rust API (`omnigent_core::terminal`)

- `TerminalEndpoint::new(server_url, session_id)`, with `list_request(&ListTerminals)`,
  `create_request(&CreateTerminal)`, `get_request(id)`, `delete_request(id)` and
  `attach_request(id, &AttachOptions)`. They return `HttpRequest`s; the caller adds auth and
  Databricks headers.
- `list_response`, `resource_response` and `delete_response(id, result)` return
  `Result<_, TerminalError>`. A delete 404 is `DeleteOutcome::AlreadyGone`. A create may be
  retried with the same `session_key`: the runner launch is idempotent per key.
- `TerminalAttach::new(AttachConfig, AttachOptions, jitter)` with `handle(now_ms, AttachInput)
  -> Vec<AttachOutput>`. The inputs are `Start`, `Stop`, `Foreground`, `Input`, `Resize`, plus
  the WebSocket sink and timer callbacks.
- `TerminalInventory`: `apply_snapshot`, `apply_event`, `rows`, `user_shells`,
  `agent_terminal`, `harness_terminal`, `next_activity_expiry`.

### Proposed FFI (for the omnigent-ffi agent)

- A UniFFI object `TerminalAttachDriver` wrapping `TerminalAttach` and executing outputs with
  the existing `WebSocketTransport` host and timer plumbing. It exposes `start`, `stop`,
  `foreground`, `send_input(bytes)` and `resize(cols, rows)`, and calls a foreign listener with
  `on_state(FfiAttachState)`, `on_output(bytes)`, `on_reset_screen()`,
  `on_clipboard_write(text)` and `on_input_dropped(len, reason)`.
- Mirror records for `TerminalResource`, `TerminalRow` and `TerminalStatus`, with functions
  `terminal_list`, `terminal_create`, `terminal_delete` and `harness_terminal` on the session
  client.
- **Host trait change:** `WebSocketHandle` has only `send_text`, but terminal input is binary.
  Add `fn send_binary(&self, bytes: Vec<u8>) -> impl Future<Output = Result<(), TransportError>>`
  (or a general `send(SocketMessage)`) in `realtime/host.rs`, and the matching
  `URLSessionWebSocketTask.send(.data(...))` in `URLSessionEventStreamTransport`.

### Swift

- Implement `TerminalConnection` on top of `TerminalAttachDriver`. `state` and `states` come
  from `on_state`; `output` yields `.bytes`, `.resetScreen` and `.clipboardWrite`.
- Keep one `TerminalSurfaceController` per attached terminal in the session store, so a
  Chat/Terminal switch keeps the screen. Then use `SessionTerminalView(controller:)`.
  `SessionTerminalView(connection:)` is the self-contained variant.

## 7. Known gaps

- Read-only viewers have no "attach interactively" escalation; the server decides on reattach.
- The direct-attach loopback URL (`metadata.direct_attach_url`) is parsed and validated but not
  used. The relay path is always used.
- Per-query reply suppression (attach in `MANUAL`, suppress only what tmux lists) needs a fork
  API; `MANUAL_MIRROR` is the safe approximation.
- The App Store (sandboxed) edition is fine: manual I/O spawns nothing. This has not been
  verified inside the sandboxed build yet.
