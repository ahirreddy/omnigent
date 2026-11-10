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
| Shared browser UI (both engines) and agent actions | `Packages/OmnigentBrowser/Sources/OmnigentBrowser/{UI,Agent}` | Swift 6 |
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
  - Minor versions are negotiated: Hello carries the host's `ProtocolMinor`, and since 1.1
    `HelloAck` carries the client's. Each side uses a feature only when the peer's minor is at
    least the one that introduced it (`OWL_PROTOCOL_MINOR_PROMPTS` for the browser UI below). A
    1.1 host serving a 1.0 client keeps every 1.0 behavior, including blocking that UI; a 1.1
    client talking to a 1.0 host never sends 1.1 messages (`Session.supportsBrowserUI`).
  - Lists and nested values in 1.1 fields are UTF-8 JSON strings, documented field by field at
    the top of `owl_protocol.h`.
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
| 1.1 prompt requests and replies (JSDialog, PermissionRequest, FileChooser, DownloadRequest, AuthRequest, CertificateError, ContextMenu, ColorChooser, PromptCancelled) | `owl.mojom.WebViewUIClient` with one `=> (reply)` method per prompt; cancellation is the reply pipe closing | `WebViewUIDelegate`, `WebPrompt` |
| 1.1 PopupCreated / PopupBlocked / SetPopupPolicy / SetNavigationRules / NavigationBlocked | `owl.mojom.WebView.SetPolicies(...)`, `WebViewUIClient.OnPopup(pending_remote<WebView>)` | `WebView`, `WebPopup` |
| 1.1 Ime* / Drag* / StartDrag / DragCursor | `owl.mojom.WebContentRenderer` (`blink.mojom.FrameWidgetInputHandler`-style IME and drag methods) | `WebContentRenderer` |

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

The host returns every unconsumed key-down, and a text field leaves the RawKeyDown of each typed
character unconsumed (the Char inserts the text). `UnhandledKeyRouting` therefore decides what
step 3 does:

- A key that only types (a printable character without Command, Control or Globe) stops there.
  AppKit never offers such a key as a key equivalent, and `NSMenu.performKeyEquivalent` called
  directly runs the system's Globe items for it: a plain E opens Emoji & Symbols, D starts
  dictation, F enters full screen.
- NSMenu ignores Globe when matching, so a chord that matches a Globe item (Control-C against
  Window > Center) skips the main menu unless Globe was held. Globe is not on the wire; the
  rebuilt event takes it from the key-down that was sent.
- Everything else (Command and Control chords, Escape, Return, arrows, function keys) goes to the
  window, the main menu and the responder chain as above.

The `keys` proof shows Cmd+Shift+U reaching a menu item after the page declined it.

**IME and dead keys (1.1).** `WebSurfaceView` is an `NSTextInputClient`, on the model of
Chromium's own Mac view and cefclient's off-screen text input client:

1. A key-down without Command runs `inputContext.handleEvent`. The `NSTextInputClient` callbacks
   it triggers are collected, not sent.
2. No marked text before or after, and at most one inserted UTF-16 unit: the plain key events
   above. More text: `ImeCommitText`. Marked text: `ImeSetComposition` (text, selection, optional
   replacement range). Marked text that went away: `ImeFinishComposing` after `unmarkText`,
   otherwise `ImeCancelComposition`.
3. Callbacks outside a key-down (emoji palette, dictation) are sent at once.
4. The host maps these to `CefBrowserHost::Ime*`. `OnImeCompositionRangeChanged` comes back as
   `ImeCompositionChanged` with per-character rects, which `firstRect(forCharacterRange:)` uses
   to place the candidate window; `OnTextSelectionChanged` backs `selectedRange`.

The `ime` proof drives the client as an input method would (`setMarkedText` に, にほ, 日本, then
`insertText` 日本語) and checks the page saw `compositionstart`, four `compositionupdate`s and
`compositionend:日本語`.

**Drag and drop (1.1).**

