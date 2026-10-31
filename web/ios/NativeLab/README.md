# Omni Native Preview

For another developer taking over this branch, start with [HANDOFF.md](HANDOFF.md).

A native SwiftUI mobile workspace, built alongside the existing Omnigent app.
Enter your server's HTTPS API address and sign in, choose **Connect to local
server** for the simulator's single-user loopback API, or **Open sample workspace**
for the offline demo. Replies arrive
over SSE; session updates arrive over WebSocket. The transcript renders partial
text as received, including harness deltas that arrive after the enqueue response
has completed. See the
[streaming validation](../../../designs/ios-native/progressive-streaming-validation.md).
**Sessions, Inbox and Settings** remain available in both modes. Hosted transport
and sign-in are implemented; connection to this user's actual hosted workspace
still needs a renewed login and live validation.

The shipping WKWebView-based Omnigent target is unchanged. The original tested
prototype in Downloads is also untouched; current development is in this clone.

## Run

Use **Xcode 26 or newer** (for the Liquid Glass SDK) with an iOS 18+ simulator.
Xcode 27.1, the standard iOS 26.0 runtime and the Duo-only iOS 27.1 runtime
are installed on this Mac.

From the repository root:

```sh
open web/ios/NativeLab/NativeLab.xcodeproj
```

Select **NativeLab**, choose an iPhone or iPad simulator and press **Cmd-R**.
The installed app is **Omnigent Lab**, bundle ID `ai.omnigent.ios.lab`.
No signing team is needed for simulator use. A physical device requires
selecting your development team in Signing & Capabilities.

To use the running development API, keep `http://127.0.0.1:6767` in the welcome
screen and tap **Connect to local server**. Open a conversation and write in
the native composer; editable sessions support Send, turn interruption and
supported approval/question responses. Updates arrive automatically. The
connection status explains connecting/reconnecting/failure states.
Scroll up and choose **Load older messages** for older history. The list has
**Load more sessions**; search and filters apply to loaded sessions only. Inbox
discovers pending requests across the server inventory, not just loaded pages.
Settings lets you switch back to the sample workspace without losing its drafts.

### Hosted server sign-in

Enter the direct HTTPS API root, including a deployment mount such as
`https://your-workspace.example/api/2.0/omnigent`. Choose automatic discovery,
username/password, browser sign-in, or an access token issued for that server.
A protected workspace proxy can require explicit **Access token** selection
before discovery can succeed. A workspace token is distinct from a model API key.
For Databricks deployments that require a workspace selector, append
`?o=<numeric-workspace-id>` to the API root. The client sends that selector in
`X-Databricks-Org-Id` and keeps credentials and drafts separate for each workspace.

The app confirms the server's authenticated identity before showing sessions.
**Remember sign-in in Keychain** stores the token on this device, scoped to the
server's full API root and account. **Saved accounts** reconnects with that same
verified identity. Expired sign-ins require authenticating again; automatic
workspace OAuth renewal is not implemented. Settings provides **Sign out and
forget this account**. Server addresses and account IDs are saved in preferences;
passwords and tokens are never saved there. Browser sign-in uses the server's
own login flow, and API redirects are rejected.

Accounts/OIDC deployments and mounted workspace proxies require live validation
before release. See [hosted authentication validation](../../../designs/ios-native/hosted-auth-validation.md).

### Harness, model and reasoning

Session rows and both composers show the harness logo beside the reported model.
The send button uses that logo's color and updates only when a harness change is
confirmed. Full harness/model names remain available to VoiceOver and in session
details; unknown harnesses use a generic icon. Logo artwork reuses Omnigent's web
assets, with attribution bundled in `HarnessBranding-NOTICE.md`.
Tap that identity above the message field to open **Harness & model**. Search
the advertised models, choose supported reasoning, then tap **Apply to next
message**. **Done/Cancel** closes any picker page without submitting your draft.
Session details include the exact reported IDs, host and workspace. An unknown
model ID stays visible; missing data is not presented as a confirmed default.

Harness changes require confirmation and keep the same conversation, workspace
and message draft. The runtime resets and starts on next use; cross-provider
changes clear overrides. Configured host readiness does not prove provider
authentication or successful model execution. After a switch, an empty runner
catalog can use a labeled host preview, revalidated before applying.

Busy, read-only, archived and disconnected sessions remain inspectable but
cannot change settings. Updates arrive through the existing streams. If another
client changes settings while you edit, **Review current settings** is required.
Uncertain writes are never automatically retried, and sending waits for review.
Global provider settings remain in the web app.

