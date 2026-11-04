# Omnigent native Apple client

Native SwiftUI apps for Omnigent: macOS (the primary target, AppKit-native SwiftUI,
not Catalyst), then iPhone (including the foldable iPhone Duo) and iPad. They sit
alongside the existing WKWebView shell (`web/ios`) and the Electron app
(`web/electron`); neither is changed.

## Architecture

- **Rust core, `client-core/`.** Everything that does not need an OS SDK is written
  once in Rust. That covers wire models, SSE and WebSocket framing, reconnect and
  reconciliation, the transcript reducer, app state, auth logic, and send and
  decision bookkeeping. The core is sans-IO. It calls host traits for HTTP, event
  streams, WebSockets, timers, secure storage and logging, and it owns app state,
  which it publishes as granular change events.
- **UniFFI bridge.** `scripts/build-core.sh` builds the core into
  `OmnigentCoreFFI.xcframework` and generates the Swift bindings into
  `Packages/OmnigentCoreFFI`. Both outputs are build products, not committed.
- **Swift, transport and UI only.**
  - `OmnigentServices` implements the host traits with URLSession and the Keychain.
  - `OmnigentStores` mirrors core state into `@Observable` MainActor models.
  - `OmnigentUI` holds the cross-platform SwiftUI.
  - `OmnigentPlatform` holds the `#if os()` shims (push, haptics, pasteboard,
    QuickLook).
- **WASM.** The platform-neutral crates (`omnigent-core`, `omnigent-protocol`) must
  keep compiling for `wasm32-unknown-unknown`, so the web app can adopt them later.
  For now this is only a `cargo check`; there is no JS facade yet.

## Prerequisites

- macOS with **Xcode 27.2** (the 27.2 SDKs; minimum deployment OS is 26).
- **Rust** through rustup. `client-core/rust-toolchain.toml` pins the channel,
  components and Apple and wasm targets, and rustup installs them on first use.
- **mise**, which installs the Tuist version pinned in `apps/apple/.mise.toml`.
  Run `mise trust apps/apple/.mise.toml` once.
- **just** (`brew install just`).
- For the local services and streaming tools: the repo's Python environment
  (`OMNIGENT_SKIP_WEB_UI=true uv sync --frozen --no-dev`), plus Node.js and `tmux`
  for the native harness.

## Quickstart (macOS desktop app)

From the repository root:

```sh
just apple-generate         # Rust core (debug) + bindings, fetch-cef, tuist install, tuist generate
just apple-run              # build and launch OmnigentMac (alias: apple-run-mac)
just apple-test             # Swift package tests + OmnigentMac hosted tests
just apple-install-local    # Release build for daily use: ~/Applications/Omnigent Native.app
just apple-run-appstore     # build and launch OmnigentMacAppStore
just apple-test-appstore    # OmnigentMacAppStore hosted tests
just apple-test-ui          # both editions' UI tests (take the mouse; idle machine only)
just apple-lint             # strict SwiftLint over the whole tree
just core-test              # cargo fmt --check, clippy -D warnings, cargo test
just core-wasm-check        # wasm32 type-check of the core crates
```

After changing Rust, rebuild the core and bindings with `just apple-core` (or
`just apple-core release`). `just apple-build` and `just apple-build-appstore` build
without launching. Re-run `just apple-generate` after changing `Project.swift` or the
Tuist manifests.

`just apple-install-local` builds a Release, ad-hoc signed OmnigentMac (Rust core in release,
host architecture only) at background priority, and installs it as `~/Applications/Omnigent
Native.app`, apart from the Debug "Omnigent Lab" and the Electron "Omnigent". Without a team ID
it keeps sign-ins in files under `~/Library/Application Support/ai.omnigent.mac/LocalCredentials`
instead of the keychain, and Sparkle stays off. Rerun it to update; it quits the running copy
first. `--skip-prereqs` reuses the current core, CEF and workspace.

Then open `apps/apple/Omnigent.xcworkspace` in Xcode if you prefer to build from
there. There is no checked-in `.xcodeproj`; Tuist generates it.

### Two macOS editions

Both editions build the same sources (`Apps/Omnigent-macOS/Sources`). The only
compile-time difference is the `OMNIGENT_CHROMIUM` Swift condition, read in
`AppEdition.swift`.

