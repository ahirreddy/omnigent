# Omnigent Web Layer (OWL) design

Chromium support in the Developer ID Mac app, modelled on ChatGPT Atlas's "OWL" (OpenAI's Web
Layer): Chromium runs in its own process, the **web host**, and the Swift app is a thin **client**
that embeds its pixels, forwards input and drives navigation over IPC. This replaces the earlier
in-process CEF bridge (`OmnigentCEFBridge`), its NSApp swizzling, its external message pump, and
the five helper apps embedded directly in the Mac app.

The host is built on the prebuilt CEF 156 distribution. Nothing here builds Chromium from
source. The client API (`Session`, `Profile`, `WebView`, `WebContentRenderer`, `LayerHost`) is
shaped so that a custom Chromium content-API host could replace the CEF host later without
changing it; see "Path to a custom Chromium host".

## Components

| Piece | Where | Language |
|---|---|---|
| Wire schema and Mach transport | `Sources/OWLProtocol` (`owl_protocol.h`, `owl_channel.{h,c}`) | C, shared by both sides |
| Client library | `Sources/OmnigentWebLayer` | Swift 6 |
| Web host app | `apps/apple/WebHost/Sources` | Objective-C++ over `libcef_dll_wrapper` |
| CEF helper entry point | `apps/apple/WebHost/Helper/owl_cef_helper.cc` | C++ |
| Build wiring | `apps/apple/Tuist/ProjectDescriptionHelpers/BrowserTargets.swift`, `WebHost/Scripts` | Tuist, bash |
| Browser engine adapter | `Packages/OmnigentBrowser/Sources/OmnigentBrowserChromium` | Swift 6 |
| Proof app | `Example/` | Swift 6 |

## Process model

```
Omnigent.app (client: SwiftUI, OmnigentWebLayer)            no CEF code, never loads CEF
  └─ posix_spawn ─► Contents/Helpers/Omnigent Web Host.app (CEF browser process, LSUIElement)
                      ├─ Omnigent Web Host Helper (GPU)
                      ├─ Omnigent Web Host Helper (Renderer)  × n
                      ├─ Omnigent Web Host Helper             (network, storage utilities)
                      ├─ Omnigent Web Host Helper (Plugin)
                      └─ Omnigent Web Host Helper (Alerts)
```

- One host per `Session`; one `CefBrowser` (windowless) per `WebView`; one `CefRequestContext`
  per `Profile`.
- The host is a real app bundle with a normal `CefRunMessageLoop()`, its own
  `NSApplication<CefAppProtocol>` subclass and CEF's standard shutdown sequence. Those are the
  configurations CEF is designed and tested for; the in-app integration needed an external pump
  and an isa-swizzled `NSApp` under SwiftUI's lifecycle.
- The host is the client's child. It watches the client's PID (`DISPATCH_PROC_EXIT`) and the
  channel (dead-name notification), so it shuts down if the app exits or crashes. CEF's helpers
  exit when the host does (their Mojo channel to the browser process closes).
- The App Store edition never contains the host. `OmnigentBrowserChromium` is not linked there,
  and a build phase (`WebHost/Scripts/check-no-chromium.sh`) fails the build if any Chromium
  binary appears in the bundle.

## IPC

**Decision: a Mach-port channel with a versioned, schema-defined protocol** (`OWLProtocol`).
Embedding Mojo and using XPC were both rejected.

### Why not XPC

- XPC needs either a launchd-registered service (an `.xpc` bundle that launchd starts, or an
  `SMAppService` agent, which shows up in Login Items) or an anonymous endpoint. An anonymous
  endpoint can only be handed to another process over an XPC connection that already exists, so
  there is no public way to bootstrap a child we spawn ourselves.
- The host must be a normal app process with a WindowServer connection (for `CAContext`), its
  own run loop owned by CEF, and child processes of its own. An XPC service is launched by launchd,
  not by us, and is not our child.
- Frames need port rights (IOSurface Mach ports). XPC can carry them, but every hot-path message
  would pay for XPC's dictionary encoding.

### Why not Mojo now

- The prebuilt CEF distribution does not expose Mojo. Its Mojo is internal to
  `Chromium Embedded Framework.framework`, there are no public headers or bindings generator, and
  it does not promise ABI compatibility.
- Building `mojo/core` and the bindings generator separately means a partial Chromium checkout
  and toolchain. That is the source build this task excludes.

### What the channel is

