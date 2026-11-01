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

## Product decisions

- [ ] Mac app name, given the existing Electron `Omnigent.app`.
- [ ] Sparkle EdDSA signing key.
- [ ] Ankit's co-author credit on the NativeLab import.
- [ ] Reusing the iOS bundle ID requires a version above 0.3.2.

## Done
