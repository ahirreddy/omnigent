# Native live interaction validation

Date: 2026-10-17. Checkout: `feature/mobile-native-core`.

This supersedes the read-only scope of `local-server-validation.md`. The
production WKWebView app and original Downloads prototype are unchanged.

## Implemented behavior

- Native live composer, message submission, turn interruption, and explicit
  supported approval/question responses with server permission checks.
- Conversation SSE for incremental replies, committed items, decisions and
  status. WebSocket notifications update Sessions and the complete Inbox
  inventory. No timer-based polling or primary Refresh action.
- Stream-before-hydration reconciliation, automatic bounded reconnect, and
  foreground recovery. Repeated committed items do not consume a newer preview.
- Persistent Sessions, Inbox and Settings tabs in demo and live workspaces.
- Per-server/account in-memory drafts. Rejected or uncertain submissions keep
  their draft; uncertain delivery requires review before resending. A server
  acknowledgement is distinguished from an agent receiving or completing work.
- Existing provider failures remain visible after reopening a conversation.

## Current verification

The core suite passed 80 tests with the real-local-API checks enabled and no
skips. It covers REST paging, actual SSE/WebSocket readiness, byte framing,
duplicate stream items, mutation wire shapes, permissions, uncertain sends,
decision origin routing, and transient versus permanent hydration failures.
Regressions also cover preserving partial text during same-stream hydration
and delivery state across same-server reconnects while a send is pending.
The inventory regression puts the only pending request after 50 visible idle
sessions, follows its page cursor, reads the decision, watches all 51 IDs and
applies a resolution update. This is deterministic core coverage of unloaded
Inbox entries; the UI approval fixture is not guaranteed to be off-page.
Persisted error items are also covered, including reopening a failed session
whose optional `last_task_error` metadata is null.

```sh
cd web/ios/NativeLab
OMNI_LOCAL_API_TESTS=1 swift test --scratch-path /private/tmp/omni-live-stream-core-build
```

The initial 17 Pro UI run had four passes, one failure and one intentional
provider-test skip. Its stream-readiness failure reproduced a real defect:
`URLSession.AsyncBytes.lines` dropped empty SSE delimiters on this runtime.
The reader now frames bytes explicitly, preserving LF, CRLF, CR and UTF-8;
the real transport regression passed after that repair. The failed result is
retained at `/private/tmp/omni-live-17-results.xcresult`.

The repaired 17 Pro live run passed all five enabled journeys, with the genuine
provider test explicitly skipped. Results are in
`/private/tmp/omni-live-17-fixed-results.xcresult`; exported screenshots in
`/private/tmp/omni-live-17-attachments` were visually checked for the streamed
final message, connected composer and persistent Inbox navigation.

The full SE run executed all 16 UI journeys: 14 passed, the genuine-provider
test skipped, and the new unbound-send test failed because it incorrectly
required non-null `last_task_error`. The server had correctly persisted one
input and one `runner_failed_to_start` item. The test now checks the persisted
error and permits absent optional metadata; the client renders that error item
as readable transcript content. The corrected SE send journey passed in
`/private/tmp/omni-live-se-send-fixed.xcresult`. Its screenshot was visually
checked at `/private/tmp/omni-live-se-send-attachments`.

The SE full run completed test execution but hung during Xcode diagnostic
collection. Only that finished test process was terminated; its partial bundle
and runner stdout remain under `/private/tmp/omni-live-se-results.xcresult`.
The per-test results above come from its `StandardOutputAndStandardError.txt`,
not a successfully finalized bundle. The other 14 journeys were not rerun
after the small persisted-error rendering correction. Future CLI runs use
`-collect-test-diagnostics never`, as `bin/check.sh` already does.

A cached 17 Pro `test-without-building` invocation ran only one of three
requested tests. That is not counted as three passes. A fresh-build rerun
executed all three, passed background recovery and streaming, and reproduced
the same optional-metadata assertion. The final corrected 17 Pro run passed
all three tests with no skips or failures, recorded in
`/private/tmp/omni-live-17-verified-results.xcresult`. Final screenshots are in
`/private/tmp/omni-live-17-final-attachments`.

The unsigned iOS-device build also passed; this is a compile check, not a
physical-device install. Xcode reported the existing iPad orientation warning.

Strict Swift formatting, Ruff checks/formatting, shell syntax and whitespace
checks passed. No production-server changes were needed.

### Acceptance coverage

