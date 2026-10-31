# Native event coverage

Inventory date: 2026-10-19. Scope: `specs/features/native-event-parity.md`.
This is the source contract and independent parity audit for NativeLab, not a
claim of full parity or successful provider execution. Tests and implementation
evidence are recorded separately below as they become available.

Presentation follow-up: [native event hierarchy](../../specs/features/native-event-hierarchy.md).
Routine resource creation/deletion and finished client-task bookkeeping are
retained in **Session activity > Lifecycle history**, not as chat cards. Failed
activities, attachments and actual terminal output remain in the transcript.
Normal response completion stays a state transition; interruption uses a small
Stopped marker. Failures use compact expandable warnings. This supersedes the
initial screenshots that gave routine resource receipts full transcript cards.
The hierarchy follow-up passed the 202-test core run (two opt-in skips, zero
failures), two SE UI checks and two 17 Pro UI checks, including read-only actual
server history and largest-text Session activity. See its spec for result bundles
and [updated screenshots](screenshots/hierarchy-se-quiet-conversation.png).

## Reference contract

The main web app declares **52 normalized event variants** in
[`events.ts`](../../web/src/lib/events.ts:859). Its
[`sse.ts`](../../web/src/lib/sse.ts:273) recognizes **47 direct raw event names**;
`response.output_item.done` fans out into multiple normalized variants, and
`response.heartbeat` intentionally emits none. The parser also normalizes
`response.TaskStatus.<STATUS>` and consumes the `[DONE]` transport sentinel.

Persisted history has **16 explicitly recognized item types**, including seven
provider-native tools, in
[`conversationItems.ts`](../../web/src/lib/conversationItems.ts:22).
[`itemsToBlocks.ts`](../../web/src/lib/itemsToBlocks.ts:66) is the history
presentation reference; [`blockStream.ts`](../../web/src/lib/blockStream.ts:342)
is the live presentation reference. Session/cache side effects live in
[`chatStore.ts`](../../web/src/store/chatStore.ts:4088). Some declared variants
are intentionally not transcript blocks; absence from `blockStream` does not
make an event unsupported by the main app.

The native mapping below describes required behavior. “State” means a native
status/details surface or state transition; “activity” means a compact,
expandable display-only card; “transport” means no transcript row. Safe read-only
display of a terminal/browser event is not equivalent to executing that action.

## Raw SSE event matrix

All 47 direct raw names are listed once. The normalized names exactly match
`events.ts`; output-item normalization is expanded in the next section.