### New live sessions and attachments

Tap **+** in Sessions, choose a ready host, harness, registered agent and an
absolute workspace path. Choose a model advertised by that host, or keep its
default. **Start session** opens the confirmed session with your first message
kept as a draft; tap **Send** once the stream connects. Creation does not provision
hosts or managed sandboxes. A lost creation acknowledgement requires reviewing
Sessions before another creation is allowed.

In either composer, tap the **paperclip**, then **Photos** or **Files**. The native
attachment sheet shows progress, cancellation, errors and uploaded files. Tap
**Done**, then **Send** with or without text. Limits: eight files / 25 MB per draft,
5 MB per image, 20 MB per PDF, 10 MB per text/code file. Uploaded references are
scoped to the session and server; only a confirmed accepted send clears its exact
attachment batch. Uploading alone stores a server file but does not send a message.
Removing an uploaded draft attachment does not delete that server file.
Live attachment drafts stay in memory and do not survive app termination.

### Background notifications

**Settings > Notifications** reports permission and provider availability.
**Sessions for alerts** selects owned sessions for approval/question, completion
and failure alerts. A notification opens its session only after connecting to
the matching server and identity. Push delivery runs on the server while iOS is
suspended; it does not depend on an open SSE connection.

The standard build has push disabled. Apple signing, a provider key and an
explicitly enabled server are needed for delivery. See [push setup](PUSH_SETUP.md)
for the opt-in development configuration, limitations and activation steps.
No real Apple push delivery has been verified for this change.

### Native events and activity

Known history items now have native presentation instead of unsupported-preview
messages. Routine resource creation/deletion and cancelled client-task receipts
live under **Session options > Session activity > Lifecycle history**, not in the
chat transcript. Nothing is discarded; this section shows events from loaded
history, newest first. Actual terminal output, attachments and failures remain
visible. Interrupted replies use a small **Stopped** marker, and failure details
expand from compact warnings.

Tap a card to inspect tool arguments/output, terminal history,
public reasoning summaries, compaction, command receipts, routing decisions,
retries and errors. Live tool output and summaries update as they arrive and
reconcile with saved history. Unknown future events retain bounded, sanitized
details rather than disappearing.

Open **Session options > Session activity** for streamed usage, tasks,
environment/MCP startup, resources, viewers, skills, child sessions and changed
files. Changed-file invalidations trigger a session-scoped read, not polling.
A superseded session provides an explicit link to its successor; the original
draft stays with its conversation.

Requests support native typed forms, single/multiple choice and custom answers,
plan feedback and advertised permission choices. Persistent permission changes
require explicit confirmation. Unsupported schemas remain blocked instead of
becoming binary approvals; external confirmation links open only on your tap.

Attachments have native metadata cards. **Preview file** explicitly fetches a
file belonging to the current session on the connected server, up to 10 MiB,
for a supported safe media type. Arbitrary external URLs, embedded payloads and
active content are not automatically downloaded or executed. Terminal/browser
events are readable activity; desktop-only execution stays on the desktop.

The full source-backed event matrix and verification boundaries are in the
[event coverage report](../../../designs/ios-native/event-coverage.md).

### Regular iPhone simulators

On this Mac, choose **Omni iPhone 17 Pro** or **Omni iPhone SE** as the run
destination to try a conventional phone screen. Both use iOS 26.0; the SE
exercises the smaller 4.7-inch layout. Press **Cmd-U** to run the UI journeys
on the selected phone. Tests use isolated sample data, not your normal preview
workspace.

On another Mac, add a standard iOS runtime in **Xcode > Settings > Components**
and create a phone in **Window > Devices and Simulators**. The Duo-only runtime
does not support regular iPhone models. The equivalent Apple Silicon runtime
installation command used here is:

```sh
xcodebuild -downloadPlatform iOS -buildVersion 26.0 -architectureVariant arm64
```

This downloads approximately 8 GB. See the validation notes below for actual
device/test results; an installed simulator alone is not a passed test.

### Test on your own iPhone

1. Connect an iPhone running iOS 18 or newer to this Mac, unlock it and accept
   **Trust This Computer** if prompted.
2. In Xcode, add your Apple account under **Settings > Accounts** if needed.
   Select the **NativeLab** app target, open **Signing & Capabilities**, leave
   automatic signing enabled and choose your own development team. Do not
   commit personal signing settings. If the bundle identifier is unavailable
   for your team, use a unique local identifier.
