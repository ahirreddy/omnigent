# Native Apple client: agent guidance

Read `README.md` first. These rules cover `apps/apple/` and the Rust core in
`client-core/`.

## Where code goes

- **Logic goes in Rust (`client-core`)** unless it needs an OS SDK. That includes
  wire models, request building, response handling, SSE and WebSocket framing,
  reconnect and backoff, reconciliation, reducers, app state, auth flow logic
  (PKCE, mode resolution, refresh timing), and validation. If a Swift change
  includes a branch on server data, it probably belongs in the core.
- **Swift is transport and UI.**
  - `OmnigentServices` implements the core's host traits (URLSession, Keychain,
    timers, ASWebAuthenticationSession).
  - `OmnigentStores` applies core change events to `@Observable` models.
  - `OmnigentUI` renders them.
  - `OmnigentPlatform` holds the OS shims.
- `omnigent-core` and `omnigent-protocol` stay sans-IO and wasm-clean. Don't add
  tokio, threads, `std::time::Instant` or OS-specific deps there. Check with
  `just core-wasm-check`.

## Swift

- Swift 6 language mode with complete strict concurrency. Don't silence it with
  `@unchecked Sendable` or `nonisolated(unsafe)` without a written justification.
  `@preconcurrency import` is allowed only for generated UniFFI code.
- Use `@Observable` and MainActor models. Don't use `ObservableObject` or
  `@Published` in new code.
- macOS is the primary target, in two editions that share every source file:
  `OmnigentMac` (Developer ID, Chromium) and `OmnigentMacAppStore` (App Sandbox,
  WebKit only). Edition differences go through `AppEdition` and the
  `OMNIGENT_CHROMIUM` condition, never through copied files. Code that only the
  App Store edition may not contain (Chromium) stays behind `OmnigentBrowserChromium`,
  and CEF itself only in the out-of-process web host (`WebHost/`, see
  `Packages/OmnigentWebLayer/DESIGN.md`). Never load CEF in the app process.
- Chromium is only for browser tabs (user and agent browsing). Anything that renders
  content inline outside a browser tab (HTML, SVG, rich previews, artifacts) uses
  WebKit with a non-persistent `WKWebsiteDataStore`: that rendering is stateless,
  and WebKit costs far less memory and CPU. Markdown stays native SwiftUI.
- `OmnigentMac` is the primary edition. Keep iOS and iPad compiling, and
  keep platform differences in `#if os()` shims, not in forked views.

## Errors and unknown data

- **Never swallow errors.** Every transport, decode and server error propagates as
  a typed error (Rust `CoreError`) to the caller or the listener and is shown in
  the UI. Don't use `try?`, empty `catch`, `let _ =` on a Result, or `.ok()` that
  drops information unless the reason is explicit and written down.
- Unknown server event or item `type`s decode to an explicit `Unknown { type, raw }`.
  They render a visible placeholder and are logged. Never drop them silently, and
  never hide a pending decision.

## FFI and bindings

- After any change to `omnigent-ffi` (or types it exports), regenerate with
  `just apple-core` and rebuild. Generated bindings and the xcframework are build
  products. Never hand-edit or commit them.
- Re-run `just apple-generate` after changing `Project.swift` or `Tuist/`. Don't
  commit generated `.xcodeproj` or `.xcworkspace` files.

## Server compatibility

The server and these apps release independently. An app may talk to an older or
newer server. Gate features on what the server actually advertises (`/v1/info`
and the `/.well-known/omnigent.json` manifest version and fields), not on assumed
versions. Missing fields mean "unsupported". Test against an older-shaped
response as well as the current one. See `web/electron/AGENTS.md` for the same
rule on the desktop shell.

## Reference and tools

- `Reference/NativeLab` is a read-only parity oracle for the Rust port and will be
  deleted. Don't edit or run anything in it, or build on it. Port behavior and tests
  into `client-core` and the packages, and name each ported test's Rust
  counterpart.
- `Tools/` (local services, seeding, smoke tests) touches only the gitignored
  `.native-lab-server/`. `just apple-smoke-stream` is a strict real-model gate
  that is currently expected to fail. Report its result honestly. Never fake
  progressive streaming or relax `--require-incremental`.

## Checks before handing off

```sh
just core-test && just core-wasm-check
just apple-generate && just apple-build && just apple-test
just apple-build-appstore && just apple-test-appstore && just apple-lint
```

Pre-commit runs swift-format (config: nearest `.swift-format`), `cargo fmt` and
clippy.

## Mac tests without UI automation

XCUITest drives the real mouse and keyboard through the accessibility API, about a second per
action, and takes over the machine. Test the Mac app without it:
- Behaviour (stores, adapters, layout, persistence, decisions) in the packages.
- AppKit input in package tests: put the view in a window that is never shown and send it
  `NSEvent`s (`RemoteBrowserViewE2ETests`). The pointer and keyboard are untouched.
- What needs the app process (its sandbox, entitlements, real transports) in the hosted tests
  (`Tests/OmnigentMacTests`, run inside each edition's app; `LiveServerStreamingTests`). Hosting
  tests, the app opens no windows and never becomes active (`OmnigentMacAppDelegate.isTestHost`).
- `Tests/OmnigentMacUITests` keeps only the launch smoke and the titlebar drags, which need the
  window server. Run them on an idle machine or before a release, not on every change.

When a UI test is unavoidable: build once and run every test in one `test-without-building`;
paste long text instead of `typeText`; wait for state (`waitForExistence`,
`waitForNonExistence`), not time.

## Follow-ups

Record deferred work in `docs/follow-ups.md` (browser, server, app and product items),
and move items to its "Done" section when they land.

## Git

Stage files explicitly by path (`git add path/to/file`). Never use `git add .`,
`git add -A`, or a bare directory.