- **Bootstrap.**
  1. The client calls `bootstrap_check_in` on a fresh, unguessable name
     (`ai.omnigent.owl.<pid>.<generation>.<random>`). This dynamic check-in is what Chromium's
     own `MachPortRendezvousServer` does. A spike on macOS 26.7.1 confirmed it works for an
     unsandboxed app.
  2. It spawns the host with that name, a 128-bit token and its own PID.
  3. The host looks up the name and sends `Hello`. Hello carries a send right to the host's
     receive port, the protocol version, the token and the host's CEF and Chromium versions.
  4. The client checks the protocol major version, the token, and the PID claimed in Hello
     against the PID it spawned, then answers `HelloAck` with the session configuration.
- **Sender verification.** Every received message carries a kernel audit trailer. Both sides drop
  messages whose PID is not the expected peer and report them as `OWL_CHANNEL_EVENT_SENDER_REJECTED`
  (tested).
- **Message layout.** Each message is one complex Mach message: header, a port descriptor (at
  most one right, for example an IOSurface), an out-of-line descriptor (payloads over 4 KiB, such
  as PNG snapshots), a 32-byte envelope (`magic`, `protocol_major`, `kind`, `request`, `target`),
  and an inline payload.
- **Schema.** `owl_protocol.h` is the single source of truth. Both the C++ host and the Swift
  client compile against it; Swift imports its `CF_ENUM`s as Swift enums.
  - Payloads are tag-length-value fields: `u64`, `i64`, `double`, `bool`, UTF-8 `string`,
    `bytes`.
  - Kinds and tags are never renumbered. A minor version may add kinds and fields; receivers skip
    unknown fields and report unknown kinds. A major mismatch fails the handshake with
    `WebLayerError.protocolMismatch`.
- **Back-pressure.** Receive queues use `MACH_PORT_QLIMIT_LARGE`. Sends time out after 100 ms
  (client) or 250 ms (host) instead of blocking, so a wedged peer can never freeze the other
  side's main thread.
- **Peer death.** Each side arms `MACH_NOTIFY_DEAD_NAME` on the peer's port, which reports
  `OWL_CHANNEL_EVENT_PEER_DIED`. The client also gets the host's exit status from the process.

### How a Mojo-based host maps

A future custom host keeps the same bootstrap: a Mach rendezvous, then a handshake. Instead of
OWL messages it sends a Mojo invitation over the rendezvous port. Mojo on macOS is itself a Mach
port channel (`mojo::PlatformChannel` with Mach endpoints), so the process model does not change.

| OWL message group | Mojo interface (proposed) | Client type that keeps its API |
|---|---|---|
| Hello / HelloAck / Ready / Ping / Shutdown | `owl.mojom.Host` (bootstrap, `Initialize(SessionConfig) => (HostInfo)`, `Ping() => ()`) | `Session` |
| ProfileCreate / ProfileDestroy | `owl.mojom.Profile` (one remote per profile, `CreateWebView(...)`) | `Profile` |
| Navigate, Reload, SetZoom, Evaluate, Snapshot, Find, DevToolsMethod, view events | `owl.mojom.WebView` plus `owl.mojom.WebViewObserver` | `WebView` |
| InputMouse / InputKey / KeyUnhandled | `owl.mojom.WebContentRenderer` (`blink.mojom.WidgetInputHandler`-style, `ForwardInputEvent(blink.mojom.Event) => (ack)`) | `WebContentRenderer` |
| LayerContext / Frame / FrameAck / PopupVisibility | `owl.mojom.LayerHost` plus `LayerHostClient` (`OnCAContextChanged(id)`, popup widget contexts) | `LayerHost` |

Only `HostChannel` and the `Wire*` types change: they become generated Swift bindings for the
mojom files (Atlas generates its own). The public Swift API stays the same.

## Rendering

The host renders windowless (CEF off-screen rendering, `shared_texture_enabled`). In
`OnAcceleratedPaint` it gets an IOSurface that is only valid during the callback, so it copies it
with a Metal blit into a host-owned IOSurface ring (up to four per layer; a surface is reused only
when the client has acknowledged it and `IOSurfaceIsInUse` is false). The page and the popup
widget are separate layers. Delivery then takes one of two paths.

### Remote layer (default)

- The host creates a `CAContext` through the private `+[CAContext contextWithCGSConnection:options:]`.
  Its root layer holds a page layer and a popup layer whose contents are the ring surfaces.
- The host sends the context ID once, as `LayerContext`. The client embeds it with the private
  `CALayerHost` (`contextId`) inside `WebLayerView`.