- Into the page: `WebSurfaceView` accepts file URLs, URLs, text and HTML. `draggingEntered`,
  `draggingUpdated`, `draggingExited` and `performDragOperation` become `DragEnter` (with
  `DragData` JSON: text, html, url, file paths), `DragOver`, `DragLeave` and `DragDrop`, that is
  `CefBrowserHost::DragTarget*`. The page's accepted operation comes back as `DragCursor` and is
  what AppKit is told.
- Out of the page: `CefRenderHandler::StartDragging` becomes `StartDrag` with the drag data, the
  allowed operations and the drag image as PNG. A dragged virtual file (an image) is written to a
  private temporary directory in the host and sent as a path. The client starts an
  `NSDraggingSession` from the last mouse-down, and its end becomes `DragSourceEnded`
  (`DragSourceEndedAt` plus `DragSourceSystemDragEnded`).
- Drags started by agent input never leave the page (`StartDragging` returns false).
- Synthesized drag events carry their mouse button in the modifiers even when the hardware state
  says otherwise, which CEF needs to start a drag.

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
- Native UI that CEF would open in the host process is never shown there. Since 1.1 it is
  projected to the client as described in "Browser UI over the channel"; with a 1.0 client, or a
  view without a `WebViewUIDelegate`, it is denied and reported as `WebLayerError.featureBlocked`
  and `WebViewEvent.featureBlocked`.

## Browser UI over the channel (protocol 1.1)

Every piece of browser UI Chromium would draw in the host process is projected to the client
instead. The host holds the CEF callback under a host-assigned `PromptID` and sends a request;
the client answers by `PromptID`; the host runs the callback. Nothing opens a window in the host.

| Feature | CEF hook in the host | Request (H->C) / reply (C->H) | Client UI (`OmnigentBrowser`, both engines) | WebKit equivalent |
|---|---|---|---|---|
| `alert`, `confirm`, `prompt`, `beforeunload` | `OnJSDialog`, `OnBeforeUnloadDialog`, `OnResetDialogState` | `JSDialog` / `DialogReply` | NSAlert sheet, text field for `prompt` | `runJavaScript*Panel` (no public `beforeunload`) |
| Camera, microphone, geolocation, notifications, clipboard, MIDI | `OnRequestMediaAccessPermission`, `OnShowPermissionPrompt`, `OnDismissPermissionPrompt` | `PermissionRequest` / `PermissionReply` | NSAlert with "Remember for this site"; `BrowserPermissionStore` per profile and origin | `requestMediaCapturePermissionFor` |
| `<input type=file>`, File System Access | `OnFileDialog` | `FileChooser` / `FileChooserReply` (paths) | NSOpenPanel or NSSavePanel sheet, types from `accept` | `runOpenPanelWith` |
| Downloads | `CanDownload`, `OnBeforeDownload`, `OnDownloadUpdated` | `DownloadRequest` / `DownloadReply` (path), `DownloadUpdated`, `DownloadControl` | Folder setting and "ask where to save" (NSSavePanel); `BrowserDownloadsView` with progress, Cancel, Show in Finder | `WKDownload` with `WKDownloadDelegate` |
| Context menus | `OnBeforeContextMenu` (removes Print and View Source), `RunContextMenu` | `ContextMenu` (menu model JSON) / `ContextMenuReply` (command ID) | Native NSMenu built from the host's model, plus "Open Link in New Tab" and "Copy Link" | WKWebView's own NSMenu |
| HTTP and proxy auth | `GetAuthCredentials` (IO thread, posted to UI) | `AuthRequest` / `AuthReply` | NSAlert with user name, password and "Remember in Keychain" (off by default, hidden for ephemeral profiles) | `didReceive challenge` (Basic, Digest, NTLM) |
| Certificate errors | `OnCertificateError` (no callback means not overridable) | `CertificateError` / `CertificateReply` | Interstitial over the page; "Proceed" only when overridable and `allowsCertificateOverrides` | `didReceive challenge` (server trust), per-tab exceptions |
| `window.open`, `target=_blank`, modified clicks | `OnBeforePopup` (windowless popup with a new client), `OnOpenURLFromTab`, `OnBeforePopupAborted` | `PopupCreated` (targets the new view), `PopupBlocked`; `SetPopupPolicy` | `BrowserPopup` to the app (`onOpenPopup`), else a popup window; "Popup blocked" banner with Open | `createWebViewWith` on WebKit's configuration |
| `<input type=color>` | Isolated-world script plus `Runtime.addBinding` (see below) | `ColorChooser` / `ColorReply` | NSColorPanel | WKWebView's own panel |
| Navigation rules (agents) | `OnBeforeBrowse` (redirects and page-initiated loads included) | `SetNavigationRules`, `NavigationBlocked` | `BrowserURLPolicy` | `decidePolicyFor navigationAction` |