| | `OmnigentMac` (Developer ID) | `OmnigentMacAppStore` |
|---|---|---|
| Bundle id (Release / Debug) | `ai.omnigent.mac` / `ai.omnigent.mac.lab` | `ai.omnigent.mac.appstore` / `ai.omnigent.mac.appstore.lab` |
| Distribution | Developer ID signing, hardened runtime, notarization, outside the Mac App Store | Mac App Store |
| App Sandbox | off (`OmnigentMac.entitlements`) | on, plus `network.client` (`OmnigentMacAppStore.entitlements`) |
| Browser engines | Chromium (the default, out of process) and System (WebKit) | System (WebKit) only |
| Chromium | `Contents/Helpers/Omnigent Web Host.app` (CEF and its five helpers); links `OmnigentBrowserChromium` | never linked or embedded; a build phase fails if it appears |
| Managed preferences | own domain, then `ai.omnigent.mac`, `ai.omnigent.desktop` | own domain only (`OmnigentManagedPreferencesOwnDomainOnly`) |
| Schemes and tests | `OmnigentMac`: `OmnigentMacTests`, `OmnigentMacUITests` | `OmnigentMacAppStore`: `OmnigentMacAppStoreTests`, `OmnigentMacAppStoreUITests` |

- Chromium runs in a separate host process on the model of ChatGPT Atlas's OWL (see
  `Packages/OmnigentWebLayer/DESIGN.md`). Stock CEF cannot run inside App Sandbox,
  so Chromium exists only in the Developer ID edition. `OmnigentBrowser` is
  engine-neutral and ships the system engine. `OmnigentBrowserChromium` registers
  Chromium with `DefaultBrowserEngineProvider.withChromium()`. Pickers list only
  `offeredEngines`, and a stored Chromium choice is ignored where it is not offered.
- The App Store edition reads managed preferences only from its own domain, so it
  needs no `temporary-exception.shared-preference` entitlement, which App Review may
  reject. MDM profiles for it target `ai.omnigent.mac.appstore`.
- The tests are shared. `Tests/OmnigentMacTests` and `Tests/OmnigentMacUITests` run
  against both hosts and branch on `OMNIGENT_CHROMIUM`. They cover the edition's
  engines, sandbox state, managed-preference domains, and the Settings engine picker.
- Debug builds of the App Store edition are named `OmnigentAppStore.app`, so both
  editions can share one build directory. Release names it `Omnigent.app`, so build
  the two editions' Release configurations in separate derived-data directories.
- Both editions register the `omnigent://` scheme. With both installed,
  LaunchServices picks one, so use `open -a <app> omnigent://...` to target one.

### Distribution

- **Developer ID (`OmnigentMac`).** Fetch a universal CEF first
  (`apps/apple/scripts/fetch-cef.sh --arch universal`). Archive the `OmnigentMac`
  scheme (Release), export with the Developer ID method, then notarize and staple:
  `xcrun notarytool submit Omnigent.zip --wait`, then `xcrun stapler staple Omnigent.app`.
  The web host and every helper are signed with the app's Team ID; the per-helper
  hardened-runtime entitlements are in `Tuist/ProjectDescriptionHelpers/BrowserTargets.swift`. Debug
  builds are ad-hoc signed, and Xcode turns hardened runtime off for them.
- **Mac App Store (`OmnigentMacAppStore`).** Archive the `OmnigentMacAppStore` scheme
  and upload through Xcode Organizer or `xcrun altool`. No CEF fetch is needed for it.
- Signing needs team `8RMX4WU6F8` identities, which these scripts do not provision.

### CEF (`scripts/fetch-cef.sh`)

`just apple-generate` runs `fetch-cef.sh --arch <host arch>` before `tuist generate`.
Set `OMNIGENT_CEF_ARCH` to override the arch, for example `universal` for Release. The
script downloads the pinned CEF into the gitignored `Vendor/cef`, verifies its SHA-256
and SHA-1, builds `libcef_dll_wrapper`, and stages `Vendor/cef/out`. It is idempotent.
Only the web host (`WebHost/`) compiles against it; the app never links CEF. `OmnigentMac`'s
build fails with a clear error when CEF is missing, stale, or lacks an architecture being
built. `OmnigentMacAppStore` does not need CEF.

### iPhone and iPad (later)

```sh
just apple-build-ios                      # simulator build, default "iPhone 17 Pro"
just apple-test-ios
just apple-run-ios                        # boot, install, launch
just apple-run-ios device="<name>"   # any name from `xcrun simctl list devices`
```

Set `OMNIGENT_APPLE_SIMULATOR` to change the default simulator.

## Layout