- Each frame is set as layer contents in the host, followed by a `CATransaction` flush. The client
  is not involved per frame.

### IOSurface (fallback)

- The host sends each frame's IOSurface as a Mach port (`IOSurfaceCreateMachPort`) together with
  its geometry.
- The client calls `IOSurfaceLookupFromMachPort`, sets the surface as `CALayer.contents`, and
  acknowledges the surface it replaced.
- Public API only.

### Spike evidence

Measured on an M1 Pro, macOS 26.7.1, Debug build. The page is a CSS animation plus a
`requestAnimationFrame` counter, measured for 3 s idle and 3 s with the client main thread blocked
40 ms out of every 50 ms ("jank"). The numbers are from `--proof spike`, two runs per mode.

| Mode | Phase | Page rAF | Frames delivered | Host paint to presented, p50 / p95 | GPU copy p50 | CPU client / host |
|---|---|---|---|---|---|---|
| remote layer | idle | 59 fps | 59 fps | 0.96 / 2.0 ms (run 2: 1.4 / 2.2) | 0.47 ms | 2% / 10% |
| remote layer | jank | 59 fps | 59-60 fps | 1.0 / 2.2 ms (run 2: 1.4 / 2.7) | 0.47 ms | 1% / 8% |
| IOSurface | idle | 59-60 fps | 59-60 fps | 1.5 / 2.8 ms (run 2: 1.4 / 2.4) | 0.52 ms | 4% / 10% |
| IOSurface | jank | 59 fps | 59-60 fps (applied in bursts) | **17.4 / 39.7 ms** (run 2: 16.9 / 39.8) | 0.57 ms | 3% / 9% |

For remote layer, "presented" is the host's transaction commit. For IOSurface it is the moment the
client sets the layer contents.

**Decision: remote layer by default, with automatic fallback to IOSurface.**

- **Jank isolation.** When the app's main thread is busy (SwiftUI layout, a large transcript
  update), IOSurface frames queue behind it: 17 ms median and 40 ms p95 extra latency, with frames
  applied in bursts. Remote-layer frames never touch the client's main thread, so latency stays
  near 1 ms. This is the property Atlas relies on.
- **Cost.** Remote layer avoids one Mach message and one main-thread hop per frame, and uses
  about half the client CPU.
- **Correctness.** Both paths pass every proof below: rendering, popups, input, snapshots, and
  crash recovery.

### Risks of the private API

These apply only to the Developer ID build; the App Store build has no Chromium.

- `CAContext` and `CALayerHost` are private. Apple can rename them, change their semantics, or
  restrict cross-process context hosting. Chromium has depended on them since 2014 for its own
  GPU-to-browser compositing, so a break would also break Chrome and Electron, and fixes would
  surface publicly.
- Notarization does not scan for private Objective-C class use. App Store review would, but that
  edition does not contain this code.

### Detecting breakage

- **Static check, both sides.** The host checks for the `CAContext` class and its factory
  selector and resolves `CGSMainConnectionID` with `dlsym`. The client checks for `CALayerHost`
  and `setContextId:`. If either is missing, the session falls back to IOSurface: the host
  reports the mode it actually used in `Ready`, and `HostInfo.renderMode` reflects it. A zero
  context ID is a typed `renderingUnavailable` error.
- **Runtime canary (`--proof pixels`).** The proof renders a solid colour, screen-captures the
  window, and compares the centre pixel with the host's own snapshot. A `CALayerHost` that
  silently stops compositing leaves the view blank and fails the check. It is meant for a
  macOS-beta CI lane.

### Rejected: Chromium's own GPU `CAContext` (zero copy)

Windowed CEF also composites through a `CAContext` in the GPU process, and the host could read its
ID from the `CALayerHost` inside CEF's `NSView` and forward it. That avoids the ~0.5 ms copy but:

- CEF only produces frames while its window is visible, so the host would need an on-screen
  (transparent) window kept in sync with the client's geometry;
- `<select>` and other popups open as native `NSMenu`s in the host process, which takes focus
  away from the app;
- input would have to go through the host's AppKit event path.

A custom Chromium host removes all three, because it can expose the compositor's
`AcceleratedWidget` `CALayer` directly, as Atlas does. The client API does not change:
`LayerContext` simply carries the compositor's context ID.

### Geometry and scale

- `WebLayerView` reports size (points), backing scale, screen origin and occlusion-based
  visibility. The host turns them into `GetViewRect`, `GetScreenInfo`, `WasResized`,
  `NotifyScreenInfoChanged` and `WasHidden`.
