# OmnigentBrowser

Embedded browser for the native Omnigent apps, with two engines:

| Engine | `BrowserEngineKind` | Platforms | Default |
|---|---|---|---|
| Chromium via CEF | `.chromium` | macOS only | macOS, when bundled and startable |
| The OS web view, currently WKWebView | `.system` ("System (WebKit)") | macOS, iOS, iPadOS | iOS and iPadOS, and macOS builds without CEF |

App Store rules restrict iOS and iPadOS to WebKit. On those platforms the package compiles without
any CEF code.

## Parity target

The scope comes from the Electron browser pane: `web/electron/src/browserViewRegistry.js`,
`browserIpc.js`, `browserActionScript.mjs`, and `browserUrlPolicy.js`. It also covers the
server's `browser.action_request` bridge (`omnigent/server/routes/sessions/routes_browser.py`,
`web/src/hooks/useBrowserAgentRelay.ts`) and the WKWebView usage in `web/ios`.

| Capability | Electron | This cut |
|---|---|---|
| Navigate, back/forward/reload/stop | yes | yes, both engines |
| Observable URL, title, loading, progress, can-go-back/forward | yes | `BrowserTabState`, both engines |
| Per-server/per-conversation storage isolation | in-memory partition per conversation, scoped per window | `BrowserProfile`: persistent per server or ephemeral per id. WebKit uses `WKWebsiteDataStore(forIdentifier:)`; Chromium uses a `CefRequestContext` per profile under `root_cache_path` |
| JS evaluation (agent snapshot/click/type scripts) | `executeJavaScript` | `evaluateJavaScript` (completion value, promises not awaited). Chromium uses CDP `Runtime.evaluate` in the browser process; WebKit uses `evaluateJavaScript` |
| Screenshot (`browser_screenshot`) | `capturePage` | `takeSnapshotPNG`. Chromium uses CDP `Page.captureScreenshot`; WebKit uses `takeSnapshot` |
| Find in page | `find_preload.js` | `find(_:forward:caseSensitive:)` |
| DevTools | `openDevTools` | Chromium: `showDevTools()` opens a native DevTools window. WebKit: the view is inspectable from Safari's Develop menu; `showDevTools()` throws `featureUnsupported` |
| Popups / `window.open` | `popupPolicy.js` | Open in the same tab |
| Downloads | Electron default | Blocked and reported as `BrowserError.downloadsUnsupported` |
| Agent actions (`browser.action_request`: navigate/snapshot/click/type/screenshot) | yes | Primitives exist; the relay and the action-script port are not wired yet |
| URL policy for agent navigation (localhost/proxy checks) | `browserUrlPolicy.js` | Not yet |
| Design mode, Chrome cookie import, permission prompts | yes | Not yet |

## Engine selection and failure handling

- `BrowserPreferences` persists the user's choice under `ai.omnigent.browser.engine`. Until the
  user picks, the default is `.chromium` when the platform supports it and
  `DefaultBrowserEngineProvider.availability(of: .chromium)` is `.available`; otherwise it is
  `.system`.
- `BrowserController` owns the tab. If the preferred engine cannot provide one, the content
  becomes `.engineUnavailable(requested:error:)`. `BrowserView` then shows the error with a "Use
  System (WebKit)" button and a "Retry" button. The controller never switches engines on its own.
- A CEF start failure is sticky for the process, because CEF cannot re-initialize. Every error is
  a typed `BrowserError`.

## Chromium (CEF)

- Version: CEF `156.0.15+gcf671c0+chromium-156.0.8078.80`, the latest stable build on
  2026-10-31. It uses the "minimal" distribution, which already has everything needed: the
  framework, `libcef_dll`, and the headers.
  - macosarm64 SHA-256: `a27f1d856e84047657ed2a14caf355fb04480c4fe1963f04249a8a3184af1c30`
  - macosx64 SHA-256: `e2aedb3cb41cc293ff2db81245f3462c61c49e13ac137f628872889c8a36c702`
  - The script pins both the SHA-256 and the SHA-1 and verifies them with `shasum`.
- `apps/apple/scripts/fetch-cef.sh [--arch arm64|x86_64|universal]` does the following, and is
  idempotent:
  1. Downloads into the gitignored `apps/apple/Vendor/cef`.
  2. Verifies both checksums and fails on any mismatch.
  3. Builds `libcef_dll_wrapper.a` with CMake.
  4. Stages `Vendor/cef/out`, converting the framework to the versioned macOS layout that Xcode's
     product validation and `codesign` expect.
- **C++ wrapper, not the C API.** The bridge is Objective-C++ against `libcef_dll_wrapper`.
  - The C API needs hand-written ref counting for every struct, plus vtable-filling for every
    handler. That is a large, error-prone surface.
  - The wrapper is CEF's supported client API and is what cefclient and cefsimple use.
  - The wrapper is built in Release (`NDEBUG`) and statically linked. The bridge defines
    `NDEBUG` to match, so the base-header layouts agree.
  - The bridge header (`OmnigentCEFBridge.h`) is plain Objective-C. Swift never sees C++.
- **Loading.** The framework is never linked. The bridge `dlopen`s it with `cef_load_library`,
  and each helper uses `CefScopedLibraryLoader`.
- **Message pump.** CEF runs with `external_message_pump`. `OnScheduleMessagePumpWork` drives an
  `NSTimer` in common run-loop modes, with a 1/30 s ceiling, following cefclient's
  `MainMessageLoopExternalPump`.