| Raw event | Normalized event | Native behavior | Main-app source |
| --- | --- | --- | --- |
| `response.created` | `response_created` | State: adopt response ID, start a new turn, clear obsolete failure state; preserve earlier transcript. | `sse.ts:277`, `blockStream.ts:345` |
| `response.queued` | `response_queued` | State: queued/running indication, no invented assistant message. | `sse.ts:280`, `blockStream.ts:350` |
| `response.in_progress` | `response_in_progress` | State: adopt ID even when created was missed; start live response. | `sse.ts:283`, `blockStream.ts:353` |
| `response.completed` | `response_completed` | Finalize only matching response; close text/activity previews; retain usage, including context-token distinction. | `sse.ts:289`, `blockStream.ts:794`, `chatStore.ts:4090` |
| `response.failed` | `response_failed` | Finalize matching response and expose code/message; preserve partial content. | `sse.ts:295`, `blockStream.ts:804` |
| `response.incomplete` | `response_incomplete` | Finalize partial content with reason, not success; ignore stale response terminal events. | `sse.ts:298`, `blockStream.ts:796` |
| `response.cancelled` | `response_cancelled` | Finalize partial content as cancelled, not failure or successful completion. | `sse.ts:306`, `blockStream.ts:797` |
| `response.output_text.delta` | `text_delta` | Content: stream text; respect native message ID/chunk index/final; deduplicate replay and later committed item. | `sse.ts:314`, `events.ts:81`, `blockStream.ts:448` |
| `response.function_call_output.delta` | `tool_output_delta` | Activity: append output to matching call, including before final output arrives; do not confuse same call ID across responses. | `sse.ts:326`, `chatStore.ts:3502` |
| `response.reasoning.started` | `reasoning_started` | State/activity: visible thinking/summary section; close previous text segment; never fabricate reasoning. | `sse.ts:334`, `blockStream.ts:364` |
| `response.reasoning_text.delta` | `reasoning_delta` | Handle as reasoning activity; only provider-exposed permitted text is displayable. Hidden/encrypted payloads remain excluded. | `sse.ts:337`, `blockStream.ts:394` |
| `response.reasoning_summary_text.delta` | `reasoning_summary_delta` | Activity: stream exposed summary, support an implicit start, preserve boundaries between consecutive summaries. | `sse.ts:343`, `blockStream.ts:395` |
| `response.output_item.done` | Multiple; see next matrix | Decode shared typed item, reconcile its stable item/call/response identity with live preview; known items must not become unsupported placeholders. | `sse.ts:351`, `sse.ts:968` |
| `response.output_file.done` | `output_file_done` | Activity: filename, file ID and content type; no automatic download or arbitrary URL fetch. | `sse.ts:354`, `blockStream.ts:783` |
| `response.retry` | `retry` | Activity: retry attempt/max/delay and error/source; do not retry requests in the client. | `sse.ts:364`, `blockStream.ts:757` |
| `response.error` | `error` | Activity: code/message/source/tool; visible even with empty message; reconcile with stored error where an item ID exists. | `sse.ts:377`, `blockStream.ts:769` |
| `response.compaction.in_progress` | `compaction_in_progress` | Activity/state: compacting indicator, not a user message. | `sse.ts:387`, `blockStream.ts:739` |
| `response.compaction.completed` | `compaction_completed` | Replace compacting state with completed marker; apply reported post-compaction token count. | `sse.ts:390`, `blockStream.ts:749`, `chatStore.ts:4244` |
| `response.compaction.failed` | `compaction_failed` | End compacting state without implying history changed; explain failure if supplied. | `sse.ts:397`, `chatStore.ts:4252` |
| `response.client_task.cancel` | `client_task_cancel` | State/activity: correlate task ID/optional call ID and end matching task indication. Native does not pretend to run desktop client tools. | `sse.ts:402`, `events.ts:427` |
| `response.heartbeat` | None | Transport keepalive; never transcript content or a reason to stop a response. | `sse.ts:415` |
| `session.status` | `session_status` | State: idle/launching/running/waiting/failed, matching response ID, optional background-task count and error. Missing count preserves; explicit zero clears. | `sse.ts:420`, `chatStore.ts:4276` |
| `session.usage` | `session_usage` | State: sparse merge of context tokens/window/cost; replace present per-model map. Validate nonnegative finite values; missing values are not zero. | `sse.ts:462`, `chatStore.ts:4133` |
| `session.model` | `session_model` | State: update only matching session's confirmed model; reconcile snapshot/catalog without overwriting an edit baseline. | `sse.ts:519`, `chatStore.ts:4161` |
| `session.reasoning_effort` | `session_reasoning_effort` | State: matching session's effort; explicit null means default, absent/malformed is not a clear. | `sse.ts:526`, `chatStore.ts:4176` |
| `session.collaboration_mode` | `session_collaboration_mode` | State: reported collaboration/plan mode; no automatic mode mutation. | `sse.ts:537`, `chatStore.ts:4186` |
| `session.agent_changed` | `session_agent_changed` | State: matching session's binding; refresh detailed snapshot/catalog and invalidate old resource context. | `sse.ts:548`, `chatStore.ts:4203` |
| `session.todos` | `session_todos` | State: full replacement of valid pending/in-progress/completed todos; empty list clears. | `sse.ts:562`, `chatStore.ts:4103` |
| `session.terminal_pending` | `session_terminal_pending` | State: terminal-startup indication; false clears, no terminal execution. | `sse.ts:589`, `chatStore.ts:4108` |
| `session.sandbox_status` | `session_sandbox_status` | State: provisioning/cloning/starting/connecting/ready/failed and error. Ready ends startup; failed remains explainable. | `sse.ts:601`, `chatStore.ts:4114` |
| `session.mcp_startup` | `session_mcp_startup` | State: replace valid per-server startup map; ready clears transient indicator, failures/cancellations remain readable. | `sse.ts:624`, `chatStore.ts:4123` |
| `session.input.consumed` | `session_input_consumed` | Nested `data`: commit user input by item ID, clear matching pending ID, suppress meta content, preserve authorship; never blindly discard unrelated draft. | `sse.ts:655`, `chatStore.ts:4456` |
| `session.interrupted` | `session_interrupted` | Nested `data`: stop matching response and seal partial text in order; not a global stop for a newer turn. | `sse.ts:683`, `blockStream.ts:883`, `chatStore.ts:4553` |
| `session.created` | `session_created` | State: child-session spawn associated with parent; surface child ID/status, not a replacement of the current session. | `sse.ts:694`, `chatStore.ts:4570` |
| `session.superseded` | `session_superseded` | State/action: explain replacement target and permit intentional navigation; preserve source draft and avoid cross-session writes or a fake continued response. | `sse.ts:707`, `chatStore.ts:4580` |
| `session.resource.created` | `session_resource_created` | State/activity: register resource by owning session and resource ID; show type/name/metadata; no automatic attach or execution. | `sse.ts:719`, `chatStore.ts:4605` |
| `session.resource.deleted` | `session_resource_deleted` | State/activity: remove/mark exact resource deleted; do not leave an active resource indicator. | `sse.ts:724`, `chatStore.ts:4610` |
| `session.child_session.updated` | `session_child_session_updated` | State: patch matching child's status/preview; preserve partial fields and child ID. | `sse.ts:738`, `chatStore.ts:4615` |
| `session.changed_files.invalidated` | `session_changed_files_invalidated` | State: mark workspace/environment changed; display a truthful notice; no fake diff or automatic filesystem access. | `sse.ts:752`, `chatStore.ts:4630` |
| `session.terminal.activity` | `session_terminal_activity` | State: terminal activity pulse by owning session/terminal ID, no transcript flood. | `sse.ts:761`, `chatStore.ts:4636` |
| `session.skills` | `session_skills` | State/invalidation: reload reported skills from detailed snapshot; don't claim an empty event body contains the list. | `sse.ts:772`, `chatStore.ts:4641` |
| `session.model_options` | `session_model_options` | State/invalidation: reload reported catalog; preserve current/unknown model and pending edits. | `sse.ts:782`, `chatStore.ts:4650` |
| `session.presence` | `session_presence` | State: full replacement of viewers with optional joined time/idle flag; matching session only, no chat rows. | `sse.ts:790`, `chatStore.ts:4194` |
| `browser.action_request` | `browser_action_request` | Explicit desktop-only action state with bounded action/arguments; do not claim execution, grant approval, or navigate automatically. | `sse.ts:816`, `chatStore.ts:4271` |
| `response.elicitation_request` | `elicitation_request` | Interactive request: exact ID, owning child/session, message/preview/schema. Supported fields use matching response contract; unsupported URL/complex/native extras stay readable with explicit limits. | `sse.ts:834`, `blockStream.ts:823` |
| `response.elicitation_resolved` | `elicitation_resolved` | Resolve only matching request ID; duplicate resolution must not overwrite local verdict; tool output is not an approval signal. | `sse.ts:925`, `chatStore.ts:4668` |
| `response.policy_denied` | `policy_denied` | Activity/state: reason/phase; distinguish denied input from accepted/running work; never invent approval. | `sse.ts:935`, `blockStream.ts:870`, `chatStore.ts:4262` |