- Frames are laid out at pixel size divided by scale, anchored top-left, so a frame that lags a
  resize is never stretched.

## Input

The client translates NSEvents itself (`InputTranslator`); the host never sees an NSEvent.

| NSEvent | Sent as |
|---|---|
| `keyDown` | `RawKeyDown`, plus one `Char` per inserted UTF-16 unit. No text for Command chords, AppKit function keys (`0xF700...0xF8FF`) or control characters other than Return. CEF derives `windows_key_code` from the native key code on macOS. |
| `keyUp` | `KeyUp` |
| `flagsChanged` | `RawKeyDown` or `KeyUp` of the modifier key |
| mouse down/up, drag, move, enter/exit | click (button, click count) / move / leave, in view points, top-left origin |
| `scrollWheel` | wheel; precise deltas in points, line deltas × 40 |

Modifiers map to `cef_event_flags_t`, including held mouse buttons, which CEF needs for drags.

**Unhandled keys.**

1. `WebSurfaceView.performKeyEquivalent` gives the page the first chance at key equivalents, as
   Chromium does.
2. The host's `CefKeyboardHandler::OnKeyEvent` sees keys the renderer did not consume. It matches
   them against the events it sent and, for user-originated key-downs only, sends `KeyUnhandled`.
3. The client rebuilds an NSEvent, reusing the original event's characters when it has them, and
   dispatches it to `NSApp.mainMenu.performKeyEquivalent`, then to the responder chain.

The `keys` proof shows Cmd+Shift+U reaching a menu item after the page declined it.

Not yet implemented: IME composition (`NSTextInputClient` marked text), dead keys, and
drag-and-drop between the app and the page.

## Popups

- In off-screen mode Blink draws `<select>` menus and other page popups as a separate widget
  (`OnPopupShow`, `OnPopupSize`, `OnPaint(PET_POPUP)`). The host gives the widget its own surface
  chain and layer: a sublayer of the remote context, or the client's popup layer in IOSurface
  mode.
- Agent screenshots composite the popup into the page image (`Presenter::Snapshot`), so an agent
  sees what the user sees. Hidden or off-screen views produce no frames, so for them the host asks
  Chromium for a frame with CDP `Page.captureScreenshot` instead (proved in the `agent` proof).
- The `select` proof opens a `<select>`, captures the window and the snapshot (both show the open
  list), and picks an option with ArrowDown, ArrowDown, Return.
- Native UI that CEF would open in the host process is blocked and reported as
  `WebLayerError.featureBlocked` and `WebViewEvent.featureBlocked`, never shown:
  - JavaScript `alert`, `confirm` and `prompt`;
  - permission prompts and camera/microphone requests (denied);
  - file choosers (cancelled);
  - context menus (cleared).
  These wait for projected views (see "Remaining work").

## Profiles and ephemeral agent sessions

- A `Profile` is one `CefRequestContext`.
  - **Persistent** profiles live at `<root_cache_path>/Profile-<storageKey>`. The storage key is
    the first 16 bytes of SHA-256 of the identifier, the same as `BrowserProfile.storageKey`.
  - **Ephemeral** profiles use an empty `cache_path`, which gives each context its own in-memory,
    off-the-record storage.
- `Session.makeEphemeralProfile()` creates one per logged-out agent run; `Profile.close()` closes
  its views and drops the context.
- The `cookies` proof runs against a local HTTP server:
  - The default profile sets `owl=default`.
  - Ephemeral A sees no cookie, sets `owl=agent-a`, and then sees only its own.
  - Ephemeral B sees no cookie.
  - The default profile still has only `owl=default`.

## Async boot

- `Session.start()` spawns the host and returns in about 2 ms. Views show a "Starting Chromium…"
  overlay, commands issued before then are queued (the initial URL, navigations, geometry), and
  `Ready` replays profiles, then views.
- Timeouts: Hello within 10 s, Ready within 30 s. Either failure is a typed error with a Retry
  path.
- Timings, from `--proof boot,render` over five consecutive launches of the Debug example:

| Step | Warm launches (4) | Cold (first launch after a rebuild) |
|---|---|---|
| First SwiftUI paint | 185-195 ms | 182 ms |
| `start()` to spawn | 0-1 ms | 2 ms |
| `start()` to Hello | 224-347 ms | 282 ms |
| `start()` to Ready | 312-450 ms (CEF init 177-197 ms in the host) | 2221 ms (CEF init 2031 ms) |
| View created to first frame (example.com, network included) | 0.8-1.4 s | 1.3 s |