Rules that apply to all of them:

- **Withdrawal.** When the page navigates, the view closes or Chromium dismisses a prompt, the
  host sends `PromptCancelled`; the client withdraws the prompt and its sheet. A reply that
  crosses a withdrawal is answered with `HostError(UnknownPrompt)`, which the client records as a
  protocol warning, not a view error.
- **No silent drops.** Without a `WebViewUIDelegate` (web layer) or `BrowserTabDelegate`
  (engine-neutral), each request is denied and reported (`featureBlocked`). Malformed JSON fields
  are typed errors on the view.
- **Agents.** Agent views get the agent controller as their delegate, which answers without UI.
  The host also cancels context menus and drags started by agent input.
- **Policies before the first load.** `ViewCreate` carries `PopupPolicy` and `Rules`, so the
  initial navigation is covered; popups inherit both from their opener.
- **Chrome's own UI is switched off.** The host passes `--disable-chrome-login-prompt`; without it
  Chromium's Chrome-style login dialog opens as a window in the host (and closing it with the
  view crashed the host). Persistent request contexts set the popup content setting to Allow, so
  the view's popup policy, which sees the user gesture, decides (see "Remaining work" for
  ephemeral contexts).
- **Popups keep their opener.** `OnBeforePopup` returns a windowless `CefWindowInfo` and a fresh
  `BrowserClient` under a host-allocated view ID (from 2^48 up, so it never collides with the
  client's IDs). `PopupCreated` reaches the client before the new view's first message, and the
  client adopts the view (`Session.adoptPopup`) into the opener's profile. After a host restart
  the client re-creates it like any other view, without the opener.
- **Color inputs.** CEF has no color-chooser handler. At view creation the host enables Runtime
  and Page over DevTools, adds the binding `owlColorChooser` and a document script, both in the
  isolated world `owl-browser-ui`, which page scripts cannot reach. The script cancels the click
  that would open Chromium's panel and calls the binding; the host turns `Runtime.bindingCalled`
  into `ColorChooser`, and on `ColorReply` (validated `#rrggbb`) sets the value and fires `input`
  and `change` through `Runtime.evaluate` in that world's context.
- **Downloads.** The client picks the path (settings or NSSavePanel, sanitized file name, never
  overwriting); releasing CEF's callback without a path cancels. Progress for a download is
  ignored until its destination is chosen.
- **Permissions.** Decisions are stored per profile storage key and origin
  (`scheme://host[:port]`): in `UserDefaults` for persistent profiles, in memory for ephemeral
  ones. A request that includes an unmapped permission type (`OWLPermissionOther`) is denied.
  `getUserMedia` is all or nothing, as CEF requires.
- **Passwords.** Credentials cross the channel once per challenge and are never stored by the web
  layer; WebKit gets them with `URLCredential.Persistence.none`. Only the explicit Keychain
  opt-in stores them (`KeychainBrowserCredentialStore`, internet passwords tagged with the app's
  description).

### Proofs (`--proof browser-ui`)

Run with `--render-mode remoteLayer`, `--render-mode ioSurface` and `--engine system`. All twelve
pass on Chromium in both render modes; on WebKit the Chromium-only parts (beforeunload, camera
prompt, gesture-less popup report, context menu, IME, drag, color) are skipped because WKWebView
provides those natively, and the rest pass. Screenshots are `owl2-<proof>-<engine>.png` in the
output directory.

| Proof | What it shows |
|---|---|
| `dialogs` | alert, confirm (Cancel returns false) and prompt ("owl answer") as sheets; Chromium also beforeunload "Stay" |
| `permissions` | camera denied and remembered (persisted for a persistent profile, memory only for an ephemeral one); a second request is answered without a sheet; notifications allowed |
| `files` | NSOpenPanel sheet; the page reads the two chosen files' contents |
| `downloads` | NSSavePanel when asking, straight to the folder otherwise; both 256 KiB files complete; the downloads list |
| `auth` | credential sheet; the page is authorized; nothing stored without opt-in |
| `certs` | interstitial for a self-signed server; proceeding loads it |
| `popups` | a gesture-less `window.open` reported as blocked; a clicked one opens a sized window whose page has `window.opener` and posts back; `window.close()` closes it |
| `menu` | NSMenu with app and host items; "Copy Link" and the host's "Copy" both work |
| `ime` | marked text 日本 then commit 日本語, with composition events |
| `drag` | text and a file dropped into the page; a page drag starts a native drag |
| `color` | NSColorPanel opens in the client (none in the host); the input becomes #00ff00 |
| `agent-actions` | see "Agent browser actions" |

## Browsing state (protocol 1.2)

What a full browser needs beyond page UI. `OWL_PROTOCOL_MINOR_BROWSING` (2); each side uses these
only when the peer advertises minor 2, so a 1.2 client still works with a 1.1 host (no favicons,
history or audible state; mute reports `featureBlocked`; hard reload is a normal reload) and a 1.2
host never sends them to a 1.1 client.

| Message | Direction | CEF source | Client |
|---|---|---|---|
| `Reload` + `IgnoreCache` field | C->H | `ReloadIgnoreCache()` | `WebView.reload(ignoringCache:)` |
| `SetAudioMuted` (`Muted`) | C->H | `CefBrowserHost::SetAudioMuted` | `WebView.setAudioMuted(_:)`, re-sent when the view is (re)created |
| `FaviconURLChanged` (JSON list) | H->C | `OnFaviconURLChange` | `WebView.faviconURLs`; the browser fetches and normalizes the icon |
| `NavigationHistory` (JSON `{index, entries}`) | H->C | `GetNavigationEntries` after every loading-state and title change, deduplicated | `WebView.navigationHistory`, for session restore |
| `AudioStateChanged` (`Audible`, `Muted`) | H->C | the bridge world's `owlMediaState` binding | `WebView.isAudible`, `isAudioMuted` |

- **Audible.** CEF does not tell embedders when a page is audible. A script in the isolated
  `owl-browser-ui` world watches media events captured on the document and reports, per frame,
  whether any media element plays with sound; the host ORs frames and drops destroyed execution
  contexts. Web Audio and detached `Audio` objects are not seen. WebKit uses the same script in a
  `WKContentWorld`, plus mute by `muted` on media elements (WebKit has no public page mute).
- **History restore.** CEF cannot restore navigation entries. `OmnigentBrowser` rebuilds them in
  the page: it loads `about:blank#omnigent-restore`, adds one `pushState` entry per saved page
  (`about:blank#omnigent-restore&u=<url>&t=<title>`, fragment-only so an opaque origin allows it),
  goes to the current entry and `location.replace`s it with the real page. Entries load lazily:
  going back onto a placeholder loads `about:blank` with that fragment, and the tab model replaces
  it. The scripts run through `Evaluate`, which has a user gesture, so the history-manipulation
  intervention does not skip the entries. WebKit restores natively from `interactionState`.
- **Print.** `Page.printToPDF` over `DevToolsMethod`; the client prints the PDF with PDFKit, so no
  print UI opens in the host. View Source loads `view-source:` in a new tab.
- **Profile deletion.** `Session.deletePersistentStorage(identifier:)` closes the profile, removes
  `Profile-<key>`, and queues it in `pending-profile-deletions.json`; the next launch removes
  anything Chromium wrote while it was releasing the context.
- **Unhandled keys** now go to the client window's `performKeyEquivalent` before the main menu, so
  SwiftUI keyboard shortcuts in the browser toolbar (⌘F, ⌘+, ⌥⌘I) work while the page has focus.

### Proofs (`--proof browser2`)

Through `BrowserTabModel` and `BrowserTabContentView` (`BrowserTabHarness`), on either engine and
render mode. Screenshots are `browser2-<proof>-<engine>.png`.

| Proof | What it shows |
|---|---|
| `profiles` | Two user profiles in two tabs; `owl=alpha` in one is never seen by the other, which sets `owl=beta`; the work profile is deleted with its data |
| `browsing` | Favicon; ⌘F opens find with 6 matches (Chromium); ⌘= zooms to 110% (CSS width 1100 to 1000), remembered for the host and not for another host; ⌘0; ⌥⌘I opens DevTools (a host window on Chromium, a reported refusal on WebKit); a playing tone marks the tab audible, mute toggles; View Source opens a tab; omnibox suggestions |
| `reopen` | Closing a tab records its history; reopening restores it and Back works |
| `restore` | Saves two tabs (one pinned, muted, in a second profile), shuts Chromium down and relaunches the app with `restore-verify`, which shows saved titles and favicons without loading, loads the selected tab on show, goes back twice and forward once, and keeps the background tab unloaded |

## Sign-in (protocol 1.3)

What enterprise sign-in (Okta FastPass, device-trust agents, authenticator apps) needs.
`OWL_PROTOCOL_MINOR_SIGN_IN` (3); a 1.3 host sends these only to 1.3 clients, so older clients keep
the 1.2 behavior (local-network requests arrive as `OWLPermissionOther` and are denied; custom
schemes fail with `ERR_UNKNOWN_URL_SCHEME`). See `apps/apple/docs/browser-engine-decision.md`.

| Message | Direction | CEF source | Client |
|---|---|---|---|
| `PermissionRequest` with `OWLPermissionLocalNetwork` | H->C | `OnShowPermissionPrompt` for `LOCAL_NETWORK_ACCESS`, `LOCAL_NETWORK`, `LOOPBACK_NETWORK` | `WebPermissions.localNetwork`; the shared UI asks and remembers it per site |
| `ExternalProtocol` (`URL`, `Origin`) | H->C | `OnBeforeBrowse` cancels navigations to schemes Chromium does not render | `WebViewUIDelegate.webView(_:wantsToOpenExternally:)`; `BrowserExternalApplication` confirms, then `NSWorkspace` opens it |

- **Local Network Access.** Chromium 142+ asks before a public page fetches `127.0.0.1` or a
  private address. Okta FastPass probes Okta Verify on `127.0.0.1:8769` this way, and device-trust
  agents do the same. Before 1.3 the shared UI denied the request as an unknown permission.
- **External schemes.** The host never launches apps. Agent tabs decline the confirmation, and
  navigation rules with a scheme list block these navigations before they are offered. WebKit
  does the same in `decidePolicyFor` for schemes `WKWebView` does not handle.
- **WebAuthn** needs no protocol: Chrome's own WebAuthn dialogs open as native windows in the host
  process, which activates to show them. Platform passkeys need entitlements on the host bundle.

### Proofs (`--proof authentication`)

| Proof | What it shows |
|---|---|
| `webauthn` | Feature detection on `https://example.com`; a platform request and a presence-only security-key request, logging the host windows Chromium opens and their stacking |
| `webauthn-virtual` | A CDP virtual authenticator registers and asserts on webauthn.io and passkeys.io |
| `webauthn-tab` | The same requests through the shared UI on `--engine`, results polled from the page |
| `loopback` | A fetch from `https://example.com` to `127.0.0.1:8769` (Okta Verify, or a mock when it is not running) asks for local-network access and succeeds once allowed |
| `external-scheme` | A `com-okta-authenticator:` link asks to open Okta Verify (the proof cancels); an unregistered scheme is reported |

## Agent browser actions

`AgentBrowserController` (`OmnigentBrowser/Agent`) runs the server's agent-driven browsing on
either engine.

**Contract.**

- The server emits `browser.action_request` on the session stream (`omnigent/server/schemas.py`,
  `BrowserActionRequestEvent`): `{type, action_id, action, args}`. `action` is the `browser_*`
  tool name without the prefix.
- A client that can act first claims it: `POST /v1/sessions/{id}/browser/action_claim/{action_id}`
  returns `{claimed: true, claim_token}` to exactly one claimant (`{claimed: false}` otherwise).
  Only the winner runs the action, then posts
  `POST /v1/sessions/{id}/browser/action_result/{action_id}` with
  `{result: <object>, claim_token}` (403 without the matching token). The server waits 2 s for a
  claim and 30 s for the result; per-action timeouts in the controller default to 20 s so a
  result always arrives first.
- Requests are routed by the session whose stream delivered them, not the one on screen.
- The `result` object is `{ok, error?, data?, data_url?}`, the same as the Electron relay
  (`web/src/hooks/useBrowserAgentRelay.ts`):

| Action | Arguments | Success result |
|---|---|---|
| `navigate` | `url` | `data: {final_url, title}` |
| `snapshot` | none | `data: {snapshot_id, url, title, tree}`; `tree` lines are `- role "name" [ref=N]` |
| `click` | `ref` + `snapshot_id`, or `selector` | `ok` |
| `type` | `ref` + `snapshot_id`, or `selector`; `text` | `ok` |
| `screenshot` | none | `data_url: "data:image/png;base64,..."`; on Chromium open `<select>` popups are composited |
| `press` (client extension) | `key` (DOM name), `modifiers`, optional target | `ok` |
| `scroll` (client extension) | `delta_x`, `delta_y`, optional target | `ok` |
| `evaluate` (client extension) | `expression` | `data: {value}` |
| `wait_for_load` (client extension) | `timeout_ms` | `data: {url, title}` |

Argument checks match Electron's `buildBrowserActionScript` (unknown keys, positive integer
`ref`, `selector` up to 4096 characters, `snapshot_id` up to 128, `text` up to 100000). Any
failure is `{ok: false, error}`; prompts the page raised during an action are listed in
`data.dialogs`. The server's tool list today has navigate, snapshot, click, type and screenshot;
the extensions run only when a server sends them.