### Output-item fan-out and persisted types

Every row is a known persisted history type. Native history and live commits
must share the same decoder, stable IDs and readable presentation. The web live
parser intentionally skips reasoning/compaction commits; its history renderer
supports both, so native must not lose them after hydration.

| Item type | Normalized live variant | Required native presentation | Source |
| --- | --- | --- | --- |
| `message` | `message_done` | User/assistant text, Markdown/code, interrupted marker and reported author; retain attachment metadata. Suppress hidden context. | `conversationItems.ts:24`, `itemsToBlocks.ts:88`, `sse.ts:1009` |
| `function_call` | `tool_call` | Tool name, parsed/bounded arguments, call ID/status; one logical invocation per response+call, even observed/action-required duplicate commits. | `conversationItems.ts:38`, `itemsToBlocks.ts:195`, `blockStream.ts:495` |
| `function_call_output` | `tool_result` | Match call ID/response, expandable output; replace streaming preview, accept output before call metadata and backdated results without corrupting active turn. | `conversationItems.ts:47`, `itemsToBlocks.ts:223`, `blockStream.ts:559` |
| `error` | `error` | Durable readable source/code/message, same meaning as live error. | `conversationItems.ts:57`, `itemsToBlocks.ts:236`, `sse.ts:1020` |
| `reasoning` | None in web live parser | Exposed summary as activity; do not expose encrypted/hidden reasoning or invent content; settle live summary preview on committed item. | `conversationItems.ts:64`, `itemsToBlocks.ts:246` |
| `compaction` | None in web live parser | Compaction marker and supplied safe summary/token metadata; never hidden injected prompt as user prose. | `conversationItems.ts:103`, `itemsToBlocks.ts:271` |
| `slash_command` | `slash_command` | Skill/command name, arguments/output; missing kind defaults to skill. Preserve typed skill receipt (`/name args`), while built-in commands remain state/activity receipts. | `conversationItems.ts:116`, `itemsToBlocks.ts:285`, `sse.ts:1034` |
| `routing_decision` | `routing_decision` | Model, rationale, optional agent, and explicit applied versus would-have-picked distinction. | `conversationItems.ts:160`, `itemsToBlocks.ts:312`, `sse.ts:1056` |
| `terminal_command` | `terminal_command` | Read-only input versus stdout/stderr output; never execute or imply mobile terminal support. | `conversationItems.ts:143`, `itemsToBlocks.ts:324`, `sse.ts:1073` |
| `web_search_call` | `native_tool_call` | Search activity with provider-exposed query/status/results; URLs remain inert until explicit supported navigation. | `events.ts:14`, `itemsToBlocks.ts:255` |
| `file_search_call` | `native_tool_call` | File-search query/status/results with readable bounded details. | Same native-tool union |
| `code_interpreter_call` | `native_tool_call` | Code/outputs/status as display-only details; no execution by rendering. | Same native-tool union |
| `computer_call` | `native_tool_call` | Computer action/status as display-only details; no synthetic user approval. | Same native-tool union |
| `image_generation_call` | `native_tool_call` | Generation status and safe metadata; no automatic remote/base64 image fetch/render requirement. | Same native-tool union |
| `mcp_call` | `native_tool_call` | MCP server/tool/arguments/result/error metadata; redact secret-bearing fields and keep payload bounded. | Same native-tool union |
| `mcp_list_tools` | `native_tool_call` | MCP tools-discovery status and safe tool metadata. | Same native-tool union |

