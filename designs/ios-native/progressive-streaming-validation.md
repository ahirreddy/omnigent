# Progressive reply streaming: October 31, 2026

## Current result

**A real reply succeeded, but progressive streaming failed the strict check.**
After restoring the API/host, the coordinator sent one prompt in disposable
session `c8f822f49a854768bd8c60fd7b294332`. Its generated 8,816-character reply
arrived in one SSE text chunk, about 119.195 seconds after submission. The first
partial was already the entire final answer; the growth window was zero.
See [retained timing evidence](evidence/streaming-oct31.json). This establishes
current single-chunk delivery at the API SSE boundary. It does not distinguish
provider buffering from harness/server aggregation, or prove native visible growth.
The API did not report `llm_model`, so no exact generated model identity is claimed.

The coordinated native/web attempt failed before sending: the Pro simulator's
test runner could not launch (`Mach error -308`, server died), and its observer
timed out. Separately, the streaming worker lost provider access to a Databricks
IP ACL rejection. That worker failure is not presented as the outcome of the
coordinator's subsequently successful model turn. No global provider settings
or network access controls were changed.

## Strict real-turn proof

`web/ios/NativeLab/bin/smoke-live-chat.py` now supports a fresh disposable session,
a catalog-checked per-session model override, and timestamped evidence saved on
failure as well as success. `--observe-only --web-url` opens the **normal web
frontend** at `/c/<session-id>` and watches the same session SSE path as native.
Only the native composer sends the prompt in this mode; there is no second
provider request, event injection, response mocking, or artificial text pacing.

The new `UITests/NativeProgressiveStreamingUITests.swift` test independently
subscribes to the session SSE before sending through the native composer. It
requires all of the following:

- One marked real reply reconstructed by at least two nonempty, distinct chunks
  spanning at least 250 ms before its matching assistant item completes.
- Two visible native text states, with screenshots captured before that matching
  completion, increasing by a strict prefix over at least 250 ms. The first
  partial cannot already contain the final answer.
- The committed text appears without refresh and the stored prompt and final
  assistant reply each occur once. An explicit model override must match the
  runner's reported actual model after generation.

Wrapper `response.completed` events are recorded but cannot terminate the native
message observer. Replay indices, unrelated message IDs, post-completion text,
one full-response chunk, and rapid buffered bursts cannot manufacture a pass.
A valid SSE result alone does not establish visible UI growth. Web and native
screenshot checks are separate, using the same reply and completion boundary.

## Running the coordinated comparison

From the repository root, first restore the isolated API/host using the services
agent's startup workflow. Start the normal frontend against that same API:

```sh
cd web
npm ci --legacy-peer-deps --ignore-scripts --no-audit --no-fund
OMNIGENT_URL=http://127.0.0.1:6767 npm run dev -- --host 127.0.0.1 --port 5173 --strictPort
```

In another terminal, install Chromium if needed and start the observer. Use a
new evidence directory and probe ID for every attempt. Omit `--model` to use the
configured default, or supply an exact model from the disposable runner's `model_options` catalog.
Codex publishes this on its session snapshot; host-level model previews currently
support only Claude. With `--model`, the tool first creates a default session,
waits for its catalog, validates the choice, then PATCHes only that new session.
If the catalog is unavailable, it fails without a prompt or override. The tool
never changes host/provider defaults.

```sh
.venv/bin/python -m playwright install chromium
.venv/bin/python web/ios/NativeLab/bin/smoke-live-chat.py \
  --create-session --observe-only --require-incremental \
  --probe-id oct31a --evidence-dir /private/tmp/omni-streaming-oct31a \
  --web-url http://127.0.0.1:5173 --timeout 600
```

Wait for `READY`, then read `ready.json` for the new `session_id`. Run only the
new UI test on an available simulator; the parent agent owns adding its source
file to `NativeLab.xcodeproj`. The `TEST_RUNNER_` environment prefix forwards
these values into the XCTest runner:

```sh
TEST_RUNNER_OMNI_PROGRESSIVE_UI_TESTS=1 \
TEST_RUNNER_OMNI_PROGRESSIVE_SESSION_ID=<SESSION_ID> \
TEST_RUNNER_OMNI_PROGRESSIVE_PROBE_ID=oct31a \
TEST_RUNNER_OMNI_PROGRESSIVE_EVIDENCE_DIR=/private/tmp/omni-streaming-oct31a \
xcodebuild -project web/ios/NativeLab/NativeLab.xcodeproj -scheme NativeLab \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UUID>' \
  -derivedDataPath /private/tmp/omni-streaming-oct31/DerivedData \
  -resultBundlePath /private/tmp/omni-streaming-oct31a/NativeStreaming.xcresult \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:NativeLabUITests/NativeProgressiveStreamingUITests \
  CODE_SIGNING_ALLOWED=NO test
```

