# Creation, background notifications and attachments

Initial validation October 19, 2026 against `web/ios/NativeLab` and the local server source.

## Delivered behavior

- Live creation chooses an existing ready host, harness, agent, absolute workspace
  and advertised model. One acknowledged create opens its session; the first
  prompt stays in its composer for explicit Send after the stream connects.
  An unknown creation outcome blocks another attempt until review.
- Both composers open the native Photos/Files attachment sheet. Bounded reads,
  progress, cancellation and exact server references support attachment-only
  messages. Drafts and late completions are scoped to the original session/server;
  uncertain uploads are not retried and accepted sends clear only their captured batch.
- Notification permission, session selection, APNs registration, server outbox,
  retries and scoped tap routing are implemented. The default build/provider are
  disabled. Local development has an explicit loopback gate. Production transport
  requires authenticated HTTPS; multiple API workers are unsupported by this outbox.

## Checks

| Check | Result |
| --- | --- |
| Swift core suite | 237 executed, 235 passed, 2 opt-in local API tests skipped |
| Notification server and session-stream suite | 30 passed |
| iPhone 17 Pro: creation/upload journeys | 7 passed |
| iPhone SE 3: same journeys plus large-text landscape composer | 8 passed |
| Final 17 Pro checks: creation selections, explicit notification setup, existing sample creation/send | 3 passed |
| iOS Simulator build | Passed |
| Unsigned generic iOS build | Passed |
| Opt-in push build | Passed; Info.plist enables push and selects sandbox APNs |
| Python lint, shell syntax and diff whitespace | Passed |

Core tests use protocol fixtures; upload UI tests use an isolated in-memory
uploader. Server tests use temporary storage, a synthetic signing key and a mock
APNs endpoint. No provider prompts, real Apple pushes, user file uploads or
server session creation were performed by these initial checks. The October 20
live acceptance run below covers creation and a real Files-picker upload.

The UI runs report SwiftUI `Invalid frame dimension` warnings while the forms
are presented; the inspected screenshots show readable, usable layouts. The
device build also retains the existing all-orientations warning. These warnings
are not treated as proof of a clean runtime diagnostics pass.

Screenshots: [creation](screenshots/create-notify-upload/creation.png) and
[notification setup](screenshots/create-notify-upload/notification-settings.png).

## Repeat

From the repository root:

```sh
OMNI_LOCAL_API_TESTS=0 swift test --package-path web/ios/NativeLab --disable-sandbox
.venv/bin/python -m pytest tests/server/test_mobile_notifications.py tests/runtime/test_session_stream.py -q
xcodebuild -project web/ios/NativeLab/NativeLab.xcodeproj -scheme NativeLab \
  -destination 'platform=iOS Simulator,name=Omni iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:NativeLabUITests/NativeCreationUITests \
  -only-testing:NativeLabUITests/NativeUploadUITests test
```

Use the normal repository development dependencies for pytest. This machine's
minimal environment additionally needed the visual-snapshot plugin because the
shared autouse fixtures import it, even for server tests.

## Manual acceptance and remaining activation

Run NativeLab, connect to the loopback development server, and tap **+**. Choose a
ready host and workspace, start a session, then send its saved first message.
Tap **paperclip > Photos/Files**, select a small harmless file, wait for confirmation,
close the sheet and Send. Inspect the same session in the web app for its content.

For notifications, follow [push setup](../../web/ios/NativeLab/PUSH_SETUP.md), select
owned sessions in Settings, background the app and test a real approval/completion.
Actual APNs delivery and notification taps on physical phones are not verified.
The current loopback connection also requires separate authenticated networking
work before a regular phone can reach the Mac. Live drafts remain memory-only.

The final simulator build was installed on both test devices without removing app data. The development API was started at `http://127.0.0.1:6767`; discovery reports single-user mode, accounts disabled, and identity `local`. APNs remains disabled.

## Live acceptance: October 20, 2026

**Streaming correction:** these short live replies proved SSE delivery, not
progressive generation. Follow-up investigation found and fixed a native client
bug that discarded harness deltas after early enqueue-response completion. Some
isolated provider probes also returned a single chunk; they did not establish the
cause of the web-versus-native discrepancy. See the
[streaming validation](progressive-streaming-validation.md).

The API and isolated Mac host were restarted with the fixes below and remain
available at `http://127.0.0.1:6767`. Both phone simulators used iOS 26.0 and the
real configured Codex native harness.

