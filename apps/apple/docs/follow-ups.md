# Native apps: follow-up list

The running list of deferred and follow-up work for the native Apple apps and the Rust core.
Keep it current:
- add items when work is deferred;
- move finished items to "Done", with the date and the change that closed them;
- link the design doc that has the details instead of repeating them here.

## Browser: Apple passkeys and http/https

Details: [browser-engine-decision.md](browser-engine-decision.md), sections "Entitlements and the
Apple process" and "Recommendation and plan" (phase 1b).

- [ ] **Register `OmnigentMac` as a web browser.** Add `CFBundleURLTypes` for `http` and `https`
  to the Info.plist. Apple's passkey criteria expect it, and it also makes Omnigent selectable as
  the default browser in macOS. Deferred by the user on 2026-11-01; decide before the entitlement
  request.
- [ ] **Apply for the passkey entitlement.** Request `com.apple.developer.web-browser.public-key-credential`
  through "macOS Browsers Passkeys"
  (https://developer.apple.com/contact/request/macos-browsers-passkeys/). The Account Holder
  submits it for `ai.omnigent.mac.webhost`, probably `ai.omnigent.mac` too, and
  `ai.omnigent.mac.appstore` if the WKWebView edition needs passkeys for arbitrary sites. Until
  then, iCloud Keychain passkeys and Touch ID don't work in the Chromium browser. Security keys,
  Okta FastPass and 2FA codes work without it.
- [ ] **After approval:** enable the capability on the App ID and create a Developer ID
  provisioning profile for the host bundle. Add the Release-only host entitlements
  (`web-browser.public-key-credential`, `keychain-access-groups`
  `$(AppIdentifierPrefix)org.chromium.Chromium.webauthn`). The exact diff is in the doc.
- [ ] **Run the manual hardware checklist:** YubiKey with a PIN, iCloud Keychain passkeys,
  phone-as-passkey over Bluetooth, and Okta (see the doc's "Manual test checklist").

## Browser: CEF

- [ ] **Okta SSO extension:** it returned `NotSupported` for the Chromium host in the spike. Retest
  with a Developer ID-signed build, and compare with Google Chrome's
  `chrome://histograms/Enterprise.ExtensibleEnterpriseSSO`. If Okta flows need it, add a per-site
  WebKit fallback (`BrowserEngineKind`); the trade-off is that the tab uses WebKit cookies.
- [ ] **Managed allowlist** for local-network access, so organisations can pre-approve Okta
  FastPass's loopback probe.
- [ ] **WebKit WebAuthn:** the spike was inconclusive ("document is not focused"). Retest in a
  focused window.
- [ ] **Bug:** the Chromium tab's "No app opens …" message for external links is overwritten by
  the next state sync.
- [ ] **Prebuilt engine pipeline (phase 2):**
  - Stand up 2+ self-hosted Apple Silicon builders (64 GB RAM, 1 TB+ SSD, label
    `chromium-engine`).
  - Move `scripts/engine/chromium-engine.yml` to `.github/workflows/`.
  - Publish a first unpatched `omnigent.1` build to prove the pipeline, then pin
    `scripts/engine/omnigent-cef.lock`.
- [ ] **CEF patches (phase 2b):**
  - native back/forward history restore (today we rebuild history with placeholders)
  - tab freeze and discard hooks, with memory-pressure handling
  - renaming the WebAuthn keychain group to `ai.omnigent.mac.webhost.webauthn`
  - proprietary codecs (H.264, AAC), after a license review
  - Widevine, which needs a separate agreement with Google
- [ ] **Custom Chromium host (phase 3),** only if Chrome Web Store extensions or Chrome's own
  TabManager become requirements.
- [ ] **Known CEF limits, not yet scheduled:**
  - DevTools opens in a separate window
  - audio detection covers `<audio>`/`<video>` only
  - clearing site data is coarse
  - Chrome Enterprise device-trust checks can never pass outside Google Chrome

## Remote browser

Details: [remote-browser-design.md](remote-browser-design.md).

- [ ] Diff the core's macOS keycode and USB-HID to DOM `code` tables line by line against
  Chromium's (`ui/events/keycodes/dom/dom_code_data.inc`); HID 0x32 maps to `Backslash` per the
  W3C spec, Chromium may use `IntlHash`.
- [ ] Host: x264 sometimes ignores a qpfile IDR request ("switching to encoder restarts"); the
  restart fallback works, but find out why the in-stream IDR path is skipped.
- [ ] Confirm hardware H.264 decode on a physical iPhone/iPad (simulators have no hardware decoder;
  the renderer logs the VideoToolbox probe at launch).
- [ ] Add a reconnect-after-unexpected-close case (with backoff) to the headless e2e gate.
- [ ] M2 to M5 from the design doc: agent CDP and tab mapping, handoff and takeover, profiles,
  settings and hardware encoders.
- [ ] **Share the CEF core between the OWL host and `browser-host/`.** M1 copied and adapted the
  portable parts of `WebHost/Sources` (popups, JS dialogs, IME, cursor mapping) instead of
  extracting them, to leave the Mac host untouched. Extract them into `browser-host/core` with
  both hosts building it.
- [ ] **Agent-created tabs over CDP (M2).** Playwright `newPage()` fails and raw
  `Target.createTarget` makes a non-windowless browser that never paints
  ([remote-browser-m0.md](remote-browser-m0.md)). Add `browser_tabs open`, or a CDP proxy that
  turns `Target.createTarget` into a host tab.
- [ ] **macOS host: `CefShutdown` stalls** while Chromium releases a Keychain handle (seen when
  launched from an agent shell). The host bounds it to 5 s and kills its helpers; find the cause.
- [ ] **Re-run the M0 render and live bench on a 2-4 vCPU cloud VM** before fixing the CPU
  budget and the Linux display default (headless Ozone vs Xvfb).
- [ ] **Package the host** (G1): link libjpeg-turbo statically, CI builds for linux x86_64 and
  arm64 and macOS arm64, `omnigent browser install`.
- [ ] **Gate remote browser tabs on the server.** The apps offer them only behind the
  `OmnigentRemoteBrowser` user default (or `OmnigentRemoteBrowserFixture` for the fixture host)
  because nothing advertises them yet; gate on a `/v1/info` or runner field once one exists.
- [ ] **iOS remote tab input (E3):** on-screen keyboard driven by `text_input`, marked text, and
  pinch to zoom the video. M1 has taps, long press, pan or trackpad scroll and hardware keys.
- [ ] **macOS IME caret:** place the candidate window at the host's `text_input.caret` instead of
  the page's bottom-left.
- [ ] **Video off the main thread:** frames hop to the main actor before
  `AVSampleBufferDisplayLayer` enqueue; move enqueue to a dedicated queue if main-thread stalls
  show up in frame age.

## Server (upstream omnigent)

- [ ] **Edit approvals:** send the full tool input, or a structured list of file changes, for edit
  tools. Previews are capped at 1024 characters, so large edits show no line counts.
- [ ] **Codex `item/fileChange/requestApproval`:** attach the `changes` from the matching
  `fileChange` item; today the approval lists no files.
- [ ] **Capabilities:** advertise feedback and steering support, so clients show only the controls
  a harness supports.
- [ ] **Pending-input queue:** stop treating the runner's interrupt marker as consuming a queued
  message.
- [ ] **CLI:** remove the pidfile on SIGTERM.
- [ ] **Session delete:** the server's `DELETE /v1/sessions/{sid}` ignores the runner's response
  status (only transport errors are caught, then it deletes server-side anyway), so a runner
  `resource_cleanup_failed` 500 (for example a browser host that failed to close tabs) is not
  surfaced (`omnigent/server/routes/sessions/routes_events.py`, around line 3835).

## Apps

- [ ] **Read state:** persist this device's read marks across relaunches; today they are kept in
  memory only.
- [ ] **Sub-agents:** a child session can appear both in the parent's mirrored count and in its own
  list row, which may double-count "needs you".
- [ ] **Sub-agents:** a running child's elapsed time uses the wall clock.
- [ ] **iPhone reading posture:** the focus guard ignores a deliberate tap on the composer within
  1 s of opening a session.
- [ ] **iPhone:** transcript content shows briefly under the dock and composer while the layout
  settles.
- [ ] **Tabs:** drag-to-reorder on iPad.
- [ ] **Test data:** remove the two "Tabs fixture" sessions from the integration server's
  database.
- [ ] **Share:** the session Share control isn't wired in the real app yet; there's no share store
  or core API.
- [ ] **Tabs:** the overview menu's "Recently Closed" entries are inert labels.
- [ ] **Tabs:** the titlebar tab row reserves a fixed estimated width for the trailing controls. An
  account chip or four viewers may leave a gap or push items into overflow; measure it instead.
- [ ] **Lint:** `SupportingScreens`, `AdapterTests` and `NativeAppE2EUITests` have pre-existing
  swift-format/lint findings.

- [ ] **Decision forms:** wire `validateForm(fields:values:)` into `ConversationContainer` so the real
  app shows field-keyed form errors (the playground already does).
- [ ] **Mac sidebar:** with the window inactive, the Running and Needs you rows don't dim like the
  other rows (`QuickFilterRow` forces the primary color).
- [ ] **iOS sidebar:** the swipe actions still use system orange (Pin) and indigo (Archive).
- [ ] **CLI style:** the CLI composer has no host chip, and its status-line model menu duplicates
  `ConfigurationMenu`'s pickers (no agent switch).
- [ ] **CLI style:** fold the non-message hover host (`cliActions`) into the shared
  `messageActionsHost` once it takes arbitrary actions.
- [ ] **CLI style:** Styled renders fenced code without syntax highlighting.

- [ ] **Gallery:** page and flow toolbars leak into the gallery window's toolbar; captures draw
  modals and the tab strip in place (Open in Window shows the real chrome).
- [ ] **Gallery:** add `initial…` parameters so it can preset server settings panes, Inbox
  selection and the palette query (they live in private view state).
- [ ] **Gallery:** export takes about 1 s per image (blur and shadow rasterization); render at 1x
  or in parallel. Tests' `RenderSupport` could reuse `CatalogExporter.render`.
- [ ] **UI review from the gallery:** sign-in screens use system blue instead of the Omnigent theme;
  "Tell the agent instead" with a shared draft opens in both the inline card and the dock.

- [ ] **Tabs: primary chats accumulate.** Tabs span sessions per window and a session's primary
  chat cannot be closed, so every session opened from the sidebar stays in the strip until it is
  archived or deleted. Decide between per-session tab scoping, a preview tab, or a "Close
  Session in This Window" command.
- [ ] **Split view:** the other pane's Inbox, New Session and browser views still publish their
  toolbar items and focused values (only conversations and terminals defer to the focused pane);
  notification suppression covers only the focused pane's chat.

## Product decisions

- [ ] Mac app name, given the existing Electron `Omnigent.app`.
- [ ] Sparkle EdDSA signing key.
- [ ] Ankit's co-author credit on the NativeLab import.
- [ ] Reusing the iOS bundle ID requires a version above 0.3.2.

## Done
