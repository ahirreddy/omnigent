# Browser engine decision: which Chromium for the Mac app

Status: decided 2026-11-01. Applies to the Developer ID edition (`OmnigentMac`). The Mac App
Store edition stays on WebKit.

Open items from this decision are tracked in [follow-ups.md](follow-ups.md).

## Decision

1. **Now: keep stock CEF in Alloy style, windowless, behind the OWL out-of-process host.** It
   already runs Chrome's WebAuthn stack and dialogs, sees USB security keys, and, after this
   change, passes Okta FastPass's loopback probe and hands `com-okta-authenticator:` links to Okta
   Verify. Passkeys from iCloud Keychain and Touch ID need entitlements on the host bundle, not a
   different engine. Apple must approve one of them.
2. **Next: build our own patched CEF in CI** and fetch it as a prebuilt binary, like
   `fetch-cef.sh` does today. Patches add what stock CEF lacks: native navigation-history restore,
   tab freezing and discarding hooks, and, after a license review, proprietary codecs. The OWL
   protocol, the layer model and the Swift API stay as they are.
3. **Later, only if Web Store extensions become a requirement: a custom Chromium host** ("full
   Atlas"). It is the only option with Chrome's extension system, session service and TabManager
   unchanged. It reuses the pipeline from step 2.
4. **CEF Chrome style is not an option for us.** It cannot render windowless, so it cannot feed the
   `CALayerHost` model, and in our host it crashed on creation (below).
5. **Okta fallback.** Okta's Apple SSO extension did not accept our Chromium process in the spike.
   If an Okta flow needs it, open that site in a WebKit tab. A per-site engine choice already
   fits `BrowserEngineKind`. The cost: that tab gets WebKit cookies, not Chromium ones.

## Environment of the spikes

- CEF 156.0.15+gcf671c0 (Chromium 156.0.8078.80), the pinned build from `scripts/fetch-cef.sh`.
- The web host from `WebHost/`, built by the `WebLayerExample` harness (the same `BrowserTargets`
  targets `OmnigentMac` embeds). It is ad-hoc signed: this machine has no Developer ID or
  development certificate (`security find-identity -p codesigning` lists none). Nothing
  entitlement-gated could be tested.
- macOS 26.7.1, M1 Max. Attached: a YubiKey (USB, FIDO+CCID). Okta Verify 9.61.1 is installed and
  listening on `127.0.0.1:8769`. The Mac is managed and has Okta's `Okta Device` Credential SSO
  extension configured for the org's Okta host.
- How to run: `WebLayerExample --proof authentication [--engine system]`, defined in
  `Packages/OmnigentWebLayer/Example/Sources/Proofs+Authentication.swift`. Proofs take
  screenshots only of host windows and the harness window.

## What we verified in our build

| Check | Current CEF (Alloy, windowless) | WebKit engine |
|---|---|---|
| `PublicKeyCredential` and client capabilities | Present. `hybridTransport` and `passkeyPlatformAuthenticator` are true; `userVerifyingPlatformAuthenticator` is false | Present. `userVerifyingPlatformAuthenticator` is true |
| Platform passkey request (`authenticatorAttachment: platform`) | Chrome's dialog opens as a native host window, in front, with the host activated: "Your device can't be used with this site". Log: Touch ID is unavailable because the `keychain-access-groups` entitlement `<team>.org.chromium.Chromium.webauthn` is missing | `NotAllowedError: The document is not focused` from a scripted call. Inconclusive; Apple documents that WKWebView apps only get passkeys for their associated domains |
| Security key (YubiKey over USB) | Detected over HID with no entitlements. Chrome showed "Use your security key with example.com". A request that wanted a resident key and user verification showed "PIN required: set up a new PIN" because the key has no PIN. The proof aborted without touching the key, and later runs ask for presence only | Not reached (focus error above) |
| Hybrid (phone) transport | Blocked. Log: "Cannot use Bluetooth because the responsible app for the process does not have Bluetooth metadata in its Info.plist" | Not tested |
| CDP virtual authenticator (`WebAuthn.addVirtualAuthenticator`) | Register and sign-in both succeed on webauthn.io and passkeys.io | No CDP |
| Okta FastPass loopback (`https://example.com` fetching `http://127.0.0.1:8769/probe`) | **Before:** Chromium raised a Local Network Access permission request, the shared UI auto-denied it as an unknown permission, and the fetch failed. **After:** a "wants to use your apps and devices on your computer and local network" prompt; Allow returns 200 from the real Okta Verify | Fails (`TypeError: Load failed`) |
| Real Okta sign-in page (the org tenant, page load only, no credentials) | Loads. The sign-in widget immediately raised the same local-network permission request (denied in that run, before the fix) | Not tested |
| Apple Extensible SSO in Chromium | The code is in CEF 156: `chrome/browser/enterprise/platform_auth/extensible_enterprise_sso_*` and Okta's extension ID are in the binary. On the org's Okta host Chromium consulted it, but recorded only `Enterprise.ExtensibleEnterpriseSSO.NotSupported` (6 navigations): the OS or Okta's extension did not accept our process | WebKit's built-in path not tested |
| `com-okta-authenticator:` link (registered to Okta Verify on this Mac) | **Before:** `ERR_UNKNOWN_URL_SCHEME`, nothing opens. **After:** "This page wants to open a com-okta-authenticator: link in Okta Verify." OK opens it with `NSWorkspace` (the proof cancels) | **Before:** "unsupported URL" (-1002). **After:** same prompt |
| Unregistered custom scheme | Reported, no prompt | Reported ("No app opens ... links") |
| CEF Chrome style (`CefBrowserView` + `CefWindow`, `CEF_RUNTIME_STYLE_CHROME`) in our host | Crashed in `CefWindow::AddChildView` (`EXC_BAD_ACCESS`) with both the global and a persistent profile context; once a blank window with no page target. Not root-caused: needs CEF debug symbols. The spike code was removed | - |

What we only read about is cited in "Sources" and marked as such in the matrix.

## Requirement matrix

Legend: **Yes** (verified in our build), yes (documented, not verified here), partial, no.

| Requirement | (a) Current CEF (Alloy, windowless) | (b) CEF Chrome style | (c) Patched CEF (ours, CI-built) | (d) Custom Chromium host |
|---|---|---|---|---|
| **1. iCloud Keychain passkeys** | yes once the host carries `com.apple.developer.web-browser.public-key-credential` (Chromium checks it in the calling process; code present in CEF 156) | same as (a) | same as (a) | same as (a) |
| 1. Chrome-profile passkeys (Touch ID) | yes with `keychain-access-groups` `<team>.org.chromium.Chromium.webauthn` on the host (log above) | same | same, or rename the group with a patch | same |
| 1. Hybrid (phone QR/BLE) | yes once `NSBluetoothAlwaysUsageDescription` is in the app and host Info.plist; Chrome's dialog shows the QR code | same | same | same |
| 1. Security keys (USB CTAP2/U2F) | **Yes** (detected, dialog shown) | yes | yes | yes |
| 1. Security keys over NFC | no Mac has a reader for this (Apple: NFC keys work only with iPhone) | no | no | no |
| 1. 2FA: TOTP, push, SMS | **Yes** (plain web pages) | yes | yes | yes |
| 1. **Okta Verify: FastPass loopback** | **Yes** after this change (LNA prompt) | yes, Chrome's own LNA bubble | yes | yes |
| 1. Okta Verify: custom URI launch | **Yes** after this change | yes, Chrome's own dialog | yes | yes |
| 1. Okta Verify: Apple SSO extension | **No** in the spike (`NotSupported`); possibly fixable with the right signing or extension configuration, unverified | same as (a) | patch can debug it | same as (a) |
| 1. Okta: Chrome Device Trust connector | no, Google Chrome only (Okta docs) | no | no | no |
| **2. Address bar and suggestions** | ours (Swift `BrowserOmnibox`); Chrome's omnibox providers are not exposed | Chrome toolbar only, which we would not show | ours | Chrome's `AutocompleteController` reusable |
| 2. Autofill and passwords | partial: Chrome code runs; its popups are native widgets like the WebAuthn dialog, unverified | yes, Chrome UI | partial, as (a) | yes, with our own UI |
| 2. Permission prompts | **Yes**, projected through OWL (local network added here) | Chrome's bubbles | **Yes** | yes |
| **3. Session restore with back/forward** | partial: placeholder history rebuild (`DESIGN.md`) | unconfirmed; no CEF restore API | yes, with a restore-entries patch (`NavigationController::Restore`) | yes, Chrome's `SessionService` |
| **4. Background throttling** | yes: hidden views get `WasHidden`, so Blink throttles them | yes | yes | yes |
| 4. Memory-pressure handling | yes: Chromium's process-wide monitor is not CEF-specific (unverified) | yes | yes | yes |
| 4. Tab discarding and freezing | partial: our client can close hidden views and restore them lazily; no freeze API | partial: TabManager acts on Chrome `Browser` tab strips only | yes, with a freeze/discard patch | yes, `TabManager` and `PerformanceManager` |
| **5. Extensions** | partial: request-context-level extensions only; no Web Store (CEF #3859) | partial: Chrome UI extensions; Web Store unconfirmed | partial | yes, Web Store with our install UI |
| Fits OWL `CALayerHost` model | **Yes** | **no**: Views windows only, crashed in our host | **Yes** | yes, with an Atlas-style `CAContext` export |
| Prebuilt binaries only for developers | **Yes** (CEF CDN) | yes | yes, CI + GitHub Releases | yes, same pipeline |
| Engineering cost | done | high, and loses the layer model | medium: CI plus a few patches per Chromium bump | high: a new embedder |

## Okta Verify

Okta Verify is the minimum bar. Each way it authenticates on macOS:

1. **FastPass loopback.** The sign-in widget fetches `http://127.0.0.1:8769/probe` (fallback ports
   65111, 65121, 65131, 65141 and 65151, per Okta). Since Chrome 142, Local Network Access asks the
   user first; Chrome 146 split the permission into local-network and loopback. In our host the
   request reaches `OnShowPermissionPrompt` with `CEF_PERMISSION_TYPE_LOOPBACK_NETWORK` (or the
   older bits). **Fixed here:** protocol 1.3 maps it to `OWLPermissionLocalNetwork`. The shared UI
   asks once per site and remembers the answer. Okta Verify answers the probe with
   `Access-Control-Allow-Origin` set to the asking origin and `Access-Control-Allow-Private-Network:
   true` (checked with curl). Device-trust agents such as Kolide use the same loopback pattern.
   Managed Chrome on this Mac pre-allows only the Kolide origin in `LocalNetworkAccessAllowedForUrls`.
   - Follow-up: honor an admin allowlist for local network access from managed preferences
     (`ai.omnigent.desktop`), mirroring Chrome's `LocalNetworkAccessAllowedForUrls`, so managed
     fleets see no prompt.
2. **Custom URI launch** (`com-okta-authenticator:`, registered to `com.okta.mobile` here).
   **Fixed here:** `OnBeforeBrowse` cancels navigations to schemes Chromium does not render and
   sends `ExternalProtocol`. The client asks "This page wants to open a ... link in Okta Verify"
   and opens it with `NSWorkspace`. The host never launches apps. Agent tabs always decline. The
   WebKit engine does the same in `decidePolicyFor`. Universal links (https URLs that should open
   Okta Verify) are not intercepted; Chrome on macOS does not either.
3. **Apple Extensible Enterprise SSO.** Chrome 135+ supports OS SSO extensions; Okta's was added
   in Chrome 146. The policy is `ExtensibleEnterpriseSSOBlocklist`, and Okta documents "Chrome 146
   or later". The implementation is open-source Chromium with no branding guard, and it is
   compiled into CEF 156. In our ad-hoc-signed host it ran and recorded only `NotSupported`. Likely
   causes, unverified: the system or Okta's extension only serves known browser bundles, or the
   unsigned host lacks something. Next step: compare `chrome://histograms/Enterprise.ExtensibleEnterpriseSSO`
   in Google Chrome on the same Mac, then retest a Developer ID-signed build.
4. **Okta Verify as a passkey authenticator / FIDO2 behind Okta.** Okta's "Passkey (FIDO2
   WebAuthn)" authenticator uses the browser's WebAuthn. Security keys work now. Platform passkeys
   need the entitlements below. Okta does not document Okta Verify as a macOS passkey provider.
5. **Device trust that wants managed Google Chrome** (Chrome Enterprise Device Trust connector):
   never works in another Chromium. Okta Verify's own device signals (OS version, disk encryption,
   Secure Enclave) do not need Chrome. If a policy requires the Chrome connector, the user must
   use Google Chrome; no engine of ours can satisfy it.
