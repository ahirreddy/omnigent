# Handoff: native Apple apps (2026-11-04)

State of the `apple-native-scaffold` branch on `ahirreddy/omnigent`, for continuing the work on
another machine.

## Branches

- `apple-native-scaffold`: verified work. Each commit passed the Rust gate, the Swift package
  tests, strict SwiftLint and swift-format, and the OmnigentMac, OmnigentMacAppStore and iOS
  builds. The latest work is the Liquid Glass pass, the Safari-style remote browser chrome on
  iPhone, the remote browser UI test fixes and the host's Back repaint fix.
- `apple-native-scaffold-wip`: an older snapshot of that work in progress; superseded.

## Recently landed

1. **Liquid Glass pass.** System glass bars and soft scroll edges replace `TitlebarBackdrop`,
   `NavigationBarCanvas` and `BottomBarBackdrop`; `DesignSystem/Glass.swift`; glass composer;
   contrast roles extended for glass; `GlassContrastTests` and `GlassBarsPhoneUITests` (iOS).
   Decision recorded in `ui-ux-roadmap.md` ("Bars: glass decision"). Known gap: Mac split view
   panes show a flat toolbar instead of the soft edge.
2. **Safari-style remote browser chrome on iPhone.** Glass address pill at the top, floating
   toolbar at the bottom, collapse on scroll, page-colour tint, page menu with
   Sessions/Viewport/control. `RemoteBrowserChromeUITests`. See `remote-browser-design.md` 16.10.
3. **Remote browser fixes.** `RemoteBrowserUITestSupport` quotes the `-remoteBrowser.viewportMode`
   launch argument (it was not a valid plist value, so a persisted mode leaked in); the iPad pinch
   test pans after zooming; the host disables Chromium's back/forward cache, which in windowless
   mode restored pages without painting them (the old page stayed on screen after Back).
   `browser-host/tools/back_test.py` covers it.
4. **Mac tests without UI automation.** The streaming e2e is a hosted test
   (`LiveServerStreamingTests`, inside each edition's app, so the App Store sandbox is covered);
   remote browser input is a package test that sends AppKit events to a hidden window
   (`RemoteBrowserViewE2ETests`); the rest is covered by package and core tests, plus the new
   `ForkFlowTests`. Hosting tests, the app opens no windows and never becomes active. The Mac UI
   target keeps only the launch smoke and `WindowChromeUITests` (titlebar drags, on the offline
   demo). Rules in `AGENTS.md` ("Mac tests without UI automation").

Verified on 2026-11-03: both editions' hosted tests (14 each, live streaming included), the
remote browser package tests with a live host (50), the OmnigentAppUI tests (68), both Mac UI
tests on both editions, and on iPhone 17 Pro and iPad Pro 11 the four remote browser and two
glass UI tests. The Mac suite takes about 80 s without UI automation (it took 16 minutes).

5. **Databricks workspace sign-in on the Mac.** Workspace-hosted servers (for example
   `isaac.databricks.com`) need a Databricks OAuth bearer, even for discovery. The iOS HTTPS
   redirect cannot work on the Mac: `login.databricks.com`'s association file authorizes only
   the iOS app. The Mac apps now use the published `omnigent` client's loopback redirect
   (`http://localhost`, ephemeral port, system browser), as the Electron app does; the core binds
   each attempt to the listener's port. The App Store edition gained `network.server` for the
   listener. Covered by core, FFI and controller tests; the live sign-in needs a person.
6. **Replica routing for host-sharded servers.** isaac answers `400 wrong_replica` unless a
   request carries its session's host as `X-Databricks-Omnigent-Slice-Key` (the WebSocket takes
   `omnigent_slice_key`). `client-core/.../client/routing.rs` learns hosts from snapshots
   (walking sub-agent parents), keys sessions, terminals and remote browsers, retries keyless
   on a refusal, and freezes the modal host after the first list. `routing_tests.rs`.
7. **Sign-ins that survive rebuilds.** A Mac build without an Apple team ID (Debug, or the local
   Release below) is refused the data-protection keychain, and the login keychain ties items to
   the exact build. Such builds keep credentials in 0600 files (`CredentialFileStore`, chosen by
   `KeychainModeSelection`); a team-signed Release still requires the keychain.
8. **Networking verified without the app.** `LiveWorkspaceTests` (OmnigentStores) drive the core
   and the URLSession transports against a live workspace: list, history, live stream,
   terminals, and creating a session on a new managed sandbox (`create_sandbox_session`), sending,
   streaming and Stop. Needs `OMNIGENT_LIVE_WORKSPACE_URL` and `OMNIGENT_LIVE_CREDENTIALS`.
9. **Local build for daily use.** `just apple-install-local` builds Debug (debug Rust core, host
   arch; the user chose Debug for build speed), signs ad hoc without hardened runtime (library
   validation refuses ad-hoc frameworks) and installs `~/Applications/Omnigent Native.app`
   (`ai.omnigent.mac.lab`). Sparkle is off.

## How to build and verify on a fresh machine

```sh
just ensure                                   # tools and git hooks
just apple-generate                           # Rust core, CEF, libghostty, Tuist
just core-test && just core-wasm-check        # Rust gate
just apple-build && just apple-build-appstore && just apple-build-ios
cd apps/apple && mise exec -- swiftlint lint --strict --config .swiftlint.yml
```

- Every Swift package: `swift test --package-path apps/apple/Packages/<Package>`.
- Remote browser host: see `browser-host/README.md` (CMake; Homebrew `x264` on macOS,
  `ffmpeg` with libx264 on Linux; never link libx264).
- Remote browser end to end without UI automation: `RemoteBrowserE2ETests` in
  `OmnigentRemoteBrowser` (needs a server with `OMNIGENT_REMOTE_BROWSER=1` and the host).
- Gallery: `docs/gallery.md` (`swift run OmnigentPlayground --gallery`, `--export-gallery`).

The local test scripts used during the session (`/private/tmp/claude-502/...`: snapshot builds,
UI-test lock, integration servers on 6795/6797/6805/6835) are scratch tooling, kept with the
Claude Code session in the private repo `ahirreddy/omnigent-native-handoff` (its `restore.sh`
puts both back). Mac UI tests take over the mouse and keyboard; run them only on an idle machine,
and the user asked for background priority (`taskpolicy -b`, two jobs) while they use the Mac.

isaac is a multi-workspace host: use `https://isaac.databricks.com/?o=1965859176160743`.
Where crates.io is unreachable, cargo needs the Databricks crates proxy as a source replacement.

## Where things are documented

- Roadmap and reviews: `ui-ux-roadmap.md`, `ux-research/`.
- Deferred work: `follow-ups.md` (maintained list; check it first).
- Remote browser: `remote-browser-design.md`, `remote-browser-m0.md`, `browser-host/README.md`.
- Browser engine: `browser-engine-decision.md`. Phone supervision: `phone-supervision.md`.
- Composer sizing: `composer-sizing.md`. Real-app checklist: `verify-real-app.md`.

## Open decisions for the user

- Register OmnigentMac as an http/https browser and apply for Apple's passkey entitlement
  (deferred; see `browser-engine-decision.md`).
- Mac app name vs. the Electron `Omnigent.app` (the local build is "Omnigent Native"), the
  Sparkle EdDSA key, Developer ID signing, and Ankit's co-author credit on the NativeLab import.
- Next feature in line: a sandbox option in the New Session sheet (the core and store support
  it; see `follow-ups.md`).
- Server half of phone notifications (APNs), per `phone-supervision.md`.