3. Enable **Settings > Privacy & Security > Developer Mode** on the iPhone
   when Xcode requests it, then complete the device's restart/confirmation.
4. Choose the connected iPhone as the **NativeLab** run destination and press
   **Cmd-R**. Complete any development-profile trust prompt on the device.
   A paid membership is not required for personal-device testing; a free
   Personal Team may require periodically rebuilding the app.
5. Open **Omnigent Lab > Open sample workspace** and follow the checks below.
   Test the software keyboard, selection/paste, dictation, rotation, large text
   and leaving/reopening the app. These checks do not connect to a live server.
   To test real sessions, enter a reachable HTTPS Omnigent API address and sign
   in. The Mac's loopback server is available to Simulator only.

This is a development install, not a TestFlight or App Store release. No
physical-device validation is claimed until these steps have been completed.

## Local API development server

This separate server does not contain sessions from your hosted Omnigent
account. The app connects only after you explicitly select it. Unauthenticated
HTTP is accepted only for literal loopback addresses (`127.0.0.1` or `[::1]`).
Hosted servers use the separate HTTPS sign-in flow above.

From the repository root:

```sh
OMNIGENT_SKIP_WEB_UI=true uv sync --frozen --no-dev
bash web/ios/NativeLab/bin/local-services.sh install
bash web/ios/NativeLab/bin/local-services.sh start
bash web/ios/NativeLab/bin/local-services.sh status
```

The API is at `http://127.0.0.1:6767`; interactive API documentation is at
`http://127.0.0.1:6767/docs`. The API and isolated host run as login LaunchAgents,
with automatic process restart. They start at GUI login, including after reboot;
they do not run while logged out. If the port is occupied, startup fails and
leaves the other process alone. Logs are in `.native-lab-server/service-logs`.
Use `local-services.sh stop` or `uninstall` to stop these dedicated services;
both preserve their data. See [startup validation](../../../designs/ios-native/startup-validation.md).

For foreground debugging, stop the managed services first, then run
`bash web/ios/NativeLab/bin/local-server.sh`. **Ctrl-C** stops that foreground API.

The launcher uses this checkout's `.venv`, clears inherited deployment settings,
and keeps its database, artifacts, configuration and logs in the gitignored
`.native-lab-server/` directory. Managed startup registers an isolated host but
does not configure a provider or submit model prompts. A fresh session list is
empty. To add
four local test conversations, including a 60-message history for pagination
and a separate mutable stream-validation fixture:

```sh
.venv/bin/python web/ios/NativeLab/bin/seed-local-fixtures.py
```

This script only targets this checkout's `.native-lab-server/data/chat.db`.
The messages are explicitly stored fixtures, not generated replies. Rerunning
does not duplicate them or overwrite existing history; no model is invoked.

### Enable real replies

For an actual conversation, open **Native live chat**. **Live stream validation**
is an unbound UI test fixture: its stored text and injected events are not model
replies, and it has no execution host. An online API alone does not make those
fixtures able to answer.

Managed startup already starts the isolated host. If using foreground debugging
instead, register it in a second terminal at the repository root:

```sh
bash web/ios/NativeLab/bin/local-host.sh
```

This foreground host uses separate lifecycle/configuration state inside
`.native-lab-server/host-data` and `host-config`, leaving hosted connections
untouched. It preserves the existing `HOME` so provider CLIs can find the
local login; it does not copy credentials into the isolated state directory.
In a third terminal, create/reuse a dedicated host-backed chat:

```sh
.venv/bin/python web/ios/NativeLab/bin/prepare-live-session.py
```

The script requires a configured local Codex native harness. It creates
**Native live chat** in `.native-lab-server/chat-workspace` and may start a
runner, but does not submit a prompt. Connect from the app, open that session,
and send a message. A valid login for the harness's configured model provider
is required; a connected runner alone does not prove the provider can respond.

An opt-in terminal smoke check sends one text-only prompt and requires both
SSE text deltas and a completed generated reply:

```sh
.venv/bin/python web/ios/NativeLab/bin/smoke-live-chat.py <SESSION_ID> --send-test-prompt
```

That short connection check does not prove progressive rendering from the model.
For a longer reply that must arrive in multiple temporally separated chunks:

```sh
.venv/bin/python web/ios/NativeLab/bin/smoke-live-chat.py <SESSION_ID> \
  --send-test-prompt --require-incremental
```

The October 20 provider probe returned a single answer chunk and did not satisfy
that stronger requirement. See the October 31
[streaming validation](../../../designs/ios-native/progressive-streaming-validation.md)
for the current coordinated web/native test and its evidence. A completed real
reply alone is not proof of progressive rendering.