`plan.json` describes the exact prompt/session/model; `wire.json` contains
allowlisted events with epoch and monotonic receipt times. `web-samples.json`
and `web-*.png` record observed web text and screenshot intervals.
`native-result.json`, `native-*.png`, and the retained XCTest attachments contain
native text, screenshot intervals, and its independent wire timeline. `result.json`
records the Python probe verdict and actual runner identity. Read **both**
verdicts and inspect screenshots before claiming web/native progressive success.
The observers never save auth headers or arbitrary provider error payloads.

For an SSE-only diagnostic (not UI proof):

```sh
.venv/bin/python web/ios/NativeLab/bin/smoke-live-chat.py \
  --create-session --send-test-prompt --require-incremental \
  --evidence-dir /private/tmp/omni-streaming-wire-oct31a
```

## October 31 checks so far

- 17 offline Python regression tests pass. These use synthetic inputs solely to
  verify fail-closed validation and session/model guards, not as live evidence.
- Ruff checks pass for the two owned Python files.
- The new Swift file passes strict formatting and standalone simulator SDK
  type-checking with the real compiler and XCTest Swift module search path.
- Simulator listing through installed CoreSimulator **1174.21** succeeds. The
  assigned Omni iPhone 17 Pro `FB1F71AC-0B76-4F2B-B251-6EE3E1955B14` is booted;
  the parent owns the SE simulator for auth tests.
- API and host are online. Initial disposable session `ff0dbd8dde074b43858b79cf92ed8841`
  uses `codex-native`; the native/web attempt sent no model prompt.
  Its runner published 12 supported model choices. Its private configuration
  reports the configured model; the API's `llm_model` is still null before the
  first turn. No override or global provider change was made.
- The normal Vite frontend is serving at `http://127.0.0.1:5173`. Plain `npm ci`
  rejected peer dependencies in the existing lockfile; `npm ci --legacy-peer-deps
  --ignore-scripts --no-audit --no-fund` succeeded without changing manifests.
- The normal web UI, API SSE observer, and read-only Codex notification observer
  were connected to that **same** disposable session. Preparation artifacts are
  in `/private/tmp/omni-streaming-oct31-prepare/`; the failed comparison evidence
  is in `/private/tmp/omni-streaming-oct31pro1/`. Its `ready.json` establishes only
  observer readiness. `NativeStreaming.xcresult` records the runner launch failure.
- The parent registered `UITests/NativeProgressiveStreamingUITests.swift` in
  the UI test target. The test built successfully; its native visible-growth
  assertions have not executed successfully. The final SSE-only probe's full
  evidence is in `/private/tmp/omni-streaming-oct31wire2/`, with its timestamped
  metrics retained above. The strict validator exited with failure, as required
  for a complete response delivered as a single chunk.

Re-run the offline validator suite:

```sh
.venv/bin/python -m unittest discover -s web/ios/NativeLab/bin \
  -p test_smoke_live_chat.py -v
```

---

# Progressive reply streaming: October 20, 2026

The native client incorrectly gated harness text on the enqueue response's
lifecycle. A wrapper `response.completed` or idle status could arrive before
the harness's message deltas and make the app discard those deltas. The final
persisted item was still accepted, making the reply appear all at once.

The web UI already handles message-ID-based native text independently of that
wrapper lifecycle (`tapLiveDeltas` in `web/src/store/chatStore.ts`). The native
reducer now does the same, while retaining index deduplication, finalized-message
retirement and interruption handling. Native previews also no longer inherit an
unrelated wrapper response ID, which could prevent their replacement by the
committed message.

Two regression tests failed before the fix: text after wrapper completion was
missing, and a wrapper completion during a native reply stopped growth and left
a duplicate preview. Both pass after the fix. Coverage also checks consecutive
turns, interruption and ordinary response-scoped late-delta rejection.

The transport also used to buffer all SSE events during initial history loading
and later reconciliation. It now publishes each event immediately, records a
checkpoint for history reconciliation, and replays buffered events against that
checkpoint without applying text or side effects twice. Initial loading stays
non-sendable until connection validation completes.

Reconciliation preserves a longer live prefix if a slower history read returns
an older, shorter version. A final item still replaces the preview. A reply
received before initial history finishes stays after that earlier history.