The remaining normalized variants in this table are `tool_call`, `tool_result`,
`message_done`, `slash_command`, `routing_decision`, `terminal_command` and
`native_tool_call`; `error` is shared with a direct event. Together with the raw
matrix this accounts for all 52 normalized discriminators.

### Message-content and hidden-context rules

[`blocks.ts`](../../web/src/lib/blocks.ts:46) models four content blocks:
`input_text`, `output_text`, `input_image`, and `input_file`. Text remains text;
image/file blocks preserve filename/file ID as inspectable attachment metadata.
Arbitrary attachment URLs must not be fetched automatically. Unsupported future
content parts retain bounded safe type/details, not an empty message.

[`itemsToBlocks.ts`](../../web/src/lib/itemsToBlocks.ts:137) additionally hides:

- Messages with `is_meta: true`.
- User context beginning `This session is being continued from a previous conversation`.
- Legacy user task notifications beginning `<task-notification>` and carrying
  `<task-id>` and `</task-notification>` markers.

These are context filtering rules, not permission to hide ordinary user text
that merely contains one marker. Hidden/encrypted reasoning fields must never
appear through generic payload fallback or an expanded details view.

### Interactive subcontracts

The same `response.elicitation_request` can carry binary approval, a JSON-schema
form, URL-mode approval, structured `ask_user_question`, `exit_plan_mode`, Codex
command approval (`command`, `cwd`, `reason`, `execpolicy_amendment`),
`allow_all_edits`, or `remember_scope`. The parent/child target belongs to the
request, not necessarily the displayed conversation. Supporting the event type
does not establish support for every form or persistent-policy mutation.