**Execution.**

- One agent page per conversation, in an ephemeral profile (`agent:<conversation>`) by default,
  so agent cookies never mix with the user's. Pages a page opens join the conversation and become
  its active page.
- Input is renderer-direct on Chromium (`click` resolves the element's center by script, then
  `agentClick`; `type` focuses and selects, then `agentInsertText`). WebKit has no public trusted
  input, so its agent input dispatches DOM events from script (`isTrusted` is false). After input
  the controller waits briefly and then for any load the input started.
- **URL policy.** `BrowserURLPolicy` (default `BrowserURLRules`: http and https only, private,
  link-local and loopback IP literals blocked) is checked before `navigate`, and its rules are
  pushed into the engine before the first load: Chromium enforces them in `OnBeforeBrowse`, so
  redirects and page-initiated navigations are covered; WebKit in
  `decidePolicyFor navigationAction`. The Swift and C++ matchers implement the same rules
  (`BrowserURLPolicy.swift`, `OWLNavigationRules.mm`).
- **Off app chrome.** Agent pages are never in an app window (see "Agent input"), their prompts
  never show UI, and their unhandled keys, context menus and drags never leave the page.
- **Entry point for stores.** `AgentBrowserActing.perform(_:)` takes an `AgentBrowserActionRequest`
  (`init(eventJSON:conversationID:)` decodes the raw event) and returns an
  `AgentBrowserActionResult` whose `jsonData()` is the `result` body. Claiming and posting are the
  caller's job.