The app's UI is up roughly 120-260 ms before Chromium is ready on a warm launch, and about 2 s
before it on a cold one. `owl-boot-starting.png` is captured with the host not yet ready.

## Crash and hang detection and recovery

| Failure | Detection | Result |
|---|---|---|
| Host exits or is killed | `Process` termination status, plus the channel's dead-name notification | `SessionState.crashed(.hostExited(status:reason:))`; every view becomes `.unavailable` with a Reload overlay |
| Host hangs | 1 s pings answered on the host's CEF UI thread; none for 8 s means hung | Host is SIGKILLed; `.crashed(.hostUnresponsive)` |
| Host never handshakes or initializes | Timeouts | `.failed(...)`; Retry |
| Channel closed but process alive | Dead name, then 2 s grace | Host killed; `.crashed(.channelFailed)` |
| Renderer process crash | `OnRenderProcessTerminated` | `WebView.lastError = .rendererTerminated`; the view reloads normally |

`WebView.reload()` on an unavailable view restarts the host. The session re-creates every profile
and view, each at its last committed URL. Ephemeral profile data is lost, which is the intended
semantics of in-memory storage. In-flight requests fail with the host error, and any request unanswered after
`requestTimeout` (30 s) fails with `.hostTimedOut`, so nothing waits forever.

Proof (`crash` and `hang`):

- After `kill -9` of the host, the app reports `.hostExited(status: 9, "killed by signal 9")` in
  23-25 ms and stays up (`owl-host-killed-*.png`). Reload starts a new host and reloads the page
  in 409-440 ms.
- After `kill -STOP`, the hang is detected after 8.2-9.9 s, the host is replaced, and the page
  recovers.

## Agent input: the security boundary

Atlas's rule is that agent input goes directly to the renderer, never through the privileged
browser layer. Within CEF:

- `WebContentRenderer` exposes two separate paths. User input comes from `WebLayerView` NSEvents.
  Agent input comes from `agentClick`, `agentMove`, `agentScroll`, `agentType` and `agentPress`,
  and is tagged `OWLInputOriginAgent` on the wire.
- Agent events go to `CefBrowserHost::Send{Mouse,Key}Event`, which lands in that page's
  `RenderWidgetHost` and then its renderer: the same entry point a content-API embedder uses.
  They never pass through:
  - the client's NSEvent path, app menus or responders: unhandled agent keys are dropped and never
    re-synthesized, so an agent cannot press Cmd+Q, Cmd+W or any app shortcut;
  - browser-level UI: DevTools, dialogs, permission prompts, file choosers and context menus are
    blocked for every origin, and agents have no API to open DevTools;
  - other views: input is addressed to exactly one view ID.
- Agent views can be off screen. Before the first agent event the host gives the page widget
  focus, so typing reaches the focused element. This affects the page only, not the app's key
  window.
- In a custom host the same API would call `RenderWidgetHost::ForwardMouseEvent` and
  `ForwardKeyboardEvent` on the target `WebContents`' widget directly, which matches Atlas.

## Shutdown, and why the `CefShutdown` crash is gone

- The client sends `Shutdown`, then waits up to `shutdownGrace` (3 s) for the host to exit before
  SIGKILL. It does this on `NSApplication.willTerminateNotification`, so no app-delegate
  cooperation is needed. If the app dies first, the host notices its parent exit and runs the
  same sequence.
- The host follows cefsimple's sequence exactly: `CloseBrowser(true)` on every view, then the last
  `OnBeforeClose`, then `CefQuitMessageLoop`, then release the request contexts, then
  `CefShutdown()`, then exit. A 5 s watchdog in the host `_exit`s if that stalls.
- The old intermittent crash fired inside `CefShutdown` in the app process, because CEF shared
  the app's run loop through an external pump, and teardown raced SwiftUI and AppKit termination.
  Out of process:
  - nothing CEF does can crash or hang the app's exit;
  - the host's teardown runs on CEF's own message loop, the configuration CEF supports.
- **Two shutdown bugs found by the 20× quit loop, and fixed.**
  1. Iterating `views_` while `Close()` erased from it (a host SIGSEGV).
  2. Chromium's `MacAppCodeSignClone` feature. At exit, Chrome launches a detached
     `--type=code-sign-clone-cleanup` helper. CEF helpers cannot run that type and hit a CHECK,
     one crash report per quit. The host disables the feature; its bundle is immutable inside the
     signed app.