Native must list the supported response forms explicitly. Unsupported fields
must not be coerced into binary approve/decline, URL mode must not be silently
approved, and executing an embedded browser/client action is outside this
display implementation. A tool result cannot resolve an approval without the
matching `elicitation_id`.

### Transport, aliases and unknowns

| Input | Required handling |
| --- | --- |
| `response.TaskStatus.CREATED/QUEUED/IN_PROGRESS/COMPLETED/FAILED/INCOMPLETE/CANCELLED` | Normalize the final enum name to corresponding `response.*` lifecycle event, matching `sse.ts:251`. |
| `session.heartbeat` | Native session-stream liveness; no row. Do not reuse a stale heartbeat to revive a stopped SSE connection. |
| `response.heartbeat` | Keepalive only; no row and no response completion. |
| Bare `data: [DONE]` | Deliberate stream close, distinguished from reconnectable transport failure. |
| WebSocket `snapshot`, `changed`, `removed`, `heartbeat` | Session-list/inventory state; sparse active-session updates invalidate detailed metadata; removed means access/deletion state, not a fake assistant message. |
| Unknown future SSE event | Preserve bounded safe event identity/details where useful; no execution, automatic fetch, secret/encrypted-field disclosure, or crash. |
| Unknown future persisted item/content part | Readable bounded fallback with exact type and safe details; no placeholder-only handling for the 16 known types above. |
| Malformed known event | Ignore invalid fields or reject clearly without resetting unrelated state; never treat missing values as authoritative null/zero. |

## Verification ledger

The source inventory is complete. `ConversationActivity.swift` now provides the
shared history/live decoder; `LiveConversationReducer.swift` and
`LiveEventPresentation.swift` dispatch the stream contract; `SessionEventState.swift`
keeps non-transcript state. The independent suite is
`web/ios/NativeLab/Tests/NativeLabCoreTests/EventParityTests.swift`.

### Deterministic coverage map

The following groups account for all 47 direct raw names. Tests assert meaningful
content/state, reconciliation, or deliberate transport no-op; simply accepting a
frame without crashing is not considered parity. Test names below omit `test`.

