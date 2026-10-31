# Native mobile app handoff

Branch: `feature/mobile-native-core`. This is a development checkpoint for
collaboration, not a release. The complete native app, supporting server changes,
tests, and design/validation notes are included.

## Start here

The app supports Sessions, Inbox and Settings, a native expandable composer,
message sending, streamed session events, harness/model selection, typed approval
forms, session creation, file uploads, and hosted sign-in with Keychain storage.
The existing WKWebView app remains a separate target.

The most useful next task is **real progressive reply delivery**. The latest
real-model probe generated a reply successfully, but the API SSE stream delivered
the entire 8,816-character answer in one chunk after about 119 seconds. The strict
validator correctly failed it. This does not yet identify whether the provider,
native harness bridge, or server buffered the response. Do not replace this
failure with a simulated/typewriter animation or count an injected fixture as a
real-model streaming pass.

Read [README.md](README.md), then the
[latest integration report](../../../designs/ios-native/integration-2026-10-31.md)
and [streaming procedure](../../../designs/ios-native/progressive-streaming-validation.md).
Historical `/private/tmp` logs, simulator IDs and session IDs in those reports
belong to the original machine. They are not included in a clone; create fresh
local sessions and evidence directories using the scripts below.

## Run on another Mac

Use Xcode 26+ with an installed conventional iPhone simulator runtime, Python and
`uv` as specified in the root contributor guide, Node.js, and `tmux` for the native
harness. From the repository root:

```sh
OMNIGENT_SKIP_WEB_UI=true uv sync --frozen --extra dev
bash web/ios/NativeLab/bin/local-services.sh install
bash web/ios/NativeLab/bin/local-services.sh start
bash web/ios/NativeLab/bin/local-services.sh status
.venv/bin/python web/ios/NativeLab/bin/seed-local-fixtures.py
open web/ios/NativeLab/NativeLab.xcodeproj
```

Select **NativeLab**, choose a regular iPhone simulator and run. Connect to
`http://127.0.0.1:6767`, or open the offline sample workspace. The local API and
host are isolated in `.native-lab-server`; no credentials, database, local agent
state, signing identity, or build products are supplied by this branch.

For real replies, configure and sign into the Codex native harness on your own
machine, then run:

```sh
.venv/bin/python web/ios/NativeLab/bin/prepare-live-session.py
```

Open the resulting **Native live chat** and send a message. An online host alone
does not prove valid provider credentials. A physical phone needs a reachable
authenticated HTTPS server; its loopback address is not the Mac's server.

## Verify changes

```sh
OMNI_LOCAL_API_TESTS=1 OMNI_KEYCHAIN_TESTS=1 \
  swift test --package-path web/ios/NativeLab
.venv/bin/python -m unittest discover -s web/ios/NativeLab/bin -p test_local_services.py
.venv/bin/python -m unittest discover -s web/ios/NativeLab/bin -p test_smoke_live_chat.py
```

The latest core run passed 288 tests with both opt-ins enabled and no skips;
the service/streaming script suites passed 36 tests. Targeted SE UI journeys
passed for credentials, HTTP rejection, connection handoff and retained drafts.
Before sharing this checkpoint, all 362 affected Python backend tests and all
applicable pre-commit checks also passed.
Run UI tests serially against the shared local fixtures. See the README for
the Xcode commands and exact opt-in variables. Real model tests incur provider
usage and never automatically resend an accepted or uncertain prompt.

Start with an SSE-only streaming probe, then use the coordinated native/web
observer described in the linked streaming report:

```sh
.venv/bin/python web/ios/NativeLab/bin/smoke-live-chat.py \
  --create-session --send-test-prompt --require-incremental \
  --evidence-dir /private/tmp/omni-streaming-new-run
```

## Where to work

| Concern                              | Main files                                                                                                                                |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Connection, drafts and lifecycle     | `App/AppModel.swift`                                                                                                                      |
| Hosted sign-in and saved credentials | `App/ServerConnectionControls.swift`, `Sources/NativeLabCore/ServerAuthenticationClient.swift`, `SecureServerStore.swift`                 |
| REST/SSE/WebSocket transport         | `Sources/NativeLabCore/LocalServerSessionClient.swift`, `LocalServerStreaming.swift`, `ServerConnection.swift`                            |
| Partial-text reconciliation          | `Sources/NativeLabCore/LiveConversationReducer.swift` and event/reconciliation tests                                                      |
| Real streaming proof                 | `bin/smoke-live-chat.py`, `UITests/NativeProgressiveStreamingUITests.swift`                                                               |
| Local API/host startup               | `bin/local-services.py`, `local-server.sh`, `local-host.sh`                                                                               |
| Server native echo and attachments   | Root `omnigent/inner/codex_native_executor.py`, `omnigent/server/routes/_sessions/orchestration.py`, `omnigent/runtime/pending_inputs.py` |
| Optional background push             | Root `omnigent/server/mobile_notifications.py`, `mobile_apns.py`; app `PUSH_SETUP.md`                                                     |

Hosted transport includes Databricks workspace routing via `?o=<numeric-id>`.
Actual hosted login, hosted SSE/WSS and standalone browser completion still need
deployment validation; credentials must be renewed through that deployment's
normal sign-in. APNs is disabled by default and has not delivered a real push.
Mounted/org-scoped push deployment alignment, physical-phone validation, and an
actual logout/reboot recovery test remain outstanding.

The screenshot directory contains historical test evidence, including earlier
layout defects. Machine-specific configuration text is redacted where present;
redactions are annotations, not evidence of a changed UI.