| Check | Result |
| --- | --- |
| iPhone 17 Pro: native creation, real replies, Files picker, upload and Send | Passed |
| iPhone SE 3: same complete live journey on the smaller screen | Passed |
| Background recovery with an unsent draft and resumed streaming | Passed on 17 Pro |
| Stream deltas reconcile into one committed message without refresh | Passed on 17 Pro |
| Codex executor and native attachment regression tests | 31 passed |
| Pending-input, session resource, endpoint and attribution regressions | Passed |

Each creation test used the native form to select the host and Codex, verified
one created session and an unsent first-message draft, then tapped Send. Each
prompt and generated reply was stored once. Files were selected through the
system **Files > On My iPhone** picker, uploaded by the app, and sent from its
expanded composer. Codex returned the file's contents, `OMNI_FILE_PICKER_OK`.
The test checked the original typed prompt, persisted `input_file` reference,
downloaded bytes (including the newline), and cleared attachment state. No
assistant replies were injected for these two journeys. The background and
deduplication checks use explicitly synthetic events in the unbound stream fixture.

The first live run exposed two server integration defects, both fixed:

- Text attachments reached Codex as unlabeled plain text. The adapter now names
  and delimits the attachment so requests to read the attached file work.
- Transcript forwarding mixed expanded file contents into the saved user prompt.
  Pending inputs now copy submitted blocks, and attachment echoes restore those
  original blocks while retaining sender attribution and existing Kiro matching.

The initial Pro run failed when Codex said it could not see an attachment; the
redundant pre-fix SE run was stopped. The final runs passed all four UI checks
with zero skipped tests. Existing SwiftUI frame-dimension warnings remain.
Photos, large/binary uploads, real Apple push delivery, and physical-phone
connectivity were not covered by this live run. The client still accepts only
loopback connections, so a physical phone cannot reach the Mac this way.

Inspectable successful sessions:

| Device | Session title | Session ID |
| --- | --- | --- |
| iPhone 17 Pro | Native E2E 77F723C8 | `89207798a94346109e29ab1127ca511d` |
| iPhone SE 3 | Native E2E 46E41ECA | `2a3e88f4d83943518fa999bd7df87828` |

Screenshots: [Pro reply](screenshots/live-e2e/pro-file-reply.png),
[SE reply](screenshots/live-e2e/se-file-reply.png),
[SE upload](screenshots/live-e2e/se-file-uploaded.png), and
[background recovery](screenshots/live-e2e/pro-background-recovery.png).
Local XCTest bundles: `/private/tmp/omni-live-e2e-oct20-b.xcresult` (3 passed)
and `/private/tmp/omni-live-e2e-oct20-se-b.xcresult` (1 passed).

To try it, run **Omnigent Lab**, connect to `http://127.0.0.1:6767`, and open
either successful session above. Send a message, then use **paperclip > Files**
to select **Omni native attachment.txt**, close the sheet and ask for its contents.
The seed file remains on both simulators. Automated rerun instructions are in
the [NativeLab README](../../web/ios/NativeLab/README.md#enable-real-replies).

## Execution availability after local-server restart

`Live stream validation` is an unbound fixture, so it cannot execute messages.
The native app now explains missing execution connectivity and disables Send
while preserving an editable draft and history. It keeps ordinary permissions
separate from availability, retains readiness across sparse updates, and allows
stopped runners to restart on an online host or a resumable managed host.
Legacy liveness can report an unbound session as online for in-process execution;
native harnesses additionally require an actual runner binding or a usable host.
The client retains only whether a runner is assigned, rather than its identifier.

The opt-in `testOptInRealModelReplyArrivesWithoutRefresh` passed on iPhone 17 Pro
after the local API and host restart. Sending from the native composer restarted
the runner for **Native live chat** (`b1e073a42e3d4600b9e208e36e22c1d4`), produced
a genuine model reply, and stored exactly one user item and one assistant item.
No assistant reply was injected. Evidence:
`/private/tmp/omni-runner-recovery-real-oct20.xcresult` and
`/private/tmp/omni-runner-recovery-real-shots/`.

Final checks: **258 core tests passed**, including the two opt-in local API
checks. `testUnboundNativeSessionKeepsDraftAndDisablesSend` passed on both
iPhone 17 Pro and SE, with no skips or runtime warnings. Bundles:
`/private/tmp/omni-execution-readiness-fixture-oct20.xcresult` and
`/private/tmp/omni-execution-readiness-se-oct20.xcresult`. The updated build is
installed and running on both simulators. Native live chat was confirmed idle
with its host and runner online after verification.

To chat manually, connect to `http://127.0.0.1:6767` and open **Native live chat**,
or use **Sessions > New session** and select the online Mac host.