To test creation, a real reply, and Files-picker upload from the native UI,
keep the API and host running and choose a booted iPhone simulator UDID from
`xcrun simctl list devices booted`. From the repository root:

```sh
OMNI_TEST_DEVICE=FB1F71AC-0B76-4F2B-B251-6EE3E1955B14
python3 web/ios/NativeLab/bin/seed-picker-file.py "$OMNI_TEST_DEVICE"
TEST_RUNNER_OMNI_LIVE_MODEL_UI_TESTS=1 xcodebuild \
  -project web/ios/NativeLab/NativeLab.xcodeproj -scheme NativeLab \
  -destination "platform=iOS Simulator,id=$OMNI_TEST_DEVICE" \
  -parallel-testing-enabled NO \
  -only-testing:NativeLabUITests/NativeLabLiveUITests/testOptInLiveCreationAndNativeFileSend test
```

This opt-in test creates a uniquely named **Native E2E** session, sends two real
Codex prompts, and uploads a 20-byte test file through **Files > On My iPhone**.
It checks retained drafts, exactly-once messages/replies, the saved file reference,
downloaded bytes, and cleared attachment state. It leaves the session available
for inspection. The seed script writes only `Omni native attachment.txt` into
the selected simulator's Files storage. It does not change app file-sharing settings.

Use the ID printed by the preparation script. The check refuses other session
titles/workspaces and never retries an accepted/uncertain prompt automatically.
On this Mac, renew an expired Databricks provider login with
`databricks auth login --profile YOUR_PROFILE`. The launcher must preserve
`HOME`: a valid login still failed when the isolated host omitted it.
After correcting that launcher, the real-model native UI test passed on
2026-10-17, with an independently observed SSE text delta and saved reply.

Check it from another terminal:

```sh
curl --fail --noproxy '*' http://127.0.0.1:6767/health
curl --fail --noproxy '*' http://127.0.0.1:6767/v1/info
curl --fail --noproxy '*' 'http://127.0.0.1:6767/v1/sessions?limit=5'
```

This is single-user, no-login development mode, bound only to loopback. The
iOS simulator can use the Mac's loopback address. A physical phone's `127.0.0.1`
refers to the phone, not this Mac. Physical-device integration needs a separately
configured authenticated, protected connection; do not expose this no-login
server to the LAN.

Initial server verification on this Mac on 2026-10-16: `/health`, `/v1/info`, `/v1/me`,
`/v1/sessions?limit=5`, `/v1/agents?limit=5` and `/docs` returned HTTP 200.
Discovery reported single-user mode, identity was `local`, and no sessions or
hosts were attached. Safari on the iOS 26.0 **Omni iPhone 17 Pro** simulator
also displayed `{"status":"ok"}` from `/health`. Subsequent core and UI tests
verified NativeLab's URLSession integration, session pagination and stored
history against this API; see the current validation report below.
Physical-phone connectivity to a hosted HTTPS server remains unverified.

## Try it

1. Tap **Open sample workspace**. Browse Pinned and Recent; search a title,
   message preview or project such as `Planning`. The filter menu includes
   running, needs-response and archived sessions.
2. Open **Native mobile design**. Tap the expand icon in the composer. Write
   a multiline draft in the native editor, tap **Done**, navigate away and
   reopen it. Relaunch the app: the draft is still there.
3. Approve the sample design, then send the draft. Watch the simulated reply.
   Use **Stop** to interrupt another reply; your next draft stays editable
   while a reply is arriving.
4. Open a conversation's **…** menu to rename, pin or archive. The list also
   supports swipe actions and long-press menus. Choose the Archived filter
   to find and restore a session. Archiving does not dismiss a pending decision.
5. Open **Inbox**, answer the question in **Choose the first release**,
   and return. Only the answered session leaves Inbox.
6. Open **Project notes** to check read-only behavior. Both composers respect
   it. Long-press a message to copy/share it; ordinary transcript text is selectable.
7. Tap the new-session icon. Enter an optional name and a first message.
   Dismiss and reopen the sheet to recover the draft, then tap **Start session**
   in the toolbar. A new conversation opens with the initial prompt.
8. Try large Dynamic Type, rotation and dark appearance. The composer grows
   inline or expands into an opaque full-screen native editor. The info button
   opens scrollable status/error details; landscape keeps actions in the toolbar.

## Design and scope

