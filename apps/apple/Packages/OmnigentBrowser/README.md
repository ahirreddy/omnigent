# OmnigentBrowser

Embedded browser for the native Omnigent apps, with two engines:

| Engine | `BrowserEngineKind` | Platforms | Default |
|---|---|---|---|
| Chromium, out of process in `Omnigent Web Host.app` (CEF) | `.chromium` | macOS only | macOS, when the host is bundled |
| The OS web view, currently WKWebView | `.system` ("System (WebKit)") | macOS, iOS, iPadOS | iOS and iPadOS, and macOS builds without the host |

App Store rules restrict iOS and iPadOS to WebKit. On those platforms the package compiles without
any Chromium code.

## Parity target

The scope comes from the Electron browser pane: `web/electron/src/browserViewRegistry.js`,
`browserIpc.js`, `browserActionScript.mjs`, and `browserUrlPolicy.js`. It also covers the
server's `browser.action_request` bridge (`omnigent/server/routes/sessions/routes_browser.py`,
`web/src/hooks/useBrowserAgentRelay.ts`) and the WKWebView usage in `web/ios`.

| Capability | Electron | This cut |
|---|---|---|
| Navigate, back/forward/reload/stop | yes | yes, both engines |
| Observable URL, title, loading, progress, can-go-back/forward | yes | `BrowserTabState`, both engines |
| Per-server/per-conversation storage isolation | in-memory partition per conversation, scoped per window | `BrowserProfile`: persistent per server or ephemeral per id. WebKit uses `WKWebsiteDataStore(forIdentifier:)`; Chromium uses a web-layer `Profile` (one `CefRequestContext` in the host; ephemeral ones are in-memory) |
| JS evaluation (agent snapshot/click/type scripts) | `executeJavaScript` | `evaluateJavaScript` (completion value, promises not awaited). Chromium uses CDP `Runtime.evaluate` in the host; WebKit uses `evaluateJavaScript` |
| Screenshot (`browser_screenshot`) | `capturePage` | `takeSnapshotPNG`. Chromium composites the host's page and popup frames (open `<select>` menus included); WebKit uses `takeSnapshot` |
| Find in page | `find_preload.js` | `find(_:forward:caseSensitive:)` |
| DevTools | `openDevTools` | Chromium: `showDevTools()` opens CEF's DevTools window in the host process. WebKit: the view is inspectable from Safari's Develop menu; `showDevTools()` throws `featureUnsupported` |
| Popups / `window.open` | `popupPolicy.js` | Open in the same tab |
| Downloads | Electron default | Blocked and reported as `BrowserError.downloadsUnsupported` |
| Agent actions (`browser.action_request`: navigate/snapshot/click/type/screenshot) | yes | Primitives exist, plus renderer-direct agent input on Chromium (`WebContentRenderer.agent*`); the relay and the action-script port are not wired yet |
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
- Chromium starts asynchronously: the tab shows "Starting Chromium…" until the host is ready. A
  host crash or hang becomes `BrowserError.engineStopped` and a Reload overlay; Reload restarts
  the host. Every error is a typed `BrowserError`.

## Chromium

Chromium runs out of process, on the model of ChatGPT Atlas's OWL. The design, IPC, rendering
paths, the spike data behind them, and the proofs are in
[`../OmnigentWebLayer/DESIGN.md`](../OmnigentWebLayer/DESIGN.md).

- `OmnigentBrowserChromium` adapts the `OmnigentWebLayer` client (`Session`, `Profile`,
  `WebView`) to `BrowserEngine` and `BrowserTab`. It contains no CEF code and never loads CEF.
- The host, `Contents/Helpers/Omnigent Web Host.app`, owns CEF
  `156.0.15+gcf671c0+chromium-156.0.8078.80` (from `apps/apple/scripts/fetch-cef.sh`, pinned
  and checksum-verified) and its five helpers. Sources are in `apps/apple/WebHost`; targets are
  in `apps/apple/Tuist/ProjectDescriptionHelpers/BrowserTargets.swift`.
- `ChromiumEngineFactory.availability()` checks that the host executable is bundled and that
  the app is not running under App Sandbox. The host inherits the app's sandbox, and stock
  CEF's helper sandbox cannot nest in it.

### App Sandbox and entitlements

The Developer ID edition ships without App Sandbox, with hardened runtime and notarization, like
the Electron app and Chrome. Chromium's own sandbox stays on for the helper processes. The Mac App
Store edition contains no Chromium.

| Bundle | Entitlements |
|---|---|
| App | none needed for Chromium |
| `Omnigent Web Host` (browser process) | none |
| `Helper` | `cs.allow-jit` (CEF 156 runs Blink/V8 here; without it V8 cannot reserve its CodeRange) |
| `Helper (Renderer)` | `cs.allow-jit` |
| `Helper (GPU)` | `cs.allow-jit` |
| `Helper (Plugin)` | `cs.allow-unsigned-executable-memory`, `cs.disable-library-validation` |
| `Helper (Alerts)` | none |

Xcode 27 turns hardened runtime off for ad-hoc "Sign to Run Locally" Debug builds. A real
hardened test needs a Developer ID or Apple Development identity.

### Size

| Build | Host bundle on disk | Zipped | Helpers |
|---|---|---|---|
| arm64 Debug | 331 MB (framework 326 MB) | about 141 MB for the whole example app | about 0.76 MB each |
| universal | about 2x the framework | about 2x | about 0.76 MB each |

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

The web layer's own proof app, which covers rendering, input, popups, cookies, agent input,
crash, hang and quit, is `Packages/OmnigentWebLayer/Example` (see its DESIGN.md).

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
- error and script-value mapping from the web layer
- WebKit tab state, history and JS evaluation, using local file URLs
- reporting of navigation failures

The Chromium path is exercised by the example apps: it needs a bundled host, so it cannot run
headless under `swift test`. `OmnigentWebLayer` has its own tests for the wire format, the Mach
channel, input translation and session failure paths. In the test runner, the real provider reports Chromium
as `engineNotBundled`, and that behavior is tested.
