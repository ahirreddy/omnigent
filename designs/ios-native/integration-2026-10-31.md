# October 31 integration: audit items 2, 3 and 4

Three parallel workers implemented hosted transport, managed local services,
and strict real-model streaming validation. The coordinator integrated the
native login UI, Keychain, project registration, lifecycle fixes, and tests.
Existing dirty work was preserved; no commits or resets were performed.

## 2. Hosted accounts

Implemented HTTPS API mounts, confirmed identity, password login, server OIDC
browser login, bearer tokens, saved accounts, device-only Keychain storage,
and sign-out/forget. Databricks workspace selectors use `?o=<numeric-id>` in
the configured API root and `X-Databricks-Org-Id` on all request transports.
Databricks org-scoped connections use workspace bearer tokens; browser/password
sign-in is supported for compatible standalone accounts/OIDC servers instead.
Automatic token renewal is not implemented.

Connection cancellation no longer cancels itself when Settings navigates to
Sessions. A 401 during initial data loading cannot be reported as a successful
connection or save a rejected token. Old notification registration cleanup runs
before the old client disconnects. Terminal connection errors stop the spinner.

Hosted account access is not live-verified. The cached CLI login could not
produce a token; one worker subsequently received a workspace IP ACL rejection.
Renew authentication from an approved network before the hosted endpoint checks.
Mounted/org-scoped APNs deployment support remains a separate limitation.

## 3. Persistent local services

Both user LaunchAgents are installed and healthy at `http://127.0.0.1:6767`.
They start at GUI login and restart exited processes. Login after reboot is
covered by installation policy; an actual reboot/logout/crash was not tested.
The final check retained API PID 61849 and host PID 61884, with the isolated
host online. The no-login listener remains loopback-only.

A new **Native live chat**, `dbfe0c3078724d1797bf38cf3ec40799`, is bound to that
online host. No prompt was sent to this normal chat. Older chats tied to the
previous host retain their data and are not silently rebound.

## 4. Real progressive streaming

Implemented a strict observer, disposable-session/model guards, timestamped
evidence, normal-web observation, and an opt-in native UI test. They require
multiple growing partials before the matching final assistant item; a full
reply delivered in one chunk fails.

One real prompt in a disposable session produced an 8,816-character reply after
about 119.195 seconds, entirely in one SSE chunk. Sending and receiving worked;
progressive delivery failed. The API did not report an exact model identity.
The separate native/web comparison could not launch its Pro test runner and
sent no prompt. Native visible growth remains unverified. The current evidence
does not localize buffering to provider, harness, or server.

See [streaming evidence](evidence/streaming-oct31.json) and the
[complete streaming procedure](progressive-streaming-validation.md).

## Verification

- 288 Swift core tests passed, zero skips, with both real loopback transport and
  isolated real Keychain tests enabled. Log: `/private/tmp/omni-final-core-oct31.log`.
- 19 service-manager tests and 17 streaming-validator tests passed; Ruff passed.
- iPhone SE UI checks passed for local paging/composer/tabs, demo/live draft
  preservation, secure credential clearing/exact URL editing, and HTTP rejection.
  These passed across focused runs, not one clean full UI-suite run.
- The draft roundtrip initially exposed self-cancellation; its repaired rerun
  passed. Credential typing initially hit the keyboard accessory; its test now
  explicitly dismisses the keyboard between fields and passed.
- The final credential test result is
  `/private/tmp/omni-auth-secure-fields-oct31.xcresult`. The draft roundtrip and
  HTTP rejection passed in `/private/tmp/omni-auth-recovered-oct31.xcresult`,
  whose earlier credential failure is superseded by the focused result.
- Simulator builds and strict Swift formatting passed. Xcode recorded one
  transient invalid-frame runtime warning during credential keyboard changes;
  final screenshots show usable controls. This warning has not been localized.
- Physical-device networking, real hosted login, browser completion, live hosted
  SSE/WSS, actual reboot recovery, and real progressive native growth are not
  claimed by these checks.

Screenshots: [hosted sign-in](screenshots/hosted-auth-se.png),
[HTTP rejection](screenshots/hosted-auth-rejected-http-se.png).

## How to test

From the repository root:

```sh
bash web/ios/NativeLab/bin/local-services.sh status
open web/ios/NativeLab/NativeLab.xcodeproj
```

Run NativeLab on an iPhone simulator. Connect to `http://127.0.0.1:6767`, open
the new **Native live chat** on the online host, and send a message. This tests
real local interaction; the currently observed reply arrives in one chunk.
For hosted accounts, enter the HTTPS API root and sign in with the server's
supported method; Databricks may require the `?o=` selector and a workspace token.

```sh
OMNI_LOCAL_API_TESTS=1 OMNI_KEYCHAIN_TESTS=1 \
  swift test --package-path web/ios/NativeLab
.venv/bin/python -m unittest discover -s web/ios/NativeLab/bin -p test_local_services.py
.venv/bin/python -m unittest discover -s web/ios/NativeLab/bin -p test_smoke_live_chat.py
```

Run `NativeServerConnectionUITests` and
`NativeLabLiveUITests/testDemoDraftSurvivesLiveModeRoundTrip` serially in Xcode.
The opt-in progressive test and its observer commands are in the linked report;
they may incur model usage and must pass without skips to establish streaming.