- **`CefAppProtocol`.** The SwiftUI App lifecycle ignores `NSPrincipalClass` and uses its own
  `NSApplication` subclass. At start-up the bridge gives `NSApp` a dynamic subclass of whatever
  class it has, the same isa-swizzle that KVO uses. The subclass adds `CefAppProtocol`, wraps
  `sendEvent:` in `CefScopedSendingEvent`, and defers `terminate:` until every browser has
  closed. AppKit-lifecycle apps can use `OMCEFApplication` instead.
- **Embedding.** Browsers are Alloy-style children of an `NSView` (`OMCEFBrowserView`).
  `DoClose` returns true and detaches CEF's view. Its deallocation completes the close, so the
  host window is never sent `performClose:`.
- **Helpers.** CEF needs five helper apps in `Contents/Frameworks`: `<App> Helper`, plus
  `(GPU)`, `(Renderer)`, `(Plugin)` and `(Alerts)`. They all share `Helper/OmnigentCEFHelper.cc`,
  which enables Chromium's seatbelt sandbox with `CefScopedSandboxContext`.
  `apps/apple/Tuist/ProjectDescriptionHelpers/BrowserTargets.swift` defines the targets and the
  embed step (`Scripts/embed-cef.sh`). `Scripts/check-cef.sh` fails the build when CEF is missing
  or stale, or lacks an architecture being built.

### App Sandbox and entitlements

Stock CEF builds cannot run inside App Sandbox. Chromium's helper sandbox (seatbelt) cannot nest
inside it, and the Mac App Store variant of Chromium is not distributed as a CEF binary. The
Chromium engine checks for `APP_SANDBOX_CONTAINER_ID` and refuses to start under App Sandbox,
with an explicit error.

**Decision:** while it embeds CEF, the Mac app ships without App Sandbox. It uses Developer ID
signing, hardened runtime and notarization, the same model as the Electron app
(`web/electron/signing/entitlements.mac.plist`) and Chrome. Chromium's own sandbox stays on for
helper processes. If a Mac App Store build is ever needed, it would be a separate flavor with
only the system engine.

Hardened-runtime entitlements, verified by running the Example fully hardened:

| Bundle | Entitlements |
|---|---|
| App (browser process) | none needed for CEF |
| `Helper` | `cs.allow-jit` (CEF 156 runs Blink/V8 here; without it V8 cannot reserve its CodeRange) |
| `Helper (Renderer)` | `cs.allow-jit` |
| `Helper (GPU)` | `cs.allow-jit` |
| `Helper (Plugin)` | `cs.allow-unsigned-executable-memory`, `cs.disable-library-validation` |
| `Helper (Alerts)` | none |

Xcode 27 turns hardened runtime off for ad-hoc "Sign to Run Locally" Debug builds. Ad-hoc
signatures also have no Team ID, so library validation fails without
`disable-library-validation`. A real hardened test therefore needs a Developer ID or Apple
Development identity, which signs everything with one Team ID.

### Size

| Build | Framework on disk | Framework zipped | Helpers |
|---|---|---|---|
| arm64 | 331 MB | about 148 MB | about 0.8 MB each |
| universal | 581 MB | about 2x arm64 | about 0.8 MB each |

Release builds should fetch with `--arch universal`; Debug builds use the host architecture.

### Known issues

- **Intermittent teardown watchdog on quit.** Sometimes Chromium's Mac teardown watchdog fires
  inside `CefShutdown`. The process then exits with status 2 after the window has closed, and the
  NetworkService helper may still be flushing cookies.
  - Before the fixes, this happened in about 2 of 5 runs.
  - Two fixes were applied: CEF references are released, and the pump is drained before shutdown.
    Afterwards it was 2 of 10 runs, and 0 in 12 warm runs.
  - Moving `CefShutdown` ahead of `terminate:` made it worse, so that change was reverted.
  - Needs follow-up.

## Running the example

```sh
cd apps/apple
./scripts/fetch-cef.sh
cd Packages/OmnigentBrowser/Example
mise exec -- tuist generate --no-open
xcodebuild -workspace BrowserExample.xcworkspace -scheme BrowserExample build
<app>/Contents/MacOS/BrowserExample --engine chromium --screenshot /tmp/chromium.png
<app>/Contents/MacOS/BrowserExample --engine chromium --then system --screenshot /tmp/webkit.png
```

`--screenshot` waits for the page, logs the engine, URL, title and a `document.title` evaluation,
writes a PNG and quits. The page area comes from the engine's own snapshot, because
out-of-process web content does not render through `cacheDisplay`.

The Example's `Tuist/ProjectDescriptionHelpers/BrowserTargets.swift` is a symlink to the
product's helper, so the sample builds exactly what the app uses.

## Tests

`swift test` covers the following:

- engine kinds
- preference defaults and persistence
- controller fallback: a failed engine is surfaced and never swapped
- URL parsing
- profile keys
- script-value conversion
- CDP result parsing
- WebKit tab state, history and JS evaluation, using local file URLs
- reporting of navigation failures

The Chromium path is exercised by the Example app: it needs a bundled app with helpers, so it
cannot run headless under `swift test`. In the test runner, the real provider reports Chromium
as `engineNotBundled`, and that behavior is tested.