| Criteria | Evidence and status |
| --- | --- |
| AC1 | Native POST records exactly one input; deterministic SSE delta/final UI passes. Follow-up genuine-model UI test also passes with one observed text delta and one persisted assistant reply. |
| AC2 | Reducer replay/hydration regressions and native final-item deduplication pass. |
| AC3 | Transient hydration retry and background/foreground stream-resumption tests pass. |
| AC4 | Later-page inventory/watch-set regression and live Inbox appearance/resolution pass. |
| AC5 | Sessions, Inbox and Settings assertions pass in demo and live modes. |
| AC6 | Permission, rejection, uncertain-POST and scoped submission-ledger regressions pass. |
| AC7 | Originating-session decision wire tests and explicit harmless fixture approval pass. |
| AC8 | Eight demo journeys plus live/demo draft isolation and foreground draft retention pass on SE. |
| AC9 | Reproduction commands and exact pass/failure/skip boundaries are recorded here and in the README. |

## Provider-backed execution boundary

The isolated server is `http://127.0.0.1:6767`, with separate database/config in
`.native-lab-server/`. A dedicated local host runs with separate lifecycle
state. The **Native live chat** session uses
`.native-lab-server/chat-workspace`; no hosted session was used for tests.

The initial explicit text-only prompt was accepted and persisted, but the native runner
returned `codex_reauth_required`: the configured provider refresh token had
expired. At that milestone no generated assistant reply was verified. The prompt was not
automatically retried. On this machine, renew the provider login with:

```sh
databricks auth login --profile YOUR_PROFILE
```

### Follow-up after login renewal

The renewed login passed `databricks auth describe`, but the first native UI
attempt still failed with `codex_reauth_required` (one failed test, no skips;
`/private/tmp/omni-real-model-ui-results.xcresult`). The isolated host launcher
had removed `HOME`. A token-presence-only check reproduced the actual cause:
`cannot find homedir: $HOME is not set`. Preserving the unchanged home path
made both the Databricks CLI and the provider helper succeed without printing
or copying credentials. Only the dedicated local host was restarted.

After that fix, a new uniquely marked prompt sent through the expanded native
composer passed the real-model UI test: **1 passed, 0 failures, 0 skips** on
the iPhone 17 Pro simulator. The test permits an online host with a stopped
runner; this run also exercised waking the runner through native sending.
The accepted failed prompts were not automatically replayed.

- Result: `/private/tmp/omni-real-model-home-fixed-results.xcresult`.
- Independent read-only SSE observer: one text delta (40 characters), followed
  by one completed assistant item; no injected output.
- History: exactly one matching user input and one exact generated reply.
- Final state: `idle`, runner online, `last_task_error` null.
- Screenshot visually checked:
  `/private/tmp/omni-real-model-home-fixed-attachments/47CA8917-E973-40B2-93DC-A148B359F7E6.png`.

The screenshot shows the generated reply, connected composer, and persistent
Sessions, Inbox and Settings tabs. Earlier failed inputs remain in history;
resource events currently use a generic unsupported-preview row. This short
reply proves one real incremental event, not sustained long-response streaming.
The 80-test core suite and SE journeys above were not rerun for this launcher
and test-preflight correction; shell syntax and strict Swift formatting passed.

Use the opt-in model test or open **Native live chat** in the app and send a new
message. Synthetic fixture output remains transport coverage, not model output.

## Reproduce and try

From the repository root, in separate terminals as needed:

```sh
bash web/ios/NativeLab/bin/local-server.sh
bash web/ios/NativeLab/bin/local-host.sh
.venv/bin/python web/ios/NativeLab/bin/seed-local-fixtures.py
.venv/bin/python web/ios/NativeLab/bin/prepare-live-session.py
open web/ios/NativeLab/NativeLab.xcodeproj
```

Select NativeLab and a regular iPhone simulator, then Cmd-R. In Omnigent Lab,
connect to the local server, open a session and expand the composer to type.
Inbox is always beside Sessions and Settings. Cmd-U runs the UI journeys;
the genuine-provider test is opt-in and skipped by default.

## Remaining scope

Live session creation still needs a host/agent/workspace selection UI. Complex
multi-field or external-confirmation requests explain when the web app is
needed. Live drafts are not durable across termination. Inventories above the
server's 500-session watch limit show an explicit error, not silent partial
coverage. Background push, attachments, hosted authentication, and authenticated
physical-phone networking are not implemented. Do not expose the no-login
loopback server to the LAN. Physical-device, VoiceOver and iOS 18 fallback
validation remain outstanding.