The `agent-actions` proof navigates to a local form, snapshots it, types into the textbox by
ref, clicks Search by ref (the page sees the submission), clicks a button whose `alert` is
auto-accepted and reported in `data.dialogs`, screenshots with an open `<select>`, is refused
`http://169.254.169.254/` by the policy, is stopped by the host rules when a local redirect
points at `http://10.11.12.13/`, and checks the agent page is in no app window.

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
| Renderer process crash | `OnRenderProcessTerminated` | `WebView.lastError = .rendererTerminated`, whose text names how the process ended (crashed, killed, out of memory, not launched, integrity failure) and the signal or exit code; the raw status and code go to the log. Nothing reloads by itself; `reload()` starts a new renderer |

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
  Agent input comes from `agentClick`, `agentMove`, `agentScroll`, `agentType`, `agentPress` and
  (1.1) `agentInsertText`, and is tagged `OWLInputOriginAgent` on the wire. `agentInsertText` is
  an `ImeCommitText` flagged `AgentInput`: one `beforeinput`/`input` for the whole string, as an
  input method commit produces.
- Agent events go to `CefBrowserHost::Send{Mouse,Key}Event`, which lands in that page's
  `RenderWidgetHost` and then its renderer: the same entry point a content-API embedder uses.
  They never pass through:
  - the client's NSEvent path, app menus or responders: unhandled agent keys are dropped and never
    re-synthesized, so an agent cannot press Cmd+Q, Cmd+W or any app shortcut;
  - browser-level UI: context menus and drags opened by an agent click are cancelled in the host
    (it remembers the origin of the last mouse-down), agents have no API to open DevTools, and
    every prompt an agent page raises goes to the agent's own `BrowserTabDelegate`
    (`AgentBrowserController`), which answers it without UI;
  - other views: input is addressed to exactly one view ID.