- Result: 20 of 20 quits with exit status 0, no orphaned host or helper processes, and no new
  crash reports from the app, the host or any helper. `CefShutdown` takes 78-2477 ms, all of it
  in the host.

## Build, layout and size

- `BrowserTargets.helperTargets` adds `<App>WebHost` (the host app) and five
  `<App>WebHostHelper*` targets.
  - The host's post-build phase (`WebHost/Scripts/embed-cef.sh`) copies the framework and the
    helpers into `Omnigent Web Host.app/Contents/Frameworks` and signs them.
  - The app's post-build phase (`embed-web-host.sh`) copies the signed host into
    `Contents/Helpers`. Xcode then seals it into the app's signature
    (`codesign --verify --deep --strict` passes).
- Helper entitlements are unchanged: `allow-jit` for the base helper and the GPU and Renderer
  helpers; the Plugin helper's set. The host needs none.
- Size (Debug, arm64):

| Part | On disk |
|---|---|
| `Omnigent Web Host.app` | 331 MB (`Chromium Embedded Framework.framework` 326 MB; host executable plus debug dylib about 1.4 MB; helpers 0.76 MB each) |
| Whole example app | 333 MB on disk, 141 MB zipped |

Universal Release builds roughly double the framework, as before.

- App builds never compile Chromium. The host and helpers compile in seconds against the staged
  CEF distribution (`scripts/fetch-cef.sh`, pinned and checksum-verified).

## Strictness exceptions

- `owl_channel.h` disables `-Wnullability-extension` locally, so Swift gets precise nullability
  under `-Wpedantic`.
- The host resolves the private API at run time (`NSClassFromString`, `dlsym`, `objc_msgSend`,
  KVC) instead of declaring private interfaces.
- Swift `unsafe` is used only where C or AppKit force it:
  - `OpaquePointer` handles in `Channel.swift`;
  - `NSView.window` and `nextResponder`, which are `unowned(unsafe)`, behind one documented
    accessor;
  - `proc_pid_rusage` in the example.
- The `OWLField` enum cases `.URL`, `.JSON`, `.PNG`, `.X` and `.Y` keep the importer's
  capitalisation.

## Remaining work

These need **projected views**: host-side UI rendered as another `WebView`-like surface in the
client, as Atlas does for its own browser UI.

- **Downloads.** They are blocked and reported today. They need a `CefDownloadHandler` with
  client-chosen paths and a progress model.
- **Extensions.** Alloy-style CEF has limited extension support. Chrome-style runtime or a custom
  host is needed.
- **Autofill and passwords.** Off-the-record and persistent profiles have no autofill UI. It needs
  a projected autofill dropdown.
- **Bookmarks and history UI.** This is app-side data plus navigation APIs; no host work is
  needed beyond history queries.
- **DevTools.** `showDevTools()` opens CEF's own DevTools window inside the host process. A
  projected version would be a second `WebView` attached through `CefBrowserHost::ShowDevTools`
  with an off-screen `CefWindowInfo`, or through the remote debugging protocol.
- **Permission prompts, JavaScript dialogs, file choosers, context menus, `<input type=color>`
  (NSColorPanel), HTTP auth, and certificate errors.** Each needs a projected view or a native
  client sheet driven by a host callback with a reply.
- **IME** (marked text) and drag and drop.
- **`window.open`.** Popups currently navigate the same view; they need new `WebView`s handed to
  the client.

## Path to a custom Chromium host

1. Build a minimal content-API embedder (content_shell-sized) that links `//content` and
   `//components/viz`.
2. Expose the root compositor's `CALayer` through `ui::AcceleratedWidgetMac`'s `CAContext`, one
   per `WebContents` plus one per popup widget, and send the IDs as `LayerContext`. This removes
   the copy and keeps native-speed compositing.
3. Replace the OWL wire with mojom interfaces (table above). Generate Swift bindings for the
   client's `HostChannel` layer. Keep the Mach rendezvous bootstrap and handshake.
4. Route agent input to `RenderWidgetHost` directly, and implement projected views for permission
   prompts, dialogs, autofill and DevTools as additional `WebContents` with their own contexts.
5. The public Swift API (`Session`, `Profile`, `WebView`, `WebContentRenderer`, `LayerHost`) and
   `OmnigentBrowserChromium` stay unchanged. Only the host bundle and the transport layer are
   swapped.