## Measured boundary

The local API was `http://127.0.0.1:6767`; the harness was `codex-native`, model
the configured model. All prompts used a disposable local test session or a
direct diagnostic request, asked for ordinary prose, and prohibited tool/file access.

| Probe | First text | Text chunks | Characters |
| --- | --- | --- | --- |
| New session, 60 lines | 46.676 s | 1 | 5,908 |
| Existing session, raw Codex notification | 72.823 s | 1 | 6,220 |
| Same existing-session response, local SSE | 72.836 s | 1 | 6,220 |
| Direct configured `/ai-gateway/codex/v1/responses`, `stream: true` | 28.243 s | 1 | 3,438 |
| Direct standard `/ai-gateway/openai/v1/responses`, `stream: true` | 27.067 s | 1 | 3,543 |

Both direct requests returned HTTP 200 with `text/event-stream`, but each
emitted only one `response.output_text.delta` with the full answer. Both used
the same model, existing login, and low reasoning effort. No credentials were
printed or saved, and no provider routing/configuration was changed.

In the second local turn, Codex emitted the full text at 72.823 s; Omnigent
forwarded it at 72.836 s and committed it at 72.849 s. For that probe, incremental
output was already absent before the local forwarder or iOS client received the
answer. These samples do not establish the behavior of every session or explain
the user's web-versus-native discrepancy. The initial provider-only diagnosis
missed the native lifecycle bug above.

Raw timing evidence remains locally in `/private/tmp/omni-incremental-trace.json`,
`/private/tmp/omni-stream-raw-vs-sse.json`, `/private/tmp/omni-gateway-direct-stream.json`
and `/private/tmp/omni-gateway-standard-stream.json`.

## Validation

The fix is in the native client; no gateway or model configuration change is
required. Provider output timing and client rendering remain separate checks.

The connection smoke test keeps its short default prompt. Use the explicit
`--require-incremental` option for a longer reply and a progressive-streaming
assertion; one full-response delta must fail that check:

```sh
.venv/bin/python web/ios/NativeLab/bin/smoke-live-chat.py <SESSION_ID> \
  --send-test-prompt --require-incremental
```

Use the dedicated **Native live chat** session prepared by
`web/ios/NativeLab/bin/prepare-live-session.py` and an online runner. The native
fixture UI test `testServerDeltasAppearWithoutRefreshAndCommitOnlyOnce` separately
ends an enqueue turn before supplying text, then checks that a partial prefix
appears before the suffix and committed item.
That synthetic test proves incremental UI rendering, not provider streaming.

The stricter validator was checked against the recorded 6,220-character live
reply and correctly rejected it: one chunk, zero growth window, and the first
partial equal to the final answer. Its five offline regression tests pass:

```sh
.venv/bin/python -m unittest discover -s web/ios/NativeLab/bin \
  -p test_smoke_live_chat.py -v
```

The focused native UI check was rerun on the iPhone 17 Pro simulator: **1 passed,
0 failures, 0 skipped**, with no runtime warnings in the result bundle at
`/private/tmp/omni-stream-lifecycle-fix-oct20.xcresult`. It observed the prefix
after the enqueue turn ended, then the longer text, then exactly one committed
message. Screenshots for all three stages are exported in
`/private/tmp/omni-stream-lifecycle-fix-shots/`.

Final combined validation passed:

- **248 core tests**, zero failures or skips, with `OMNI_LOCAL_API_TESTS=1`.
  This includes six delayed-history tests and real local SSE/WebSocket checks.
- **iPhone 17 Pro:** streaming and background recovery, two passed, zero skipped;
  `/private/tmp/omni-stream-recovery-fix-oct20.xcresult`.
- **iPhone SE (3rd generation):** streaming, one passed, zero skipped;
  `/private/tmp/omni-stream-fix-se-oct20.xcresult`.
- No runtime warnings in either UI result bundle. Strict Swift formatting passed.

Run the core suite from the repository root while the isolated API is running:

```sh
OMNI_LOCAL_API_TESTS=1 swift test --package-path web/ios/NativeLab --disable-sandbox
```

For a manual reproduction, connect Omnigent Lab to the local API and ask a
Codex session: **Write 600 words about a walk through a park. Do not use tools.**
As text deltas arrive, the same reply should grow before it completes, without
refreshing or reopening the conversation. A session that sends only one full-text
delta will still display that single chunk; the strict smoke test distinguishes
that case from incremental delivery.