| Contract group | Raw names covered | Primary evidence |
| --- | --- | --- |
| Response lifecycle | `response.created`, `queued`, `in_progress`, `completed`, `failed`, `incomplete`, `cancelled` | `EventParityTests.LifecycleAliasesHaveSameTransitionsAndIgnoreStaleTerminalIDs`; existing `LiveConversationReducerTests.ProviderFailureEndsSpinnerAndRetainsReadableError` |
| Text and item commit | `response.output_text.delta`, `response.output_item.done` | `EventParityTests.HistoryAndLiveCommitUseSamePresentationForEveryKnownFamily`; existing native-index, duplicate-commit and hydration tests in `LiveConversationReducerTests` |
| Tool output stream | `response.function_call_output.delta` | `EventParityTests.ToolOutputStreamsThenFinalCommitReplacesPreviewAndReplayDoesNotDuplicate` |
| Public reasoning summary | `response.reasoning.started`, `response.reasoning_text.delta`, `response.reasoning_summary_text.delta` | `EventParityTests.ReasoningSummaryInterleavesWithTextAndCommitRetiresOnlyMatchingActivity`; `ConversationItemPresentationTests.ReasoningNeverFallsBackToRawOrEncryptedContent` |
| Files, retries, errors, desktop tasks, policy | `response.output_file.done`, `response.retry`, `response.error`, `response.client_task.cancel`, `browser.action_request`, `response.policy_denied` | `EventParityTests.DisplayOnlyEventsHaveMeaningfulTypedActivity` |
| Compaction | `response.compaction.in_progress`, `completed`, `failed` | `EventParityTests.CompactionCompletesOrFailsWithoutChangingTranscriptMeaning` |
| Keepalive | `response.heartbeat` plus native `session.heartbeat` | `EventParityTests.TransportHeartbeatsNeverCreateTranscriptOrEndResponse`; transport readiness tests in `LocalServerSessionClientTests` |
| Status and usage | `session.status`, `session.usage` | `EventParityTests.StatusBackgroundCountIsSparseAndExplicitZeroClears`, `UsageSparseMergeReplacementAndResponseContextTokens`, `InvalidUsageNeverReplacesValidNonnegativeState` |
| Configuration and catalog | `session.model`, `session.reasoning_effort`, `session.collaboration_mode`, `session.agent_changed`, `session.skills`, `session.model_options` | `LiveConversationReducerTests.ConfigurationEventsRetainUnknownValuesAndDistinguishNullFromMissing`; `EventParityTests.CatalogSkillsAndChangedFilesInvalidateWithoutInventedTranscript`; configuration race tests in `SessionConfigurationTests` |
| Collections and startup | `session.todos`, `session.presence`, `session.terminal_pending`, `session.sandbox_status`, `session.mcp_startup` | `EventParityTests.TodosPresenceAndMCPReplacementListsClearOldEntries`, `StartupTransitionsRetainFailuresAndClearTransientTerminalState` |
| Input and interruption | `session.input.consumed`, `session.interrupted` | `LiveConversationReducerTests.ConsumedInputKeepsStableIDAndPendingCorrelation`, `HiddenContextNeverAppearsFromStream`; `EventParityTests.NestedInterruptionSealsOnlyTheMatchingLiveTurn` |
| Child/replacement sessions | `session.created`, `session.child_session.updated`, `session.superseded` | `EventParityTests.ChildUpdatesMergeAndSupersessionKeepsSourceConversation` |
| Resources and files | `session.resource.created`, `session.resource.deleted`, `session.terminal.activity`, `session.changed_files.invalidated` | `EventParityTests.ResourcesAreScopedAndDeletedFromActiveState`, `CatalogSkillsAndChangedFilesInvalidateWithoutInventedTranscript` |
| Interactive requests | `response.elicitation_request`, `response.elicitation_resolved` | `EventParityTests.ElicitationResolutionRequiresExactIDAndToolOutputCannotResolveIt`, `UnsupportedSchemaAndIncompleteURLModeCannotBecomeBinaryApproval`; `DecisionFormTests`; request-wire tests in `LocalServerSessionClientTests` |

Cross-cutting evidence:

- All **16** persisted families and all **seven** native-tool wrappers are asserted
  in `EventParityTests`, including readable content, status and stable identity.
- Wrong-session guards cover both `conversation_id` and `session_id`, plus nested
  resource ownership. Unknown live items remain bounded and credential/private
  fields are excluded from expanded details.
- `ConversationItemPresentationTests` covers legacy Codable compatibility,
  author/agent attribution, input-image/file/audio descriptors, embedded-data
  omission, hidden reasoning, unknown content, depth/node/text limits and
  JSON-encoded credential fields.
- `DecisionFormTests` covers scalar, numeric, enum and multi-select fields,
  structured questions, command/plan metadata, safe explicit URL handoff and
  rejection of unsupported/malformed constraints. Transport tests reject binary
  approval of typed forms and verify flat MCP answer payloads.
- `[DONE]` framing and UTF-8/CRLF boundaries are covered by the existing SSE parser
  tests. Existing transport tests cover WebSocket updates, hydration, reconnect,
  permission/read-only behavior and stopping writes when the stream is not ready.