6. **Push and TOTP** do not involve the browser.

**WebKit fallback.** If an Okta app policy needs the SSO extension and Chromium keeps answering
`NotSupported`, add a per-site engine rule: open the Okta host in a WebKit tab. WebKit uses Apple's
SSO stack. Trade-off: cookies set during that sign-in live in WebKit's store, so the Chromium tabs
of that app are not signed in. Copying cookies from `WKHTTPCookieStore` into Chromium with
`CefCookieManager::SetCookie` is possible for the session cookies of the IdP and the app, but
`HttpOnly` cookies set by redirects need care, and it is brittle per app. Prefer fixing Chromium's
SSO path first.

## Entitlements and the Apple process

The browser process that calls AuthenticationServices is `Omnigent Web Host.app`
(`ai.omnigent.mac.webhost`), not the main app. Entitlements go on the host bundle, which therefore
needs its own provisioning profile embedded at `Contents/embedded.provisionprofile`. Restricted
entitlements on Developer ID need a profile; a nested app bundle can carry one.

1. **`com.apple.developer.web-browser.public-key-credential`** (macOS 13.3+): passkeys and security
   keys through the system for any relying party, which gives iCloud Keychain. It is a managed
   capability:
   - The Account Holder submits the "macOS Browsers Passkeys" request
     (https://developer.apple.com/contact/request/macos-browsers-passkeys/) for the App ID
     `ai.omnigent.mac.webhost`, and probably `ai.omnigent.mac` too.
   - Apple's criteria: the app handles `http`/`https` URLs (declare `CFBundleURLTypes` for both);
     it shows a URL field, search or bookmarks on launch; it navigates and renders pages.
   - After approval, enable the capability on the App ID, create a Developer ID provisioning
     profile for the host, and embed it.
   - Not tied to being the default browser (`com.apple.developer.web-browser` is iOS-only).
   - Users approve once in System Settings > Privacy & Security > Passkeys Access for Web
     Browsers. Chromium triggers the request (`requestAuthorizationForPublicKeyCredentials`).
2. **`keychain-access-groups`**: `$(AppIdentifierPrefix)org.chromium.Chromium.webauthn` on the host,
   for Chrome-profile passkeys with Touch ID. This is a standard capability (no Apple review) but
   needs the same host profile. The group name comes from CEF's base bundle ID; a later CEF patch
   can rename it to `ai.omnigent.mac.webhost.webauthn`.
3. **`NSBluetoothAlwaysUsageDescription`** in the app and host Info.plists, for hybrid. The app is
   the "responsible" process for the host, so it needs the string too. No entitlement is needed
   without App Sandbox.
4. **USB security keys** need nothing for the unsandboxed Developer ID edition. FIDO HID devices
   do not trigger Input Monitoring.
5. **App Store edition (WKWebView):** WebKit handles WebAuthn itself, but third-party apps only get
   passkeys for relying parties in their associated domains. Arbitrary sites need the same
   browser passkey entitlement (`ai.omnigent.mac.appstore`), with the same request process.

Proposed project diffs (not applied; `Project.swift` and `Tuist/` belong to another change):

```diff
--- a/apps/apple/Tuist/ProjectDescriptionHelpers/OmnigentSettings.swift
+++ b/apps/apple/Tuist/ProjectDescriptionHelpers/OmnigentSettings.swift
@@ public static let webDeviceUsage: [String: Plist.Value] = [
     "NSLocationWhenInUseUsageDescription":
       "Web pages you open in Omnigent can use your location when you allow it.",
+    "NSBluetoothAlwaysUsageDescription":
+      "Web pages you open in Omnigent can use your phone or a Bluetooth security key to sign in.",
   ]
--- a/apps/apple/Tuist/ProjectDescriptionHelpers/BrowserTargets.swift
+++ b/apps/apple/Tuist/ProjectDescriptionHelpers/BrowserTargets.swift
@@ static let hostEntitlements: [String: Plist.Value] = [
     "com.apple.security.personal-information.location": true,
   ]
+
+  /// Release only, with a Developer ID provisioning profile for "<base>.webhost": platform
+  /// passkeys. The web-browser key is a managed capability that Apple must approve first.
+  static let hostReleaseEntitlements: [String: Plist.Value] = hostEntitlements.merging([
+    "com.apple.developer.web-browser.public-key-credential": true,
+    "keychain-access-groups": ["$(AppIdentifierPrefix)org.chromium.Chromium.webauthn"],
+  ]) { _, new in new }
```

Also in `BrowserTargets.hostTarget`: use `hostReleaseEntitlements` for Release (a second
`.entitlements` file selected by `CODE_SIGN_ENTITLEMENTS[config=Release]`), and set
`PROVISIONING_PROFILE_SPECIFIER` for the host in Release. Add
`CFBundleURLTypes` for `http` and `https` to the `OmnigentMac` Info.plist, which Apple's criteria
expect.

## Prebuilt engine pipeline

Developers never build Chromium. CI builds it, publishes it, and a script fetches it with a pinned
checksum, the same way `fetch-cef.sh` and `fetch-ghostty.sh` work today.

- **Build:** `scripts/engine/build-cef.sh` runs CEF's `automate-git.py` for one architecture. It
  checks out the CEF branch and commit, applies `scripts/engine/patches/{chromium,cef}/*.patch`,
  builds a minimal distribution with release GN args, and writes
  `omnigent-cef-<build>-<platform>-minimal.tar.bz2` plus `.sha256`. Patches are
  plain `git apply` files kept in this repo, so each Chromium bump is a rebase of a short list.
- **CI:** `scripts/engine/chromium-engine.yml` is a draft workflow (move it to `.github/workflows/`
  when builders exist). It is manually dispatched with the CEF branch, commit and build ID. It
  builds arm64 and x86_64 on self-hosted Macs, attests provenance with
  `actions/attest-build-provenance`, verifies checksums, and creates the prerelease
  `engine-<build>`.
- **Hosting:** GitHub Releases on this repo. A minimal CEF archive is about 100 to 150 MB per
  architecture; the per-asset limit is 2 GB. Each archive gets a provenance attestation
  (`gh attestation verify`).
- **Versioning:** `<chromium version>-omnigent.<n>`, for example `156.0.8078.80-omnigent.1`, in the
  tag and asset names. The CEF version string inside stays CEF's, so `check-cef.sh` keeps working.
  A bump that only changes patches increments `<n>`.
- **Pinning and fetch:** `scripts/engine/omnigent-cef.lock` holds the version, build ID, release
  URL and per-architecture SHA-256. `fetch-cef.sh --source omnigent` (or
  `OMNIGENT_CEF_SOURCE=omnigent`) downloads, verifies and stages exactly like the stock source.
  The default stays `spotify` until the first build is pinned. Switching also sets
  `BrowserTargets.cefVersion` in the same change.
- **Signing and notarization:** CI artifacts are unsigned. `WebHost/Scripts/embed-cef.sh` already
  re-signs the framework with the app's identity and hardened runtime, and the release notarizes
  the whole app, so nothing changes in `RELEASE.md`.

**Infrastructure needed**

- Two or more self-hosted Apple Silicon builders, for example Mac Studio M2 Ultra or M4 Max with
  64 GB of RAM and 1 TB or more of SSD, registered with the label `chromium-engine`. One can build
  both architectures (x86_64 is a cross build). Expect several hours for a cold build and well
  under an hour incremental with the checkout kept (CEF's guide: about 4 hours on a 16-thread
  machine; Apple Silicon time unconfirmed). AWS EC2 Mac (`mac2-m2pro.metal`, `mac-m4.metal`) also
  works but bills a 24-hour minimum per host.
- GitHub-hosted macOS runners are not enough: 14 GB of disk and a 6-hour job limit. Electron uses
  remote execution for this. ungoogled-chromium chains resumable jobs on sponsored runners.
- Optional: a remote build cache or execution backend (siso or reclient against EngFlow,
  BuildBuddy or NativeLink). Chromium documents remote execution for macOS only for Googlers, so
  treat it as an experiment. ccache is the supported local accelerator.
- A maintainer with release permissions to dispatch the workflow and pin the lock file.
- A license review before enabling `proprietary_codecs`/`ffmpeg_branding=Chrome` (H.264, AAC).
  Widevine needs a separate agreement with Google.

## Recommendation and plan

| Phase | Work | Needs a Chromium build |
|---|---|---|
| 1 (this change) | Protocol 1.3: local-network prompts and external-app hand-off on both engines; sign-in spike proofs | no |
| 1b | Entitlements and Info.plist keys above; Apple passkey request; Developer ID profile for the host; manual hardware checklist below | no |
| 1c | Okta SSO extension investigation (signed build vs Chrome histograms); managed local-network allowlist; WebKit per-site fallback if needed | no |
| 2 | Stand up the builders and the workflow; first `omnigent.1` build with no patches, identical to stock, to prove the pipeline | yes (CI) |
| 2b | Patches: navigation-entry restore, freeze and discard hooks, WebAuthn keychain group, codecs after review | yes (CI) |
| 3 | Re-evaluate a custom host if Web Store extensions or Chrome's TabManager are required | yes (CI) |

Phase 1 meets the must-have requirements once Apple approves the entitlement. Requirements 3 and
4 move to "yes" with phase 2b. Requirement 5 stays partial until phase 3.

## Manual test checklist

Use a Developer ID-signed build with the entitlements from phase 1b, unless a step says otherwise.
Open each site in an Omnigent browser tab with the Chromium engine.

**Security key (YubiKey, USB)**
1. https://webauthn.io: register with "Authenticator attachment: cross-platform". Expect Chrome's
   "Use your security key" window in front of Omnigent. Touch the key. Then authenticate. Both
   succeed.
2. https://webauthn.io with "User verification: required": if the key has a PIN, expect a PIN
   field you can type into. If it has none, expect "PIN required: set up a new PIN"; cancel unless
   you want to set one.
3. Unplug the key mid-request: the dialog changes and the page gets `NotAllowedError` after you
   cancel.
4. U2F-only site (legacy): https://demo.yubico.com/webauthn-technical/registration with "U2F"
   compatibility. Expect the same dialog.
5. Note whether the dialog opens over the Omnigent window or on another display. Today Chromium
   centers it on the main screen.

**Platform passkeys (needs the Apple entitlement)**
6. First request: macOS asks to allow Omnigent to use passkeys (Privacy & Security > Passkeys
   Access for Web Browsers). Allow.
7. https://passkeys.io: create a passkey; choose iCloud Keychain in the system sheet; Touch ID.
   Sign out, sign in with the passkey. Confirm it shows in the Passwords app.
8. A site where you already have an iCloud Keychain passkey (google.com, github.com): sign in with
   it. Conditional UI (autofill suggestions in the username field) should list it.
9. Without the entitlement, expect "Your device can't be used with this site". That is today's
   result and the baseline.

**Hybrid (phone as passkey; needs the Bluetooth usage string)**
10. Turn Bluetooth on. On https://passkeys.io choose "Use a phone or tablet". Expect a Bluetooth
    permission prompt for Omnigent the first time, then a QR code. Scan it with an iPhone or
    Android phone, approve on the phone, and sign in.

**Okta (use your real Okta org)**
11. Open your Okta dashboard (https://<org>.okta.com) in an Omnigent tab. On load, expect "<org>
    wants to use your apps and devices on your computer and local network". Choose Allow (it is
    remembered).
12. Sign in with Okta FastPass ("Sign in with Okta FastPass" or the Okta Verify option). Expect
    Okta Verify to prompt (Touch ID or approve), then the dashboard. If the page says Okta Verify
    was not found, check that step 11 was allowed (Settings for that site) and that
    `lsof -nP -iTCP:8769 -sTCP:LISTEN` shows Okta Verify.
13. If Okta shows "Open Okta Verify", click it. Expect "This page wants to open a
    com-okta-authenticator: link in Okta Verify". OK switches to Okta Verify.
14. Open two or three Okta-protected apps from the dashboard that your org marks
    phishing-resistant or device-assurance protected (for example Google Workspace, Slack, GitHub
    Enterprise, Jira/Confluence). Each should open signed in, with no "device not trusted" page.
    Note any app that rejects the device and what the page says.
15. Repeat 11 to 14 in Google Chrome and compare. In Chrome open
    `chrome://histograms/Enterprise.ExtensibleEnterpriseSSO` after signing in: if Chrome shows
    `Okta.Result` and Omnigent does not, the SSO-extension path is the difference (see
    "Okta Verify", item 3).
16. Try the Okta flow with the WebKit engine (engine menu on the tab) to confirm the fallback.
17. Push and TOTP: sign in with "Get a push notification" and with a code from Okta Verify. These
    should work in every engine.
18. Kolide or another device-trust step, if your org uses one: expect a second local-network
    prompt for its origin; allow it and confirm the check passes.

Report for each step: pass or fail, the prompt text, and a screenshot of any failure page.

## Sources

Verified in our build: the "What we verified" table. Read only:

- CEF runtime styles; windowless always uses Alloy:
  https://github.com/chromiumembedded/cef/blob/master/include/internal/cef_types_runtime.h,
  https://cef-builds.spotifycdn.com/docs/151.2/structcef__window__info__t.html
- Alloy bootstrap removed in M128; Alloy extension API removed: https://github.com/chromiumembedded/cef/issues/3685
- Extensions in Alloy style: https://github.com/chromiumembedded/cef/issues/3859
- WebAuthn in CEF: https://github.com/chromiumembedded/cef/issues/3505,
  https://github.com/chromiumembedded/cef/issues/3508, https://github.com/chromiumembedded/cef/issues/3886
- CEF has no navigation-entry restore API:
  https://cef-builds.spotifycdn.com/docs/151.2/classCefBrowserHost.html
- Permission prompt defaults by style: https://cef-builds.spotifycdn.com/docs/151.2/classCefPermissionHandler.html
- Atlas OWL architecture and prebuilt Chromium for engineers: https://openai.com/index/building-chatgpt-atlas/
- Browser passkey entitlement and request criteria:
  https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential,
  https://developer.apple.com/help/account/capabilities/capability-requests/
- Chrome's entitlements: https://chromium.googlesource.com/chromium/src/+/main/chrome/app/app-entitlements-chrome.plist;
  iCloud Keychain gating: https://github.com/chromium/chromium/blob/main/device/fido/mac/icloud_keychain_sys.mm
- Passkeys Access for Web Browsers setting: https://support.apple.com/en-gb/guide/mac-help/mchl211c911f/27/mac/27
- WKWebView passkeys need associated domains:
  https://developer.apple.com/documentation/authenticationservices/supporting-passkeys,
  https://bugs.webkit.org/show_bug.cgi?id=220559
- Provisioning profiles and Developer ID: https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
- Bluetooth usage string: https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothalwaysusagedescription
- NFC keys only on iPhone: https://support.apple.com/en-us/102637
- Okta loopback ports: https://support.okta.com/help/s/article/okta-verify-loopback-ports-for-probing;
  Chrome LNA and FastPass: https://support.okta.com/help/s/article/configure-chrome-to-suppress-the-local-network-access-prompt-for-okta-fastpass,
  https://developer.chrome.com/blog/local-network-access
- Okta SSO extension and Chrome 146: https://help.okta.com/oie/en-us/Content/Topics/identity-engine/devices/config-credential-sso-ext-macos.htm;
  Chrome policy: https://raw.githubusercontent.com/chromium/chromium/main/components/policy/resources/templates/policy_definitions/Signin/ExtensibleEnterpriseSSOBlocklist.yaml
- Okta FastPass browser support: https://support.okta.com/help/s/article/fastpass-browser-support;
  Chrome Device Trust: https://help.okta.com/oie/en-us/content/topics/identity-engine/devices/chrome/edr-integration-dt-chrome.htm
- Chromium build requirements: https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md,
  https://chromiumembedded.github.io/cef/master_build_quick_start
- GitHub runner limits and pricing: https://docs.github.com/en/actions/reference/limits,
  https://docs.github.com/en/actions/reference/runners/larger-runners,
  https://docs.github.com/en/billing/reference/actions-runner-pricing
- EC2 Mac: https://aws.amazon.com/ec2/instance-types/mac/
- Electron CI: https://github.com/electron/electron/blob/main/.github/workflows/build.yml;
  ungoogled-chromium-macos: https://github.com/ungoogled-software/ungoogled-chromium-macos/blob/master/.github/workflows/building.yml