The [feature comparison](../../../designs/ios-native/mobile-core-comparison.md)
maps current Omnigent capabilities to the mobile scope. The
[feature spec](../../../specs/features/mobile-native-core.md) records requirements
and acceptance checks.

The session list and expandable editor follow the requested Codex-style
interaction patterns without copying assets. Glass is used for composer chrome
on iOS 26+, with a native material fallback on iOS 18 and solid backgrounds for
Reduce Transparency. Native controls provide selection, paste, undo and system
keyboard dictation. This is not an independent speech-recognition feature.

`LocalServerSessionClient` implements REST discovery, identity, paging, message
submission, turn interruption, supported decision responses and permission-aware
session edits. Conversation SSE provides live text/status/decision events;
session-list WebSockets drive list and Inbox updates. Initial connection,
reconnect and foregrounding reconcile authoritative history and current state.
Optional pull-to-reconcile remains a recovery tool, not the normal update loop.

Read-only sessions still reject writes. Unsupported schemas and external
confirmation flows explain when another surface is needed. Live creation and
attachment uploads use the existing server APIs; notifications add opt-in APNs
registration and delivery. Hosted authentication uses verified server identity
and Keychain credentials; live hosted sign-in validation remains outstanding.
See the [server audit](../../../designs/ios-native/server-contracts.md) and
[live interaction spec](../../../specs/features/mobile-live-interaction.md),
which supersedes the earlier read-only milestone.
Interactive terminal/editor, scheduling and admin are not implemented in this preview.

## Local data

The versioned store lives in the app sandbox under
`Application Support/OmnigentNativeLab/workspace-v1.json`.
It uses atomic writes and iOS file protection. Saves are briefly coalesced while
typing/streaming and flushed when leaving an editor or backgrounding the app.
There is no durable network outbox or cloud sync.

Live connection data and drafts are in memory only, scoped per server/identity,
never written into the demo store. Live drafts survive mode switches, but not
app termination. Failed/rejected/uncertain sends retain their draft; uncertain
delivery requires explicit review before another send, because the server has
no idempotency-key contract. Accepted input is not a promise of model completion.
Relaunch returns to Welcome; reconnect explicitly through **Saved accounts** or
enter credentials again. Optional remembered tokens live in device-only Keychain;
API requests do not use browser cookies.

After relaunch, an interrupted sample reply keeps its partial text, ends its
spinner and explains the interruption. Unknown/corrupt files are not overwritten:
the app shows a warning and opens a temporary sample workspace. Storage write
errors are surfaced in Settings and the workspace.

UI tests use a separate `ui-tests-v1.json`; reset arguments never erase normal
preview data. Removing the app removes its sandbox data.
Event-gallery UI tests additionally use `--ui-test-event-gallery` with
`--ui-testing`, storing only their fixtures in `event-gallery-v1.json`.
Explicit file previews are temporary protected files in the app's cache area;
they are not a durable download library.

## Checks

Core checks run without a simulator:

```sh
swift test --package-path web/ios/NativeLab
```

Run core tests plus all native UI journeys:

```sh
xcrun simctl list devices available
bash web/ios/NativeLab/bin/check.sh <SIMULATOR_UUID>
```

The script prints the temporary directory containing build output and
`NativeLab.xcresult`. **Cmd-U** in Xcode runs the UI journeys only.
Screenshot attachments are retained for the session list, conversation, expanded
composer, search and large-text/landscape layouts.

The core suite includes hosted auth, transport, permission, send-acknowledgement
and stream reducer checks. An opt-in test verifies the default transport against the real
local API. With the
server running and fixtures seeded, enable it with:

```sh
OMNI_LOCAL_API_TESTS=1 swift test --package-path web/ios/NativeLab
```

Add `OMNI_KEYCHAIN_TESTS=1` to exercise real isolated Keychain CRUD as well; those
temporary test entries are deleted afterward. The integrated October 31 run
passed all 288 core tests with both options enabled and no skips.

The `NativeServerConnectionUITests` suite checks secure credential fields,
clearing credentials when changing servers, and rejection of nonlocal HTTP.
It does not use or save a real credential. Hosted deployment login remains a
separate live check after authenticating to that deployment.

The same environment variable can prefix `bin/check.sh` for a complete run.
Live UI journeys require the local server and fixtures above; they skip
explicitly if unavailable. Check result counts before claiming live coverage.
The unavailable-server journey, eight existing demo journeys and five picker
journeys run without a backend.
To run the live/connection journeys after seeding:

