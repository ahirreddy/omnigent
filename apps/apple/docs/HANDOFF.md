# Handoff: native Apple apps (2026-11-02)

State of the `apple-native-scaffold` branch on `ahirreddy/omnigent`, for continuing the work on
another machine.

## Branches

- `apple-native-scaffold`: verified work. Each commit passed the Rust gate, the Swift package
  tests, strict SwiftLint and swift-format, and the OmnigentMac, OmnigentMacAppStore and iOS
  builds. The newest feature commit is `be2db3f30` (Review 3 top 10, phone supervision, remote
  browser iOS viewport modes).
- `apple-native-scaffold-wip`: the latest snapshot of work that was in progress when the session
  paused (see "In flight"). It builds per the agents' reports but was not verified as a whole.

## In flight (on the wip branch only)

1. **Liquid Glass pass (done, not yet merged).** System glass bars and soft scroll edges replace
   `TitlebarBackdrop`, `NavigationBarCanvas` and `BottomBarBackdrop`; `DesignSystem/Glass.swift`;
   glass composer; contrast roles extended for glass; `GlassBarsUITests` (Mac) and
   `GlassBarsPhoneUITests` (iOS). Decision recorded in `ui-ux-roadmap.md` ("Bars: glass
   decision"). Known gap: Mac split view panes show a flat toolbar instead of the soft edge.
2. **Safari-style remote browser chrome on iPhone (done, not yet merged).** Glass address pill at
   the top, floating toolbar at the bottom, collapse on scroll, page-colour tint, page menu with
   Sessions/Viewport/control. `RemoteBrowserChromeUITests`. See `remote-browser-design.md` 16.10.
3. **Remote browser UI test fixes (done, not yet merged).** Not regressions from Review 3:
   - The touch test reused a persisted viewport mode because `-remoteBrowser.viewportMode
     {"keep":{}}` is not a valid plist value; `RemoteBrowserUITestSupport` now quotes it.
   - iPad Pro 11 pinch lands off-centre; the pinch test now pans after zooming.
   - The Mac `RemoteBrowserUITests` line 105 failure is a host bug (no repaint after Back when
     many leftover tabs show the same site); it passes on a fresh host. Logged in follow-ups.
   With these, all four remote-browser iOS tests pass on iPad Pro 11 and iPhone 17 Pro. Not yet
   run on the final tree: the Mac remote-browser test against a fresh host, and the
   OmnigentRemoteBrowser package tests.

To finish: check out the wip branch, run the full verification below, re-run the three
remote-browser UI tests (Mac included), then squash the wip work into reviewed commits on
`apple-native-scaffold`.

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