- `LocalAttachmentTests` covers explicit same-server/session GET requests,
  credential-free byte delivery, all 17 supported MIME mappings, missing/active
  MIME rejection, advertised and actual 10 MiB limits, origin/redirect rejection,
  invalid references/identifiers and authentication revocation. The requests use
  an isolated URL protocol; no files are fetched from a running server.
- Changed-file transport tests in `LocalServerSessionClientTests` assert an
  event-scoped read, publication into session details, readable unavailability
  and no read for an unrelated session.
- `LiveEventReconciliationTests` adds 12 regression scenarios for chronological
  hydration, stopped partial text, native final chunks, cross-response tool-ID
  reuse, stale lifecycle events, summary identity, error deduplication, request
  resolution tombstones and safe incomplete structured tool output.

### Current execution result

The independent final full-suite run on 2026-10-19 passed: **197 tests executed,
two opt-in real-server tests skipped, zero failures**. This includes all 28
`EventParityTests`, eight `LocalAttachmentTests`, 14 `DecisionFormTests`, 11
`ConversationItemPresentationTests`, 12 `LiveEventReconciliationTests` and the
existing configuration/messaging regressions. Both independently added audit
test files also pass strict `swift-format lint`.

The primary run enabled the read-only local-server checks with
`OMNI_LOCAL_API_TESTS=1`: **197 tests passed, zero skipped, zero failures**
using `/private/tmp/omni-events-root`. No provider prompts were submitted.
An unsigned build for `generic/platform=iOS` also passed; this checks device
compilation, not installation or execution on a physical phone.

The audit caught and verified fixes for child sparse-merge, failed-compaction
token updates, reasoning/text boundaries, context-token selection, missing policy
activity, default changed-file environment, malformed/unsupported form fallback,
and inferred MIME types when no Content-Type was actually supplied. Typed forms
now reject binary approval while preserving the native field contract.

Run deterministic validation without any provider calls:

```sh
cd web/ios/NativeLab
OMNI_LOCAL_API_TESTS=0 swift test --disable-sandbox --scratch-path /private/tmp/omni-event-audit
```

`--disable-sandbox` avoids nested SwiftPM manifest sandbox failure in the agent
environment. The package has no external dependencies. The two opt-in real-server
tests are intentionally skipped by the explicit environment flag.

### Native journey verification

`UITests/NativeEventUITests.swift` contains eight representative gallery journeys.
The initial six-test run on an **iPhone SE (3rd generation), iOS 26.0 simulator**
passed two and had four failing journeys, exposing activity-toggle accessibility,
keyboard-blocked boolean selection and lost form drafts after sheet dismissal.
The result was read from `/private/tmp/omni-events-se-results.xcresult`.
The expanded eight-test run passed three and failed five; it additionally exposed
plain-button hit targets and ambiguous permission-dialog cancellation. Those
fixes are landed. A subsequent SE subset used an outdated installed test runner;
it is not accepted as final-source verification. The fresh-runner SE subset
passed file previews, command-policy confirmation, plan feedback and retained
structured answers. Its typed-field test overscrolled the numeric input; that
test-only navigation was corrected with a controlled slow scroll and end hold.
The focused rerun passed the full numeric and explicit-boolean submission journey.
No app code changed for these last test-navigation fixes.

Final result: **all eight unique gallery journeys plus one read-only live-server
journey passed**, across these iOS 26.0 simulator runs:

| Simulator | Bundle | Result |
| --- | --- | --- |
| iPhone 17 Pro | `/private/tmp/omni-events-final4-results.xcresult` | Three gallery journeys plus real-server resource history: 4/4 passed. |
| iPhone SE (3rd generation) | `/private/tmp/omni-events-se-fresh5-results.xcresult` | Four gallery journeys passed; typed input failed due to test scrolling. |
| iPhone SE (3rd generation) | `/private/tmp/omni-events-se-typed-slow-results.xcresult` | Corrected typed-input journey: 1/1 passed, zero skips. |

