# Handoff: native Apple apps (2026-11-02)

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
   demo). Rules in `AGENTS.md` ("Mac tests without UI automation"). Not yet built or run.

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
UI-test lock, integration servers on 6795/6797/6805/6835) were scratch tooling and did not move
with the branch. Mac UI tests take over the mouse and keyboard; run them only on an idle machine.

## Where things are documented

- Roadmap and reviews: `ui-ux-roadmap.md`, `ux-research/`.
- Deferred work: `follow-ups.md` (maintained list; check it first).
- Remote browser: `remote-browser-design.md`, `remote-browser-m0.md`, `browser-host/README.md`.
- Browser engine: `browser-engine-decision.md`. Phone supervision: `phone-supervision.md`.
- Composer sizing: `composer-sizing.md`. Real-app checklist: `verify-real-app.md`.

## Open decisions for the user

- Register OmnigentMac as an http/https browser and apply for Apple's passkey entitlement
  (deferred; see `browser-engine-decision.md`).
- Mac app name vs. the Electron `Omnigent.app`, the Sparkle EdDSA key, and Ankit's co-author
  credit on the NativeLab import.
- Server half of phone notifications (APNs), per `phone-supervision.md`.