```sh
xcodebuild -project web/ios/NativeLab/NativeLab.xcodeproj -scheme NativeLab \
  -destination 'platform=iOS Simulator,name=Omni iPhone 17 Pro' \
  -only-testing:NativeLabUITests/NativeLabLiveUITests \
  -parallel-testing-enabled NO -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO test
```

Seven deterministic live journeys cover pagination, live deltas/final-item
deduplication, Inbox resolution, background recovery, draft isolation, an
unavailable server and sending availability in a deliberately unbound fixture. The
last case checks that a missing execution connection blocks Send and preserves the
draft instead of submitting a message that cannot execute. It does not establish a
generated response. Run suites serially against these shared fixtures.

After preparing **Native live chat** and renewing the provider login, explicitly
enable the separate genuine-model journey. It sends one unique text-only prompt
through the native editor and checks the completed reply and stored items:

```sh
TEST_RUNNER_OMNI_LIVE_MODEL_UI_TESTS=1 xcodebuild \
  -project web/ios/NativeLab/NativeLab.xcodeproj -scheme NativeLab \
  -destination 'platform=iOS Simulator,name=Omni iPhone 17 Pro' \
  -only-testing:NativeLabUITests/NativeLabLiveUITests/testOptInRealModelReplyArrivesWithoutRefresh \
  -parallel-testing-enabled NO -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO test
```

This may incur model usage. The test must report a pass, not a skip, to count as
provider verification; alternatively set `OMNI_LIVE_MODEL_UI_TESTS=1` in the
scheme's Test environment in Xcode. It never injects assistant output.
An online host is required; sending may wake its stopped runner. A timeout is
not permission to resend: inspect the dedicated session's status/history first.

### Isolated picker integration tests

With the local API and host running, prepare a separate inert conversation:

```sh
.venv/bin/python web/ios/NativeLab/bin/prepare-configuration-fixture.py
```

It creates/reuses **Native configuration validation**, stores a marked fixture
item, and starts a runner without sending a model prompt. Picker writes are
opt-in and guarded by that title, workspace and marker; the normal **Native live
chat** is inspected but never changed by these tests. Run serially:

```sh
picker_run_dir="$(mktemp -d /tmp/omnigent-picker.XXXXXX)"
TEST_RUNNER_OMNI_CONFIG_MUTATION_UI_TESTS=1 xcodebuild \
  -project web/ios/NativeLab/NativeLab.xcodeproj -scheme NativeLab \
  -destination 'platform=iOS Simulator,name=Omni iPhone 17 Pro' \
  -derivedDataPath "$picker_run_dir/DerivedData" \
  -resultBundlePath "$picker_run_dir/Picker.xcresult" \
  -only-testing:NativeLabUITests/NativeLabLiveUITests/testLiveConfigurationIdentityCatalogAndDetailsWithoutMutation \
  -only-testing:NativeLabUITests/NativeLabLiveUITests/testOptInConfigurationMutationPreservesConversationAndRestoresHarness \
  -only-testing:NativeLabUITests/NativeLabLiveUITests/testOptInExternalConfigurationChangeRequiresReview \
  -parallel-testing-enabled NO -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO test
```

Successful mutation tests restore Codex/default overrides. A failed test does
not blindly restore/retry: inspect the fixture before rerunning. These verify
saved configuration, retained history/drafts and conflict handling, not provider
execution after a harness switch. Use a fresh build directory as above and
inspect the result bundle's pass/fail/skip counts. See the
[picker validation](../../../designs/ios-native/configuration-validation.md).

Verified on the iPhone 17 Pro simulator on 2026-10-17: **1 passed, 0 skipped**,
one native input and one generated reply persisted exactly once. Results:
`/private/tmp/omni-real-model-home-fixed-results.xcresult`. This does not verify
physical-device networking.

## Verification

The latest combined status for hosted accounts, persistent services, and real
streaming is [October 31 integration](../../../designs/ios-native/integration-2026-10-31.md).

Current validation is recorded in
[mobile-core-validation.md](../../../designs/ios-native/mobile-core-validation.md).
The [earlier regular-phone pass](../../../designs/ios-native/regular-phone-validation.md)
records the expanded-editor defects that motivated the current repair.
Current live integration and editor results are recorded in
[local-server-validation.md](../../../designs/ios-native/local-server-validation.md).
That report describes the historical read-only milestone; current streaming
and interaction verification is in
[live-interaction-validation.md](../../../designs/ios-native/live-interaction-validation.md).
Physical-device keyboard/dictation, VoiceOver and iOS 18 material fallback still
require hands-on validation before a release.