The passing typed-input rerun reports one runtime warning:
`Invalid frame dimension (negative or non-finite).` The result provides no source
location or stack, so ownership is unconfirmed. Inputs, explicit false selection,
submission and final response status passed; the screenshot is readable. This
warning remains follow-up work and the run is not described as warning-free.

The final-source **iPhone 17 Pro, iOS 26.0 simulator** run passed **four of four**
checks, with zero skips, failures or runtime warnings:

- Activity details, including terminal/tool output and safe unknown-event details.
- External confirmation without invented native approval controls.
- Session activity at the largest accessibility text size.
- Real local-server resource history with native details; stored history is
  byte-for-byte unchanged before and after inspection.

Result bundle: `/private/tmp/omni-events-final4-results.xcresult`.
Visually inspected captures:
[live resource details](screenshots/events-live-resource-details.png),
[tool details](screenshots/events-tool-details.png),
[terminal output](screenshots/events-terminal-details.png),
[largest-text usage](screenshots/events-largest-text-usage.png), and
[external confirmation](screenshots/events-external-handoff.png).

SE captures were also visually inspected:
[native file preview](screenshots/events-se-native-preview.png),
[explicit permission confirmation](screenshots/events-se-permission-confirmation.png),
[retained structured answers](screenshots/events-se-structured-question.png), and
[typed numeric/boolean answers](screenshots/events-se-typed-request.png).

The final app was installed and launched normally on the 17 Pro simulator,
without test/reset arguments or uninstalling the normal app. Welcome and the
local-server connection control were visually confirmed.

The gallery launch is isolated from normal
saved sessions, using its own `event-gallery-v1.json` fixture store:

```sh
xcrun simctl launch <booted-simulator-UDID> ai.omnigent.ios.lab \
  --ui-testing --ui-test-event-gallery --reset-demo
```

Choose the sample workspace, then exercise **Event gallery**, **Native
attachments**, **Typed request**, **Structured questions**, **Session state** and
**External confirmation**, plus **Plan review** and command-policy confirmation.
Expand tool/summary/terminal cards, type a composer
draft before opening details, verify that it survives dismissal, and repeat at
large Dynamic Type on a small phone.

To run only the eight offline event journeys from the repository root:

```sh
event_checks_dir=$(mktemp -d /private/tmp/omni-events.XXXXXX)
xcodebuild -project web/ios/NativeLab/NativeLab.xcodeproj -scheme NativeLab \
  -destination 'platform=iOS Simulator,id=<simulator-UDID>' \
  -derivedDataPath "$event_checks_dir/DerivedData" \
  -resultBundlePath "$event_checks_dir/Events.xcresult" \
  -only-testing:NativeLabUITests/NativeEventUITests \
  -parallel-testing-enabled NO -collect-test-diagnostics never test
```

Use a fresh DerivedData directory for reproducible runner installation. These
fixtures never connect to a provider or submit a real prompt. The separate live
resource-history journey needs the existing loopback configuration fixture.

### Deliberate limits

- Browser and client-task events describe desktop-side work; the phone does not
  execute a browser action, terminal command or arbitrary payload.
- Attachments preserve safe metadata/references. Explicit native previews are
  limited to files in the current session on the connected server, with a 10 MiB
  limit and an allowlist of declared static-media MIME types. Arbitrary external
  references, automatic downloads and base64 media rendering are not supported.
- Forms support the documented scalar/choice/question subset. Nested objects,
  union schemas, unsupported constraints and unsafe/missing confirmation URLs
  explicitly require the web app; they never become invented binary approvals.
- Reasoning displays only exposed summaries. Raw/private/encrypted reasoning is
  intentionally not reproduced, even if another client renders it.
- Deterministic fixtures establish native handling, not provider-backed execution,
  real-server reachability from a physical phone, background push delivery or
  production authentication. No provider prompts or hosted-session mutations were
  part of this audit.
- Physical-device behavior, spoken VoiceOver navigation and the iOS 18 fallback
  were not validated in this pass. The passing SE typed-form run still emits the
  unlocalized runtime layout warning recorded above.