- Agent views can be off screen. Before the first agent event the host gives the page widget
  focus, so typing reaches the focused element. This affects the page only, not the app's key
  window. Hidden Chromium widgets drop input, so agent views set `WebView.rendersOffscreen`: they
  report themselves visible to the host although no window shows them. Chromium agent pages are
  in no window at all; WebKit agent pages sit in an off-screen, non-activating `NSPanel` that
  ignores the mouse (WebKit needs a window to render).
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
- 1.1: `OWLPermissionOther` is `1 << 30`, not `1 << 31`, so the enumerator stays in `int` range
  in the host's C17 build.
- 1.1: two `swiftlint:disable:next` lines, each for an SDK signature (WebKit's optional `[URL]`
  completion handler, AppKit's `readObjects(forClasses: [NSURL.self])`, which resolves Finder's
  file-reference URLs). The proof app marks two main-thread AppKit objects
  `nonisolated(unsafe)` where AppKit hands them to `@Sendable` notification and timer closures.

## Remaining work

- **Extensions.** Alloy-style CEF has limited extension support. Chrome-style runtime or a custom
  host is needed.
- **Autofill and passwords.** There is no autofill UI. It needs a projected autofill dropdown
  (another popup-widget-like surface) and a password store; HTTP auth credentials already use the
  Keychain on opt-in.
- **Projected DevTools.** `showDevTools()` still opens CEF's own DevTools window inside the host
  process. A projected version would be a second `WebView` attached through
  `CefBrowserHost::ShowDevTools` with an off-screen `CefWindowInfo`, or through the remote
  debugging protocol.
- **Popup blocking in ephemeral profiles.** Chromium's own popup blocker runs before
  `OnBeforePopup`, and incognito contexts do not accept a default content setting, so in
  ephemeral profiles gesture-less popups are dropped by Chromium without a `PopupBlocked` report
  (persistent profiles report them). WebKit's own blocker never reports.
- **Navigation rules and DNS.** Host rules check IP literals, not what names resolve to, so DNS
  rebinding to a private address is not caught.
- **Media capture.** Allowing camera, microphone or location needs the usage strings and
  entitlements in the app's Info.plist (`BrowserTargets.swift`); without them macOS refuses
  access after the user allowed it in the app.
- **Download continuation.** Downloads are tied to the view that started them; closing that view
  mid-download is not handled specially.
- **beforeunload on WebKit** has no public API; the shared UI shows it for Chromium only.

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