```
client-core/            Rust workspace: omnigent-protocol, omnigent-core,
                        omnigent-ffi (UniFFI surface), uniffi-bindgen, fixtures/
apps/apple/
  Tuist.swift  Project.swift  Tuist/   Tuist manifests and helpers
  .mise.toml                           pinned tuist
  scripts/build-core.sh                cargo -> xcframework + Swift bindings
  scripts/fetch-cef.sh                 pinned CEF for the Developer ID Mac edition
  WebHost/                             Omnigent Web Host.app: the out-of-process Chromium host
  Apps/Omnigent-macOS  Apps/Omnigent-iOS   app targets (OmnigentMac, OmnigentMacAppStore, Omnigent)
  Packages/                            local Swift packages (see Architecture)
  Tests/                               app UI tests
  Tools/                               local API/host services, seeding, smoke tests
  Reference/NativeLab/                 parity oracle (see below)
```

## NativeLab reference

`Reference/NativeLab` is Ankit's working native iPhone client, imported from
`ankit-db/omnigent@feature/mobile-native-core`. Its Swift core logic and tests are
the **specification and parity oracle** for the Rust port. Its URLSession code
becomes the Swift transport adapters, and its views become the starting UI. It is
kept as-is and **deleted once the port is complete**. Don't modify it or build
features on it. Until it is deleted, its own suite should stay green:

```sh
swift test --package-path apps/apple/Reference/NativeLab
```

Its `README.md`, `HANDOFF.md` and `PUSH_SETUP.md` hold the full history. The
design and validation notes are in `designs/ios-native/`.

## Local services (`Tools/`)

The tools run an isolated, single-user, loopback-only Omnigent API and execution
host for the apps. It is a separate server, so it has none of your hosted
sessions. All of its state (database, artifacts, configuration, logs) lives in the
gitignored `.native-lab-server/` at the repo root.

```sh
just apple-services install   # register login LaunchAgents (API + isolated host)
just apple-services start
just apple-services status    # also: stop, uninstall (both keep data)
just apple-seed               # stored test conversations; no model is invoked
```

- The API is at `http://127.0.0.1:6767`, with docs at `/docs`. The apps accept
  unauthenticated HTTP only for literal loopback addresses. Hosted servers use
  HTTPS sign-in.
- The services restart automatically and start at GUI login. If the port is
  taken, startup fails and leaves the other process alone. Logs are in
  `.native-lab-server/service-logs`.
- For foreground debugging, stop the managed services first, then run
  `bash apps/apple/Tools/local-server.sh` and, in a second terminal,
  `bash apps/apple/Tools/local-host.sh`.
- For real replies, configure and sign into the Codex native harness on your
  machine, then run `.venv/bin/python apps/apple/Tools/prepare-live-session.py`.
  It creates or reuses **Native live chat** but does not send a prompt. A
  connected runner alone does not prove the provider can respond.
- Tool tests: `.venv/bin/python -m unittest discover -s apps/apple/Tools -p 'test_*.py'`.

## Known open issue: real-model streaming arrives in one chunk

Real-model SSE replies currently arrive as a single chunk after about 119 seconds.
In the latest probe, an 8,816-character answer came in one chunk. It is not yet
known whether the provider, the native harness bridge, or the server buffers it.
The strict gate checks for this:

```sh
just apple-smoke-stream   # needs apple-services and a signed-in harness; uses provider credits
```

This gate is **expected to fail until the root cause is fixed**, and its result
must be reported honestly. Don't weaken it. Don't replace progressive delivery
with a simulated or typewriter animation, and don't count an injected fixture as
a real-model pass. The Rust SSE parser carries chunk-boundary property tests, so
client-side framing is verified separately from this end-to-end gate.

## CI

`.github/workflows/client.yml` runs on changes to `client-core/**` or
`apps/apple/**`:

- Rust: fmt, clippy, tests and the wasm32 check, on Linux.
- macOS app: strict SwiftLint, core build, fetch-cef (cached under `Vendor/cef`,
  keyed by the pinned CEF version and checksum), Tuist generate, then build and test
  of both `OmnigentMac` and `OmnigentMacAppStore`. Then the Swift package tests and
  the `Tools/` Python tests.
- iOS simulator build and test, which is non-blocking for now.

Pre-commit runs swift-format and SwiftLint (`scripts/swiftlint.sh`, a no-op without
swiftlint) on `apps/apple` (excluding `Reference/`), and `cargo fmt`/clippy on
`client-core`.
