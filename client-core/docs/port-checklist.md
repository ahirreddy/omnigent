# Rust port checklist: NativeLab core and web/ios logic tests

This file tracks porting every NativeLab core test and every web/ios logic test to the Rust
client core in `client-core/`. It is the parity checklist the plan's Verification section
asks for. A ported test needs a named Rust counterpart running against the same fixtures.
The Swift suite under `apps/apple/Reference/NativeLab` stays the oracle until its cases all pass in Rust.

Sources:

- `apps/apple/Reference/NativeLab/Tests/NativeLabCoreTests/*.swift`: 22 suites, 288 tests.
- `web/ios/OmnigentTests/*.swift`: 25 suites, 310 XCTest methods. `MockHTTPServer.swift` is a
  helper with no tests. `grep -c 'func test'` reports 312 because it also counts two top-level
  helpers, `testSessionCookie` and `testWebSession`.

The wire contract these tests encode is in [`wire-contract.md`](wire-contract.md). Read it
first. Several NativeLab behaviours no longer match the current server, and that file lists
each divergence.

## Columns

- **Source::test**: Swift file and test method.
- **Rust crate::module**: target module. Modules marked `(new)` are not in the plan's module
  list. They are proposed here; see "Proposed modules" below.
- **Rust test**: proposed `#[test]` name. Keep it when porting so this table stays greppable.
- **Fixture(s)**: paths relative to `client-core/fixtures/`. Every NativeLab path listed exists and
  parses. `inline` means the test builds its input in code, with no JSON payload worth sharing.
  web/ios paths marked `(proposed)` do not exist yet. They need an `auth/` (and `session/`)
  fixture directory, which this preparation did not own. `manifest/` belongs to the scaffold agent.
- **Port mode**:
  - `port`: pure logic, ported as written.
  - `port + mock HTTP`: needs a scripted `HttpTransport` fake that asserts the request and
    returns the fixture envelope.
  - `port + fake store`: needs an in-memory `SecureStore`.
  - `port logic, Swift shim`: logic in Rust; the OS call stays in Swift behind a host trait.
  - `port (opt-in live server)`: env-gated in Swift (`OMNI_LOCAL_API_TESTS=1`). Port it as an
    `#[ignore]` integration test.
  - `keep Swift`: see "Stays Swift" at the end.
- **Status**: `todo` for every row. Change it to `done` in the PR that lands the Rust test.
- **Split?**: `yes` with a reason when the test crosses package boundaries, or is big enough
  to port on its own. Port these last within their package, or hand them to a follow-up package.

## Work packages

There are 7 packages, grouped so that each one owns a disjoint set of Rust files. In the
"Owns" column, crate paths are under `client-core/crates/`.

| Package | Scope | Owns (Rust files) | Depends on | Start |
|---|---|---|---|---|
| **WP1 protocol-models** | Serde models for items (all 11 server `ItemData` types, plus native_tool inner types), stream events (the 56-type `ServerStreamEvent` union plus `Unknown{type, raw}`), session list items and snapshots, elicitation wire, and the bounded or sanitised display of unknown JSON. | `omnigent-protocol/src/{items,events,sessions,elicitation,display}.rs` | nothing | **Immediately** |
| **WP2 sse-realtime** | Byte-level SSE parser with chunk-boundary proptests, stream state machine (ready heartbeat, `[DONE]` vs EOF, reconnect, 250 ms–5 s jittered backoff, 45 s stall watchdog), `WS /v1/sessions/updates` codec and state (watch set ≤500, 70 s silence watchdog), hydration-and-stream handoff ordering. | `omnigent-core/src/sse.rs`, `omnigent-core/src/realtime/{mod,stream,updates,backoff}.rs` | WP1 for typed events. The parser, backoff and WS frame codec can start on `serde_json::Value`. | **Immediately** (parser, backoff, WS codec); typed dispatch after WP1 |
| **WP3 reducer-reconcile** | `LiveConversationReducer`, `SessionEventState`, conversation activity and presentation, event hierarchy, history-vs-live reconciliation (item-id dedupe, `session.input.consumed`, interruption sealing, wrapper vs native turns). `insta` snapshots. | `omnigent-core/src/reducer/{mod,state,activity,presentation}.rs`, `omnigent-core/src/reconcile.rs` | WP1 (items, events) | After WP1 types merge. It can start earlier against an agreed `events.rs`/`items.rs` stub. |
| **WP4 interaction** | Submission ledger, decision forms (elicitation schema → typed form → resolve body), attachment drafts and upload validation, notification scope and push-payload decisions. | `omnigent-core/src/{ledger,decisions,attachments,notifications}.rs` | WP1 (`elicitation`, items) | Ledger and attachment-draft rows: **immediately** (no wire types). Decisions and uploads: after WP1. |
| **WP5 sessions-client** | REST session client: list, snapshot, items paging, send, interrupt, resolve, changed files, switch-agent, PATCH; session creation (agents, hosts, filesystem, model options); session configuration; execution readiness; the demo transport; session query and organization; workspace store. | `omnigent-core/src/client/{mod,sessions,items,events}.rs`, `creation.rs`, `config/session.rs`, `session_query.rs` (new), `workspace_store.rs` (new), `demo.rs` | WP1. The hydration and live rows also need WP2 and WP3. | REST-only rows (creation, config::session, paging, errors): after WP1. Live and hydration rows (marked split): last. |
| **WP6 auth-config** | Hosted auth (`/v1/info` mode resolution, accounts login, OIDC cli-login/poll with PKCE, native-token, refresh, revoke), server endpoint canonicalisation, manifest, deep links, managed configuration, settings logic, connection-error classification. | `omnigent-core/src/auth/{mod,accounts,oidc,pkce}.rs`, `server_url.rs`, `omnigent-protocol/src/manifest.rs`, `deeplink.rs` (new), `config/{managed,settings}.rs`, `error_text.rs` | nothing | **Immediately** |
| **WP7 databricks-auth** | Databricks OAuth (issuer discovery, PKCE authorize URL, token exchange and refresh, error mapping), token manager scheduling, credential record codec (v1 and v2), login manager, workspace bootstrap and recovery policy, web-context identity, `?o=` and `X-Databricks-Org-Id` routing. | `omnigent-core/src/auth/databricks/*.rs` | WP6's `auth/mod.rs` trait surface (token/credential types) | **Immediately**. Agree the `auth` trait surface with WP6 on day one. |

WP6 is the largest package (186 rows). It has two disjoint halves that can be staffed
separately if needed:

- auth, OIDC, server_url, manifest and errors (125 rows);
- `config::managed`, `config::settings` and `deeplink` (61 rows).

### Start order

1. **Wave 0, start now:**
   - WP1;
   - WP2 (parser, backoff and WS codec);
   - WP4 (ledger and attachment-draft rows);
   - WP6;
   - WP7.
2. **Wave 1, after WP1's `items`/`events`/`sessions`/`elicitation` types merge:**
   - WP3;
   - the rest of WP4;
   - WP5's REST-only rows;
   - WP2's typed dispatch.
3. **Wave 2, after the WP2 and WP3 public APIs exist:**
   - WP5's hydration and live rows;
   - every row marked `Split? yes` that crosses WP2, WP3 and WP5.

### Shared touch points (keep these edits one line each)

- `omnigent-core/src/lib.rs` and `omnigent-protocol/src/lib.rs`: each package adds only its own `mod` and `pub use` lines.
- `omnigent-core/src/error.rs` (`CoreError`): each package defines its own error enum in its module
  and adds one `From` conversion. No package rewrites `CoreError`.
- `omnigent-core/src/client.rs` exists in the scaffold. WP5 turns it into `client/mod.rs`; others only call it.
- Test support (`HttpTransport` script fake, fake `Clock`/`Scheduler`, in-memory `SecureStore`,
  fixture loader): put it in a `testing` module. WP1 creates the module, and each package adds only its own helpers to it.

### Swift sources each package must read

All NativeLab paths are under `apps/apple/Reference/NativeLab/Sources/NativeLabCore/`; all
web/ios paths are under `web/ios/Omnigent/`.

- **WP1:**
  - NativeLab:
    - `Models.swift`
    - `ConversationActivity.swift` (ConversationItem)
    - `LocalServerLiveModels.swift` (event wire types, `ElicitationWire`)
    - `LiveEventPresentation.swift` (JSONValue safe display)
    - `SessionEventState.swift`
    - `LocalServerSessionClient.swift` (`SessionWire`, `ItemWire`, `PageWire` decoding only)
  - Ground truth:
    - `omnigent/server/schemas.py` (`ServerStreamEvent`, `SessionListItem`, `SessionResponse`)
    - `omnigent/entities/conversation.py` (`ItemData`)
    - `web/src/lib/events.ts`
    - `web/src/lib/blocks.ts`
- **WP2:**
  - NativeLab:
    - `LocalServerLiveModels.swift` (`ServerSentEventParser`, `ServerSentEventByteParser`, `LiveConnectionState`)
    - `LocalServerStreaming.swift` (`runConversationStream`, `handleListMessage`, `streamFailure`/`shouldReconnect`, watch set, hydration)
    - `ServerConnection.swift`
    - `LiveConversationReducer.swift` (reconnect consumer)
  - Ground truth:
    - `web/src/lib/sse.ts`
    - `web/src/lib/reconnectBackoff.ts`
    - `web/src/lib/sessionUpdatesSocket.ts`
- **WP3:**
  - NativeLab:
    - `LiveConversationReducer.swift`
    - `LiveEventPresentation.swift`
    - `ConversationActivity.swift`
    - `SessionEventState.swift`
    - `ConversationState.swift`
    - `Models.swift`
    - `LocalServerStreaming.swift` (`finishHydration`, `rehydrateAfterMutation`)
    - `EventGalleryFixtures.swift`
  - Ground truth: `web/src/lib/blocks.ts` and `designs/ios-native/event-coverage.md`.
- **WP4:** all NativeLab:
  - `DecisionForm.swift`
  - `LocalServerLiveModels.swift` (`ElicitationWire`)
  - `Models.swift` (`DecisionResponse`)
  - `SubmissionLedger.swift`
  - `AttachmentDraft.swift`
  - `LocalServerUploads.swift`
  - `LocalServerAttachments.swift`
  - `NativeNotifications.swift`
  - `LocalServerNotifications.swift`
- **WP5:**
  - NativeLab:
    - `LocalServerSessionClient.swift`
    - `LocalServerSessionCreation.swift`
    - `SessionCreation.swift`
    - `LocalServerConfiguration.swift`
    - `SessionConfiguration.swift`
    - `SessionClient.swift`
    - `SessionQuery.swift`
    - `LocalWorkspace.swift`
    - `DemoSessionClient.swift`
    - `DemoFixtures.swift`
    - `DemoConfiguration.swift`
    - `Models.swift`
  - web/ios: `DatabricksSessionClient.swift` (session-cookie rows).
- **WP6:**
  - NativeLab:
    - `ServerConnection.swift` (`ServerEndpoint`, `ServerIdentityScope`)
    - `ServerAuthenticationClient.swift`
    - `SecureServerStore.swift` (`SavedServerAccount` logic)
    - `LocalServerSessionClient.swift` (connect, bearer, identity checks)
  - web/ios:
    - `OidcCredentials.swift`
    - `OidcCredentialStore.swift` (grant record JSON v1)
    - `OidcLoginManager.swift`
    - `OidcWebSession.swift`
    - `OAuthSupport.swift` (PKCE)
    - `ServerURL.swift`
    - `ServerManifest.swift`
    - `URL+Omnigent.swift`
    - `WorkspaceURLExpander.swift`
    - `DeepLink.swift`
    - `AppRootView.swift` (`conversationURL`)
    - `ManagedConfiguration.swift`
    - `ManagedConfigurationProvider.swift` (decode shape only)
    - `SettingsStore.swift`
    - `OmnigentWebView.swift` (`connectionErrorMessage`, `workspaceErrorMessage`, `handleWorkspaceHTTPStatus`)
    - `WebShellView.swift` (`RecoveryPage`, `RecoveryIntent`)
    - `WebViewModel.swift` (`serverPickerJSON`)
- **WP7:**
  - web/ios:
    - `DatabricksOAuthConfiguration.swift`
    - `DatabricksOAuthAttempt.swift`
    - `DatabricksOAuthClient.swift`
    - `DatabricksOAuthIssuer.swift`
    - `DatabricksCredentialStore.swift` (record codec; Keychain stays Swift)
    - `DatabricksLoginManager.swift`
    - `DatabricksTokenManager.swift`
    - `DatabricksWorkspaceBootstrap.swift`
    - `DatabricksWebContext.swift`
  - NativeLab: `ServerConnection.swift` (Databricks org routing).

### Proposed modules (not in the plan's list)

- `omnigent-core::client`: the REST request builder and response handler for sessions, items, events
  and resolves. It already exists as `client.rs`.
- `omnigent-core::session_query` (new): MobileCore search, pin ordering and filters.
- `omnigent-core::workspace_store` (new): persistence of local organisation and drafts, recovery,
  and handling of corrupt or future stores. The bytes go through a host store trait.
- `omnigent-core::deeplink` (new): deep-link grammar. It is not configuration.
- `omnigent-core::config` is split into `config::session` (WP5, session model/effort/agent
  configuration) and `config::{managed,settings}` (WP6, MDM managed configuration and settings logic).
  This avoids two packages editing one file.
- `omnigent-core::auth::{oidc,databricks}`: submodules of the plan's `auth`.

### Notes from extraction

- **Error item shapes:** error items appear in two shapes. Some carry nested `data.{source,code,message}`
  (LiveConversationReducer, persisted error) and some top-level `code/message/source` (EventParity,
  LiveEventReconciliation). WP1 must accept both. The server's `ErrorData` is top level inside `data`.
- **Synthetic test types:** some type names exist only in tests: `future_result`, `future_item`, `future_chart`,
  `response.future_activity`, `future.progress`. They exercise the `Unknown` fallback. Do not add them to the models.
- **Approximate fixtures:** the `EventGallery--*.json` and `DecisionForm` fixtures approximate Swift
  struct encodings (inferred Codable keys). Treat them as inputs and expected shapes, not byte-exact encodings.
- **Misnamed test:** web/ios `ServerURLTests::testPreservesPortAndNormalizesHostCase` asserts that host case is
  preserved. Name the Rust test after the behaviour.
- **KeyboardViewport:** web/ios `KeyboardViewportTests` has 8 rows of pure `CGRect` maths. They stay Swift by plan
  decision; they are the only pure candidates in that file.
- **Test hooks:** the Swift test hooks (`primeStreamForTesting`, `primeTransportForTesting`,
  `stopTransportForTesting`, `bufferSettingsAndTextForTesting`) must be rebuilt as Rust test
  harness state. The fixture envelopes leave out the default `/v1/info` and `/v1/me` stubs.

## Row counts

| Package | NativeLab rows | web/ios rows | Total | Split candidates |
|---|---|---|---|---|
| WP1 protocol-models | 28 | 0 | 28 | 2 |
| WP2 sse-realtime | 16 | 0 | 16 | 5 |
| WP3 reducer-reconcile | 67 | 0 | 67 | 9 |
| WP4 interaction | 71 | 0 | 71 | 8 |
| WP5 sessions-client | 82 | 10 | 92 | 10 |
| WP6 auth-config | 24 | 162 | 186 | 0 |
| WP7 databricks-auth | 0 | 84 | 84 | 0 |
| Stays Swift (web/ios only) | 0 | 54 | 54 | — |
| **Total** | 288 | 310 | 598 | |

## WP1 protocol-models — tests

### NativeLab: EventParityTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `EventParityTests.swift::testAllSixteenPersistedFamiliesHaveMeaningfulTypedPresentation` | Each of 16 persisted item families decodes to a typed activity or message with visible text and no preview fallback. | omnigent-protocol::items | `all_sixteen_persisted_families_have_meaningful_typed_presentation` | items/EventParity--AllSixteenPersistedFamiliesHaveMeaningfulTypedPresentation.json | port | done: `items::tests::all_sixteen_persisted_families_have_meaningful_typed_presentation` | no |
| `EventParityTests.swift::testEveryNativeToolSurvivesWrapperWithoutBecomingUnknown` | All seven native_tool wrapper types keep kind nativeTool, status completed, call id and visible detail. | omnigent-protocol::items | `every_native_tool_survives_wrapper_without_becoming_unknown` | items/EventParity--EveryNativeToolSurvivesWrapperWithoutBecomingUnknown.json | port | done: `items::tests::every_native_tool_survives_wrapper_without_becoming_unknown` | no |
| `EventParityTests.swift::testToolCallsAndResultsKeepResponseAndCallIdentity` | Function call and its output keep the shared call_id and response id. | omnigent-protocol::items | `tool_calls_and_results_keep_response_and_call_identity` | items/EventParity--ToolCallsAndResultsKeepResponseAndCallIdentity.json | port | done: `items::tests::tool_calls_and_results_keep_response_and_call_identity` | no |
| `EventParityTests.swift::testRoutingDistinguishesAppliedFromSuggestion` | Applied routing titles 'Using <model>', suggestion titles 'Would have picked <model>' and shows agent and rationale. | omnigent-protocol::items | `routing_distinguishes_applied_from_suggestion` | items/EventParity--RoutingDistinguishesAppliedFromSuggestion.json | port | done: `items::tests::routing_distinguishes_applied_from_suggestion` | no |
| `EventParityTests.swift::testSlashReceiptDefaultsToSkillAndPreservesInvocationAndOutput` | Slash receipt defaults to skill when kind missing; keeps invocation text and output; title prefix Skill or Command. | omnigent-protocol::items | `slash_receipt_defaults_to_skill_and_preserves_invocation_and_output` | items/EventParity--SlashReceiptDefaultsToSkillAndPreservesInvocationAndOutput.json | port | done: `items::tests::slash_receipt_defaults_to_skill_and_preserves_invocation_and_output` | no |
| `EventParityTests.swift::testTerminalInputAndOutputStayDistinctAndKeepBothStreams` | Terminal input and output are separate rows; output keeps stdout and stderr as separate detail sections. | omnigent-protocol::items | `terminal_input_and_output_stay_distinct_and_keep_both_streams` | items/EventParity--TerminalInputAndOutputStayDistinctAndKeepBothStreams.json | port | done: `items::tests::terminal_input_and_output_stay_distinct_and_keep_both_streams` | no |
| `EventParityTests.swift::testResourceReceiptsDistinguishCreateAndDeleteWithoutLosingIdentity` | Resource created vs deleted titles differ and both still show resource name and id. | omnigent-protocol::items | `resource_receipts_distinguish_create_and_delete_without_losing_identity` | items/EventParity--ResourceReceiptsDistinguishCreateAndDeleteWithoutLosingIdentity.json | port | done: `items::tests::resource_receipts_distinguish_create_and_delete_without_losing_identity` | no |
| `EventParityTests.swift::testContextFilteringMatchesWholeLegacyNotificationNotLooseMarkers` | Only whole legacy context/notification messages and is_meta messages are hidden; lookalike text stays visible. | omnigent-protocol::items | `context_filtering_matches_whole_legacy_notification_not_loose_markers` | items/EventParity--ContextFilteringMatchesWholeLegacyNotificationNotLooseMarkers.json | port | done: `items::tests::context_filtering_matches_whole_legacy_notification_not_loose_markers` | no |
| `EventParityTests.swift::testUnknownLiveEventsHaveBoundedInspectableSafeFallback` | Unknown live event becomes an unknown activity row; text bounded; credentials and encrypted fields removed. | omnigent-protocol::events | `unknown_live_events_have_bounded_inspectable_safe_fallback` | inline | port | done: `events::tests::unknown_live_events_have_bounded_inspectable_safe_fallback` | no |

### NativeLab: ConversationItemPresentationTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `ConversationItemPresentationTests.swift::testLegacyConversationMessagesDecodeWithoutNewFields` | Legacy message JSON without the newer optional fields decodes and round-trips unchanged. | omnigent-protocol::items | `legacy_conversation_messages_decode_without_new_fields` | items/ConversationItemPresentation--LegacyConversationMessagesDecodeWithoutNewFields.json | port | done: `items::tests::legacy_conversation_messages_decode_without_new_fields` (wire-item form; the `ConversationMessage` fixture shape is a WP3 presentation type) | no |
| `ConversationItemPresentationTests.swift::testAttachmentDescriptorsPreserveTextWithoutEmbeddingOrFetchingContent` | Image, file and audio parts become descriptors; inline bytes are marked embedded and never encoded. | omnigent-protocol::items | `attachment_descriptors_preserve_text_without_embedding_or_fetching_content` | items/ConversationItemPresentation--AttachmentDescriptorsPreserveTextWithoutEmbeddingOrFetchingContent.json | port | done: `items::tests::attachment_descriptors_preserve_text_without_embedding_or_fetching_content` | no |
| `ConversationItemPresentationTests.swift::testRefusalsAndInterruptedMessagesRemainVisible` | Refusal text and interrupted flag stay visible with the partial output. | omnigent-protocol::items | `refusals_and_interrupted_messages_remain_visible` | items/ConversationItemPresentation--RefusalsAndInterruptedMessagesRemainVisible.json | port | done: `items::tests::refusals_and_interrupted_messages_remain_visible` | no |
| `ConversationItemPresentationTests.swift::testMessageAttributionPreservesHumanAndAgentIdentity` | User messages keep created_by as author; assistant messages keep model as agent. | omnigent-protocol::items | `message_attribution_preserves_human_and_agent_identity` | items/ConversationItemPresentation--MessageAttributionPreservesHumanAndAgentIdentity.json | port | done: `items::tests::message_attribution_preserves_human_and_agent_identity` | no |
| `ConversationItemPresentationTests.swift::testReasoningNeverFallsBackToRawOrEncryptedContent` | Reasoning shows only the public summary; raw content and encrypted content never leak. | omnigent-protocol::items | `reasoning_never_falls_back_to_raw_or_encrypted_content` | items/ConversationItemPresentation--ReasoningNeverFallsBackToRawOrEncryptedContent.json | port | done: `items::tests::reasoning_never_falls_back_to_raw_or_encrypted_content` | no |
| `ConversationItemPresentationTests.swift::testNestedUnknownPayloadSanitizesCredentialsAndPrivateReasoning` | Unknown item payload keeps public results and drops credential headers, passwords, encrypted and reasoning content. | omnigent-protocol::items | `nested_unknown_payload_sanitizes_credentials_and_private_reasoning` | items/ConversationItemPresentation--NestedUnknownPayloadSanitizesCredentialsAndPrivateReasoning.json | port | done: `items::tests::nested_unknown_payload_sanitizes_credentials_and_private_reasoning` | no |
| `ConversationItemPresentationTests.swift::testJSONEncodedToolArgumentsAndOutputAreSanitized` | Tool arguments and output given as JSON strings are parsed and redacted before display. | omnigent-protocol::items | `json_encoded_tool_arguments_and_output_are_sanitized` | items/ConversationItemPresentation--JSONEncodedToolArgumentsAndOutputAreSanitized.json | port | done: `items::tests::json_encoded_tool_arguments_and_output_are_sanitized` | no |
| `ConversationItemPresentationTests.swift::testIncompleteStructuredArgumentsNeverExposePrivateValues` | Incomplete JSON-looking strings show a generic incomplete marker; known placeholders pass through unchanged. | omnigent-protocol::items | `incomplete_structured_arguments_never_expose_private_values` | inline | port | done: `items::tests::incomplete_structured_arguments_never_expose_private_values` | no |
| `ConversationItemPresentationTests.swift::testUnknownPayloadsAreBoundedByCharactersDepthAndEntryCount` | Oversized unknown payloads are truncated by characters, depth and entry count; deep and late entries never appear. | omnigent-protocol::items | `unknown_payloads_are_bounded_by_characters_depth_and_entry_count` | inline | port | done: `items::tests::unknown_payloads_are_bounded_by_characters_depth_and_entry_count` | no |
| `ConversationItemPresentationTests.swift::testMessagePrivateBlocksDoNotBecomeUnknownContentCards` | Thinking and redacted thinking blocks inside a message are dropped; only the output text remains. | omnigent-protocol::items | `message_private_blocks_do_not_become_unknown_content_cards` | items/ConversationItemPresentation--MessagePrivateBlocksDoNotBecomeUnknownContentCards.json | port | done: `items::tests::message_private_blocks_do_not_become_unknown_content_cards` | no |
| `ConversationItemPresentationTests.swift::testNewContentBlocksHaveUsefulSafeDetails` | Unknown content block shows a safe detail (caption) and hides unrelated secret fields. | omnigent-protocol::items | `new_content_blocks_have_useful_safe_details` | items/ConversationItemPresentation--NewContentBlocksHaveUsefulSafeDetails.json | port | done: `items::tests::new_content_blocks_have_useful_safe_details` | no |

### NativeLab: LocalServerSessionClientTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `LocalServerSessionClientTests.swift::testPermissionCapabilitiesAndProviderFailureMetadata` | Permission level 2 gives rename/pin but not archive; last_task_error becomes the failure message; editor archive is readOnly | omnigent-protocol::sessions | `permission_capabilities_and_provider_failure_metadata` | sessions/LocalServerSessionClient--PermissionCapabilitiesAndProviderFailureMetadata.jsonl | port | done: `sessions::tests::permission_capabilities_and_provider_failure_metadata` | no |
| `LocalServerSessionClientTests.swift::testPersistedRunnerFailureRemainsReadableAfterReopeningWithoutLastTaskError` | A persisted runner error item becomes a readable tool row with its code; the session failure message survives reopening | omnigent-protocol::items | `persisted_runner_failure_remains_readable_after_reopening_without_last_task_error` | sessions/LocalServerSessionClient--PersistedRunnerFailureRemainsReadableAfterReopeningWithoutLastTaskError--session.json; items/LocalServerSessionClient--PersistedRunnerFailureRemainsReadableAfterReopeningWithoutLastTaskError--history.json | port | done: `items::tests::persisted_runner_failure_remains_readable_after_reopening_without_last_task_error` (item decode and snapshot failure message; the tool-row text is WP3 presentation) | yes: items decode plus session failure metadata |
| `LocalServerSessionClientTests.swift::testMalformedPersistedErrorsDoNotHideMissingCauseBehindUnsupportedPreview` | Error items without a usable code or message (missing, blank, whitespace) are malformedResponse, not a fallback preview | omnigent-protocol::items | `malformed_persisted_errors_do_not_hide_missing_cause_behind_unsupported_preview` | items/LocalServerSessionClient--MalformedPersistedErrorsDoNotHideMissingCauseBehindUnsupportedPreview.jsonl | port | done: `items::tests::malformed_persisted_errors_do_not_hide_missing_cause_behind_unsupported_preview` | no |
| `LocalServerSessionClientTests.swift::testHistoryPagesUseStoredOrderAndPreserveTypedContent` | History keeps stored order, joins output_text, maps input_image and function_call/reasoning items, and passes the cursor verbatim | omnigent-protocol::items | `history_pages_use_stored_order_and_preserve_typed_content` | items/LocalServerSessionClient--HistoryPagesUseStoredOrderAndPreserveTypedContent.json | port | done: `items::tests::history_pages_use_stored_order_and_preserve_typed_content` | no |
| `LocalServerSessionClientTests.swift::testEmptyHistoryAndToolOutputs` | Empty history yields no messages; function_call_output becomes a tool message with its text | omnigent-protocol::items | `empty_history_and_tool_outputs` | items/LocalServerSessionClient--EmptyHistoryAndToolOutputs--empty.json; items/LocalServerSessionClient--EmptyHistoryAndToolOutputs--tool-output.json | port | done: `items::tests::empty_history_and_tool_outputs` | no |
| `LocalServerSessionClientTests.swift::testHiddenMetaMessagesDoNotLeakAndAnAllMetaPageKeepsItsCursor` | is_meta messages are hidden, and a page of only hidden items keeps its cursor so the next page loads | omnigent-protocol::items | `hidden_meta_messages_do_not_leak_and_an_all_meta_page_keeps_its_cursor` | items/LocalServerSessionClient--HiddenMetaMessagesDoNotLeakAndAnAllMetaPageKeepsItsCursor--meta-page.json; items/LocalServerSessionClient--HiddenMetaMessagesDoNotLeakAndAnAllMetaPageKeepsItsCursor--visible-page.json | port | done: `items::tests::hidden_meta_messages_do_not_leak_and_an_all_meta_page_keeps_its_cursor` | no |
| `LocalServerSessionClientTests.swift::testMalformedResponsesAndHistoryAreNotReportedAsEmptySuccess` | Non-JSON, empty-object and wrong-type info responses, plus malformed history items (missing role, bad content, empty id), are malformedResponse | omnigent-protocol::items | `malformed_responses_and_history_are_not_reported_as_empty_success` | sessions/LocalServerSessionClient--MalformedResponsesAndHistoryAreNotReportedAsEmptySuccess--info.jsonl; items/LocalServerSessionClient--MalformedResponsesAndHistoryAreNotReportedAsEmptySuccess--items.jsonl | port | done: `items::tests::malformed_responses_and_history_are_not_reported_as_empty_success` (items half; the `/v1/info` half is WP6) | yes: info discovery (auth) plus items decode |

### NativeLab: SessionConfigurationTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `SessionConfigurationTests.swift::testPartialListProjectionPreservesConfigurationButExplicitNullClearsIt` | A partial list projection keeps prior configuration; explicit nulls and an empty model list clear it; a host going offline is kept | omnigent-protocol::sessions | `partial_list_projection_preserves_configuration_but_explicit_null_clears_it` | sessions/SessionConfiguration--PartialListProjectionPreservesConfigurationButExplicitNullClearsIt.json | port | done: `sessions::tests::partial_list_projection_preserves_configuration_but_explicit_null_clears_it` | no |

## WP2 sse-realtime — tests

### NativeLab: LiveConversationReducerTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `LiveConversationReducerTests.swift::testRealReconnectUsesFreshReducerSoInflightReplayDoesNotDoublePrefix` | After reconnect a fresh reducer replays index 4 and 5 without doubling the prefix; the old reducer state is discarded. | omnigent-core::realtime | `real_reconnect_uses_fresh_reducer_so_inflight_replay_does_not_double_prefix` | events/LiveConversationReducer--RealReconnectUsesFreshReducerSoInflightReplayDoesNotDoublePrefix--reconnected.jsonl, events/LiveConversationReducer--RealReconnectUsesFreshReducerSoInflightReplayDoesNotDoublePrefix--stale-reducer.jsonl | port | todo | yes - reconnect boundary crosses WP2 realtime and WP3 reducer |
| `LiveConversationReducerTests.swift::testByteFramingRetainsEmptyLinesCRLFAndUTF8` | Byte-level SSE framing keeps UTF-8 text, CRLF and blank-line event boundaries, including a BOM. | omnigent-core::sse | `byte_framing_retains_empty_lines_crlf_and_utf8` | inline | port | done | no |
| `LiveConversationReducerTests.swift::testSSEParserHandlesCommentsMultilineAndBoundaries` | SSE parser ignores comments, joins multi-line data with newlines, and emits on blank-line boundaries, including [DONE]. | omnigent-core::sse | `sse_parser_handles_comments_multiline_and_boundaries` | inline | port | done | no |

### NativeLab: LocalServerSessionClientTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `LocalServerSessionClientTests.swift::testTransientHydrationFailureReopensSSEAutomatically` | A transient hydration network failure moves the stream to reconnecting and reopens /stream | omnigent-core::realtime::stream | `transient_hydration_failure_reopens_sse_automatically` | inline | port | done | yes: hydration failure plus SSE reconnect |
| `LocalServerSessionClientTests.swift::testAuthenticationHydrationFailureStopsInsteadOfRetrying` | An unauthorized hydration failure marks the stream failed and does not retry | omnigent-core::realtime::stream | `authentication_hydration_failure_stops_instead_of_retrying` | inline | port | done | no |
| `LocalServerSessionClientTests.swift::testOptInLocalSSEAndWebSocketBecomeLiveWithoutPolling` | Against a live local server (env-gated), SSE and WebSocket reach live state without polling | omnigent-core::realtime | `opt_in_local_sse_and_web_socket_become_live_without_polling` | inline | port (opt-in live server) | todo | yes: needs live server, SSE and WS together |
| `LocalServerSessionClientTests.swift::testListFramesUpdatePermissionsAndRemoveLostAccess` | WS changed frame updates permission to writable; removed frame emits sessionsRemoved | omnigent-core::realtime::updates | `list_frames_update_permissions_and_remove_lost_access` | sessions/LocalServerSessionClient--ListFramesUpdatePermissionsAndRemoveLostAccess.jsonl | port | done | no |
| `LocalServerSessionClientTests.swift::testWatchLimitFailsExplicitlyInsteadOfSilentlyMissingInboxSessions` | Watching 501 sessions fails watchLimitExceeded and sends no request | omnigent-core::realtime::updates | `watch_limit_fails_explicitly_instead_of_silently_missing_inbox_sessions` | inline | port | done | no |

### NativeLab: LocalServerHydrationStreamingTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `LocalServerHydrationStreamingTests.swift::testInitialHydrationPublishesUnindexedDeltasBeforeHistoryAndAppliesThemOnce` | Unindexed deltas that arrive during initial hydration publish immediately, then history merges them exactly once | omnigent-core::realtime | `initial_hydration_publishes_unindexed_deltas_before_history_and_applies_them_once` | sse/LocalServerHydrationStreaming--InitialHydrationPublishesUnindexedDeltasBeforeHistoryAndAppliesThemOnce--live.jsonl; items/LocalServerHydrationStreaming--InitialHydrationPublishesUnindexedDeltasBeforeHistoryAndAppliesThemOnce--history.json | port | todo | yes: hydration plus stream handoff |
| `LocalServerHydrationStreamingTests.swift::testStoppedGenerationCannotPublishLateHydrationOrEvents` | After stopWatching, a late hydration result and late deltas publish nothing (reducer stays nil) | omnigent-core::realtime | `stopped_generation_cannot_publish_late_hydration_or_events` | sse/LocalServerHydrationStreaming--StoppedGenerationCannotPublishLateHydrationOrEvents--late-delta.jsonl; items/LocalServerHydrationStreaming--StoppedGenerationCannotPublishLateHydrationOrEvents--history.json | port | todo | no |

### NativeLab: HostedServerAuthenticationTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `HostedServerAuthenticationTests.swift::testSSEUnauthorizedStopsAndPublishesSignInAgainWithoutRetry` | A 401 from the SSE stream publishes a failed sign-in state and does not reconnect | omnigent-core::realtime::stream | `sse_unauthorized_stops_and_publishes_sign_in_again_without_retry` | sse/HostedServerAuthentication--SSEUnauthorizedStopsAndPublishesSignInAgainWithoutRetry.json; sessions/HostedServerAuthentication--_shared--hosted-configure.jsonl | port | done | no |
| `HostedServerAuthenticationTests.swift::testSocketHandshakeAuthAndTLSFailuresDoNotReconnect` | WebSocket handshake 302, 401 and 403, plus TLS and auth-challenge errors, are classified as non-reconnectable | omnigent-core::realtime::updates | `socket_handshake_auth_and_tls_failures_do_not_reconnect` | inline | port | done | no |

### NativeLab: SessionConfigurationTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `SessionConfigurationTests.swift::testSparseListChangeLoadsExternalModelWithoutRunnerEchoOrPolling` | A sparse WS changed frame triggers one hydrating GET that loads the external model, with no mutations or polling | omnigent-core::realtime | `sparse_list_change_loads_external_model_without_runner_echo_or_polling` | sessions/SessionConfiguration--SparseListChangeLoadsExternalModelWithoutRunnerEchoOrPolling--session.json; items/SessionConfiguration--SparseListChangeLoadsExternalModelWithoutRunnerEchoOrPolling--items.json; sessions/SessionConfiguration--SparseListChangeLoadsExternalModelWithoutRunnerEchoOrPolling--ws.jsonl | port | todo | yes: WS frame plus REST hydrate |
| `SessionConfigurationTests.swift::testSparseReconnectSnapshotLoadsMissedExternalModel` | A sparse reconnect snapshot frame loads the external model that was missed | omnigent-core::realtime | `sparse_reconnect_snapshot_loads_missed_external_model` | sessions/SessionConfiguration--SparseListChangeLoadsExternalModelWithoutRunnerEchoOrPolling--session.json; items/SessionConfiguration--SparseListChangeLoadsExternalModelWithoutRunnerEchoOrPolling--items.json; sessions/SessionConfiguration--SparseReconnectSnapshotLoadsMissedExternalModel--ws.jsonl | port | todo | no |
| `SessionConfigurationTests.swift::testSparseListUpdateDoesNotHydrateOrReviveStoppedConversationStream` | A sparse list update after the stream is stopped does not hydrate or revive it | omnigent-core::realtime | `sparse_list_update_does_not_hydrate_or_revive_stopped_conversation_stream` | sessions/SessionConfiguration--SparseListUpdateDoesNotHydrateOrReviveStoppedConversationStream--ws.jsonl | port | todo | no |

### NativeLab: SessionExecutionReadinessTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `SessionExecutionReadinessTests.swift::testSparsePushUpdatesReadinessAndPreventsStaleSnapshotRestoringOnlineState` | A sparse WS push updates readiness; a stale snapshot cannot restore the online state | omnigent-core::realtime | `sparse_push_updates_readiness_and_prevents_stale_snapshot_restoring_online_state` | sessions/SessionExecutionReadiness--SparsePushUpdatesReadinessAndPreventsStaleSnapshotRestoringOnlineState--session.json; sessions/SessionExecutionReadiness--SparsePushUpdatesReadinessAndPreventsStaleSnapshotRestoringOnlineState--ws.jsonl | port | todo | no |

## WP3 reducer-reconcile — tests

### NativeLab: EventParityTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `EventParityTests.swift::testHistoryAndLiveCommitUseSamePresentationForEveryKnownFamily` | Live output_item.done commit (applied twice) yields the same message as history decode for all 16 families. | omnigent-core::reducer | `history_and_live_commit_use_same_presentation_for_every_known_family` | items/EventParity--HistoryAndLiveCommitUseSamePresentationForEveryKnownFamily.json | port | todo | yes - item decode (WP1) plus reducer commit path |
| `EventParityTests.swift::testLifecycleAliasesHaveSameTransitionsAndIgnoreStaleTerminalIDs` | response.* and response.TaskStatus.* aliases give the same running/idle transitions; stale terminal ids are ignored. | omnigent-core::reducer | `lifecycle_aliases_have_same_transitions_and_ignore_stale_terminal_i_ds` | inline | port | todo | no |
| `EventParityTests.swift::testUsageSparseMergeReplacementAndResponseContextTokens` | Sparse usage events merge fields; empty usage_by_model replaces; response.completed usage sets context_tokens 120. | omnigent-core::reducer | `usage_sparse_merge_replacement_and_response_context_tokens` | events/EventParity--UsageSparseMergeReplacementAndResponseContextTokens.jsonl | port | todo | no |
| `EventParityTests.swift::testInvalidUsageNeverReplacesValidNonnegativeState` | Negative, zero, string or null usage values never overwrite valid stored usage. | omnigent-core::reducer | `invalid_usage_never_replaces_valid_nonnegative_state` | events/EventParity--InvalidUsageNeverReplacesValidNonnegativeState.jsonl | port | todo | no |
| `EventParityTests.swift::testStatusBackgroundCountIsSparseAndExplicitZeroClears` | background_task_count persists when absent and clears only on an explicit 0. | omnigent-core::reducer | `status_background_count_is_sparse_and_explicit_zero_clears` | events/EventParity--StatusBackgroundCountIsSparseAndExplicitZeroClears.jsonl | port | todo | no |
| `EventParityTests.swift::testTodosPresenceAndMCPReplacementListsClearOldEntries` | Todos, viewers and mcp_startup replace wholesale, so empty payloads clear old entries. | omnigent-core::reducer | `todos_presence_and_mcp_replacement_lists_clear_old_entries` | events/EventParity--TodosPresenceAndMCPReplacementListsClearOldEntries.jsonl | port | todo | no |
| `EventParityTests.swift::testStartupTransitionsRetainFailuresAndClearTransientTerminalState` | Terminal-pending section toggles; sandbox stages keep failure text; mcp server statuses update. | omnigent-core::reducer | `startup_transitions_retain_failures_and_clear_transient_terminal_state` | events/EventParity--StartupTransitionsRetainFailuresAndClearTransientTerminalState.jsonl | port | todo | no |
| `EventParityTests.swift::testResourcesAreScopedAndDeletedFromActiveState` | Resource create is idempotent; delete only applies for the owning session; terminal activity flag set and cleared. | omnigent-core::reducer | `resources_are_scoped_and_deleted_from_active_state` | events/EventParity--ResourcesAreScopedAndDeletedFromActiveState.jsonl | port | todo | no |
| `EventParityTests.swift::testChildUpdatesMergeAndSupersessionKeepsSourceConversation` | Child session updates merge; superseded sets replacement id while the snapshot keeps the source id. | omnigent-core::reducer | `child_updates_merge_and_supersession_keeps_source_conversation` | events/EventParity--ChildUpdatesMergeAndSupersessionKeepsSourceConversation.jsonl | port | todo | no |
| `EventParityTests.swift::testCatalogSkillsAndChangedFilesInvalidateWithoutInventedTranscript` | Skills, model options and agent change request reconcile with no invented messages; changed-files invalidation is per environment. | omnigent-core::reducer | `catalog_skills_and_changed_files_invalidate_without_invented_transcript` | events/EventParity--CatalogSkillsAndChangedFilesInvalidateWithoutInventedTranscript.jsonl | port | todo | no |
| `EventParityTests.swift::testSessionEventsFromOtherConversationCannotMutateSnapshot` | Session-scoped events for another conversation change nothing (effects and snapshot). | omnigent-core::reducer | `session_events_from_other_conversation_cannot_mutate_snapshot` | events/EventParity--SessionEventsFromOtherConversationCannotMutateSnapshot.jsonl | port | todo | no |
| `EventParityTests.swift::testTransportHeartbeatsNeverCreateTranscriptOrEndResponse` | response.heartbeat and session.heartbeat change nothing and do not end the running response. | omnigent-core::reducer | `transport_heartbeats_never_create_transcript_or_end_response` | events/EventParity--TransportHeartbeatsNeverCreateTranscriptOrEndResponse.jsonl | port | todo | no |
| `EventParityTests.swift::testDisplayOnlyEventsHaveMeaningfulTypedActivity` | Six display-only events (file, retry, error, client task, browser, policy) each produce a typed activity row with readable content and no pending decision. | omnigent-core::reducer | `display_only_events_have_meaningful_typed_activity` | events/EventParity--DisplayOnlyEventsHaveMeaningfulTypedActivity.jsonl | port | todo | no |
| `EventParityTests.swift::testCompactionCompletesOrFailsWithoutChangingTranscriptMeaning` | Compaction in_progress is one streaming row that completes (sets context_tokens) or fails (readable failure); transcript text unchanged. | omnigent-core::reducer | `compaction_completes_or_fails_without_changing_transcript_meaning` | events/EventParity--CompactionCompletesOrFailsWithoutChangingTranscriptMeaning--completed.jsonl, events/EventParity--CompactionCompletesOrFailsWithoutChangingTranscriptMeaning--failed.jsonl | port | todo | no |
| `EventParityTests.swift::testToolOutputStreamsThenFinalCommitReplacesPreviewAndReplayDoesNotDuplicate` | Streamed tool output preview is replaced by the final committed result; replaying the commit does not duplicate it. | omnigent-core::reducer | `tool_output_streams_then_final_commit_replaces_preview_and_replay_does_not_duplicate` | events/EventParity--ToolOutputStreamsThenFinalCommitReplacesPreviewAndReplayDoesNotDuplicate.jsonl | port | todo | no |
| `EventParityTests.swift::testReasoningSummaryInterleavesWithTextAndCommitRetiresOnlyMatchingActivity` | Text before and after a reasoning summary stays ordered; raw reasoning is never displayed; only the matching summary is retired. | omnigent-core::reducer | `reasoning_summary_interleaves_with_text_and_commit_retires_only_matching_activity` | events/EventParity--ReasoningSummaryInterleavesWithTextAndCommitRetiresOnlyMatchingActivity.jsonl | port | todo | no |
| `EventParityTests.swift::testNestedInterruptionSealsOnlyTheMatchingLiveTurn` | Interrupt for an old response is ignored; interrupt for the active response seals the partial reply. | omnigent-core::reducer | `nested_interruption_seals_only_the_matching_live_turn` | events/EventParity--NestedInterruptionSealsOnlyTheMatchingLiveTurn.jsonl | port | todo | no |

### NativeLab: LiveConversationReducerTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `LiveConversationReducerTests.swift::testNativeRepliesStreamAfterWrapperCompletionAcrossConsecutiveTurns` | Across two consecutive turns, native text streams after each wrapper completion and late deltas after the commit are dropped. | omnigent-core::reducer | `native_replies_stream_after_wrapper_completion_across_consecutive_turns` | events/LiveConversationReducer--NativeRepliesStreamAfterWrapperCompletionAcrossConsecutiveTurns.jsonl | port | todo | no |
| `LiveConversationReducerTests.swift::testWrapperCompletionDoesNotSealNativeTextAlreadyStreaming` | Wrapper completion does not seal native text already streaming; the later commit replaces the preview. | omnigent-core::reducer | `wrapper_completion_does_not_seal_native_text_already_streaming` | events/LiveConversationReducer--WrapperCompletionDoesNotSealNativeTextAlreadyStreaming.jsonl | port | todo | no |
| `LiveConversationReducerTests.swift::testNativeInterruptionRejectsLateTextButNextTurnStillStreams` | Interrupt seals the partial reply; late text for it is rejected; the next message id still streams. | omnigent-core::reducer | `native_interruption_rejects_late_text_but_next_turn_still_streams` | events/LiveConversationReducer--NativeInterruptionRejectsLateTextButNextTurnStillStreams.jsonl | port | todo | no |
| `LiveConversationReducerTests.swift::testOrdinaryResponseDeltasRemainBlockedAfterCompletion` | Ordinary response deltas after response.completed do not change the snapshot. | omnigent-core::reducer | `ordinary_response_deltas_remain_blocked_after_completion` | events/LiveConversationReducer--OrdinaryResponseDeltasRemainBlockedAfterCompletion.jsonl | port | todo | no |
| `LiveConversationReducerTests.swift::testConfigurationEventsRetainUnknownValuesAndDistinguishNullFromMissing` | Model and reasoning-effort events keep unknown raw values; null resets to 'Harness default'; missing or wrong-conversation fields change nothing. | omnigent-core::reducer | `configuration_events_retain_unknown_values_and_distinguish_null_from_missing` | events/LiveConversationReducer--ConfigurationEventsRetainUnknownValuesAndDistinguishNullFromMissing.jsonl | port | todo | yes - needs SessionConfiguration from WP5 config |
| `LiveConversationReducerTests.swift::testCatalogAndHarnessEventsRequestAuthoritativeReconciliation` | model_options and agent_changed request reconciliation; an authoritative snapshot replaces configuration wholesale. | omnigent-core::reconcile | `catalog_and_harness_events_request_authoritative_reconciliation` | inline | port | todo | no |
| `LiveConversationReducerTests.swift::testPersistedErrorItemRetainsCauseWhenReplayedAndDoesNotDuplicate` | A persisted error item keeps its code and message as one tool row, even when replayed. | omnigent-core::reducer | `persisted_error_item_retains_cause_when_replayed_and_does_not_duplicate` | events/LiveConversationReducer--PersistedErrorItemRetainsCauseWhenReplayedAndDoesNotDuplicate.jsonl | port | todo | no |
| `LiveConversationReducerTests.swift::testInPlaceHydrationPreservesPrefixAndNativeChunkDeduplication` | Hydration keeps streamed prefix and title change; duplicate native index is ignored; text continues. | omnigent-core::reconcile | `in_place_hydration_preserves_prefix_and_native_chunk_deduplication` | events/LiveConversationReducer--InPlaceHydrationPreservesPrefixAndNativeChunkDeduplication.jsonl | port | todo | no |
| `LiveConversationReducerTests.swift::testOlderHistoryPrefixCannotRetireNewerStreamingText` | Older saved history prefix does not retire newer streaming text; the final commit does. | omnigent-core::reconcile | `older_history_prefix_cannot_retire_newer_streaming_text` | events/LiveConversationReducer--OlderHistoryPrefixCannotRetireNewerStreamingText.jsonl | port | todo | no |
| `LiveConversationReducerTests.swift::testInPlaceHydrationPreservesOrdinaryResponsePrefixAndPreviewPosition` | Hydration keeps the ordinary-response preview in its chronological slot between user and tool rows. | omnigent-core::reconcile | `in_place_hydration_preserves_ordinary_response_prefix_and_preview_position` | events/LiveConversationReducer--InPlaceHydrationPreservesOrdinaryResponsePrefixAndPreviewPosition.jsonl | port | todo | no |
| `LiveConversationReducerTests.swift::testHydrationCommitRetiresMatchingPreviewBeforeBufferedFinalItem` | Hydration with a committed message retires the matching preview; a buffered late final item and delta do not reappear. | omnigent-core::reconcile | `hydration_commit_retires_matching_preview_before_buffered_final_item` | events/LiveConversationReducer--HydrationCommitRetiresMatchingPreviewBeforeBufferedFinalItem.jsonl | port | todo | no |
| `LiveConversationReducerTests.swift::testNativeDeltasDeduplicateIndexAndCommitRetiresPreview` | Native deltas dedupe by index; the committed item retires the preview; late deltas are dropped. | omnigent-core::reducer | `native_deltas_deduplicate_index_and_commit_retires_preview` | events/LiveConversationReducer--NativeDeltasDeduplicateIndexAndCommitRetiresPreview.jsonl | port | todo | no |
| `LiveConversationReducerTests.swift::testDuplicateCommittedItemCannotDiscardNewerPreview` | Re-committing an older item does not discard a newer streaming preview. | omnigent-core::reducer | `duplicate_committed_item_cannot_discard_newer_preview` | events/LiveConversationReducer--DuplicateCommittedItemCannotDiscardNewerPreview.jsonl | port | todo | no |
| `LiveConversationReducerTests.swift::testOrdinaryDeltaSegmentsBecomePersistedItemsWithoutDuplicates` | Two ordinary delta segments each become one persisted item with no duplicates. | omnigent-core::reducer | `ordinary_delta_segments_become_persisted_items_without_duplicates` | events/LiveConversationReducer--OrdinaryDeltaSegmentsBecomePersistedItemsWithoutDuplicates.jsonl | port | todo | no |
| `LiveConversationReducerTests.swift::testConsumedInputKeepsStableIDAndPendingCorrelation` | Consumed user input keeps a stable item id and reports the cleared pending id; a repeat frame does not duplicate. | omnigent-core::reducer | `consumed_input_keeps_stable_id_and_pending_correlation` | events/LiveConversationReducer--ConsumedInputKeepsStableIDAndPendingCorrelation.jsonl | port | todo | no |
| `LiveConversationReducerTests.swift::testHiddenContextNeverAppearsFromStream` | is_meta input and output from the stream never appear as messages. | omnigent-core::reducer | `hidden_context_never_appears_from_stream` | events/LiveConversationReducer--HiddenContextNeverAppearsFromStream.jsonl | port | todo | no |
| `LiveConversationReducerTests.swift::testProviderFailureEndsSpinnerAndRetainsReadableError` | Failed response ends running, stores 'Sign in again' as readable failure and requests reconcile. | omnigent-core::reducer | `provider_failure_ends_spinner_and_retains_readable_error` | events/LiveConversationReducer--ProviderFailureEndsSpinnerAndRetainsReadableError.jsonl | port | todo | no |
| `LiveConversationReducerTests.swift::testStaleResponseCompletionCannotStopNewerReply` | Completion for an old response id does not stop the active newer response. | omnigent-core::reducer | `stale_response_completion_cannot_stop_newer_reply` | events/LiveConversationReducer--StaleResponseCompletionCannotStopNewerReply.jsonl | port | todo | no |
| `LiveConversationReducerTests.swift::testRehydrationDiscardsOldPreviewsAndPendingDecisions` | A fresh reducer from committed history drops old previews and pending decisions. | omnigent-core::reconcile | `rehydration_discards_old_previews_and_pending_decisions` | events/LiveConversationReducer--RehydrationDiscardsOldPreviewsAndPendingDecisions.jsonl | port | todo | no |

### NativeLab: LiveEventReconciliationTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `LiveEventReconciliationTests.swift::testStoppedPartialTextAndFileKeepTheirChronologyAcrossHydration` | Partial text and a file row keep chronological order across two hydrations and the final assistant item. | omnigent-core::reconcile | `stopped_partial_text_and_file_keep_their_chronology_across_hydration` | events/LiveEventReconciliation--StoppedPartialTextAndFileKeepTheirChronologyAcrossHydration.jsonl | port | todo | no |
| `LiveEventReconciliationTests.swift::testNativeFinalSealsPreviewAndRejectsLateOrFractionalIndices` | Fractional index and post-final deltas are rejected; final seals the preview; reconcile keeps it sealed. | omnigent-core::reducer | `native_final_seals_preview_and_rejects_late_or_fractional_indices` | events/LiveEventReconciliation--NativeFinalSealsPreviewAndRejectsLateOrFractionalIndices.jsonl | port | todo | no |
| `LiveEventReconciliationTests.swift::testNativeMessagesWithoutOptionalIndicesKeepEveryDelta` | Native deltas without index are all appended in order. | omnigent-core::reducer | `native_messages_without_optional_indices_keep_every_delta` | events/LiveEventReconciliation--NativeMessagesWithoutOptionalIndicesKeepEveryDelta.jsonl | port | todo | no |
| `LiveEventReconciliationTests.swift::testOldResponseStartStatusAndDeltasCannotInterruptNewResponse` | Stale created, status and delta events for an old response leave the new streaming response intact. | omnigent-core::reducer | `old_response_start_status_and_deltas_cannot_interrupt_new_response` | events/LiveEventReconciliation--OldResponseStartStatusAndDeltasCannotInterruptNewResponse.jsonl | port | todo | no |
| `LiveEventReconciliationTests.swift::testRepeatedToolCallIDsRemainResponseScopedAndOldCommitDoesNotConsumeNewPreview` | A reused call_id across responses stays scoped; old response commit does not consume the new preview. | omnigent-core::reducer | `repeated_tool_call_i_ds_remain_response_scoped_and_old_commit_does_not_consume_new_preview` | events/LiveEventReconciliation--RepeatedToolCallIDsRemainResponseScopedAndOldCommitDoesNotConsumeNewPreview.jsonl | port | todo | no |
| `LiveEventReconciliationTests.swift::testReasoningCommitReplayAndHydrationRetireOnlyCorrespondingSummary` | Committing and replaying one reasoning summary retires only that summary; the other stays streaming until hydration. | omnigent-core::reconcile | `reasoning_commit_replay_and_hydration_retire_only_corresponding_summary` | events/LiveEventReconciliation--ReasoningCommitReplayAndHydrationRetireOnlyCorrespondingSummary.jsonl | port | todo | no |
| `LiveEventReconciliationTests.swift::testErrorLiveStatusStoredAndReplayBecomeOneReadableRow` | Live error, failed status, persisted error and replay collapse into one readable error row. | omnigent-core::reducer | `error_live_status_stored_and_replay_become_one_readable_row` | events/LiveEventReconciliation--ErrorLiveStatusStoredAndReplayBecomeOneReadableRow.jsonl | port | todo | no |
| `LiveEventReconciliationTests.swift::testSessionIdleSealsAllActivityAndLateDeltasCannotRestartSpinner` | Session idle seals reasoning, tool output and compaction rows; late deltas do not restart the spinner. | omnigent-core::reducer | `session_idle_seals_all_activity_and_late_deltas_cannot_restart_spinner` | events/LiveEventReconciliation--SessionIdleSealsAllActivityAndLateDeltasCannotRestartSpinner.jsonl | port | todo | no |
| `LiveEventReconciliationTests.swift::testInvalidSessionStatusDoesNotPoisonMetadata` | An invalid status value and its background count do not change the snapshot. | omnigent-core::reducer | `invalid_session_status_does_not_poison_metadata` | events/LiveEventReconciliation--InvalidSessionStatusDoesNotPoisonMetadata.jsonl | port | todo | no |
| `LiveEventReconciliationTests.swift::testIncompleteReasonIsVisibleAfterResponseStops` | response.incomplete stops the response and shows max_output_tokens as a readable error row. | omnigent-core::reducer | `incomplete_reason_is_visible_after_response_stops` | events/LiveEventReconciliation--IncompleteReasonIsVisibleAfterResponseStops.jsonl | port | todo | no |
| `LiveEventReconciliationTests.swift::testStreamingStructuredToolOutputDoesNotLeakPartialSecrets` | Partial structured tool output containing an api_key is never shown until it parses; visible result shows without the secret. | omnigent-core::reducer | `streaming_structured_tool_output_does_not_leak_partial_secrets` | events/LiveEventReconciliation--StreamingStructuredToolOutputDoesNotLeakPartialSecrets.jsonl | port | todo | yes - safe-display sanitizer lives in WP1 |

### NativeLab: EventHierarchyTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `EventHierarchyTests.swift::testRoutineReceiptsMoveToActivityWithoutChangingHistory` | Resource receipts are classified as lifecycle activity; transcript ids stay the same and the snapshot round-trips byte-stable. | omnigent-core::reducer | `routine_receipts_move_to_activity_without_changing_history` | events/EventGallery--lifecycle.json | port | todo | no |
| `EventHierarchyTests.swift::testFailuresAttachmentsAndTerminalOutputAreNeverQuieted` | Failed status, attachments and terminal output are never classified as quiet activity-only rows. | omnigent-core::reducer | `failures_attachments_and_terminal_output_are_never_quieted` | inline | port | todo | no |
| `EventHierarchyTests.swift::testOnlyFinishedClientBookkeepingIsQuieted` | Only client tasks that are cancelled, canceled or completed count as routine lifecycle. | omnigent-core::reducer | `only_finished_client_bookkeeping_is_quieted` | inline | port | todo | no |
| `EventHierarchyTests.swift::testHistoryAndStreamUseSameLifecycleProjection` | A resource_event receipt projects identically whether it comes from history or the live stream. | omnigent-core::reducer | `history_and_stream_use_same_lifecycle_projection` | events/EventHierarchy--HistoryAndStreamUseSameLifecycleProjection.json | port | todo | yes - history ItemWire decode (WP1) plus reducer projection |
| `EventHierarchyTests.swift::testStopMarksOnlyCurrentReplyAndCompletionIsQuiet` | Cancel or interrupt marks only the current reply interrupted; a normal completion is not marked interrupted. | omnigent-core::reducer | `stop_marks_only_current_reply_and_completion_is_quiet` | events/EventHierarchy--StopMarksOnlyCurrentReplyAndCompletionIsQuiet--response_cancelled.jsonl, events/EventHierarchy--StopMarksOnlyCurrentReplyAndCompletionIsQuiet--session_interrupted.jsonl, events/EventHierarchy--StopMarksOnlyCurrentReplyAndCompletionIsQuiet--response_completed.jsonl | port | todo | no |

### NativeLab: ConversationStateTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `ConversationStateTests.swift::testNewerSnapshotReplacesMessagesAndDecisionsTogether` | A newer revision replaces messages and decisions together; resolved decisions stay resolved. | omnigent-core::reconcile | `newer_snapshot_replaces_messages_and_decisions_together` | sessions/DemoFixtures--demo-design.json | port | todo | no |
| `ConversationStateTests.swift::testOlderAndEqualRevisionsCannotRestoreResolvedDecision` | Older and equal-revision snapshots are rejected and cannot bring back a resolved decision. | omnigent-core::reconcile | `older_and_equal_revisions_cannot_restore_resolved_decision` | sessions/DemoFixtures--demo-design.json | port | todo | no |
| `ConversationStateTests.swift::testDifferentSessionIsRejectedEvenWithHigherRevision` | A snapshot for another session is rejected even with a higher revision. | omnigent-core::reconcile | `different_session_is_rejected_even_with_higher_revision` | sessions/DemoFixtures--demo-design.json, sessions/DemoFixtures--demo-question.json | port | todo | no |

### NativeLab: LocalServerHydrationStreamingTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `LocalServerHydrationStreamingTests.swift::testRehydrationKeepsGrowingTextAndChunkIndicesWithoutReplayingDeltas` | Rehydration keeps growing native text across indexed chunks and ignores replayed indices | omnigent-core::reducer | `rehydration_keeps_growing_text_and_chunk_indices_without_replaying_deltas` | sse/LocalServerHydrationStreaming--RehydrationKeepsGrowingTextAndChunkIndicesWithoutReplayingDeltas--before.jsonl; sse/LocalServerHydrationStreaming--RehydrationKeepsGrowingTextAndChunkIndicesWithoutReplayingDeltas--during.jsonl; sse/LocalServerHydrationStreaming--RehydrationKeepsGrowingTextAndChunkIndicesWithoutReplayingDeltas--after.jsonl; items/LocalServerHydrationStreaming--RehydrationKeepsGrowingTextAndChunkIndicesWithoutReplayingDeltas--history.json | port | todo | yes: hydration handoff plus reducer chunk dedupe |
| `LocalServerHydrationStreamingTests.swift::testShorterPersistedPrefixCannotReplaceTextThatGrewDuringHydration` | A shorter persisted assistant prefix cannot replace text that grew during hydration; the message stays streaming | omnigent-core::reducer | `shorter_persisted_prefix_cannot_replace_text_that_grew_during_hydration` | sse/LocalServerHydrationStreaming--ShorterPersistedPrefixCannotReplaceTextThatGrewDuringHydration--before.jsonl; sse/LocalServerHydrationStreaming--ShorterPersistedPrefixCannotReplaceTextThatGrewDuringHydration--during.jsonl; sse/LocalServerHydrationStreaming--ShorterPersistedPrefixCannotReplaceTextThatGrewDuringHydration--after.jsonl; items/LocalServerHydrationStreaming--ShorterPersistedPrefixCannotReplaceTextThatGrewDuringHydration--history.json | port | todo | yes: hydration handoff plus prefix rule |
| `LocalServerHydrationStreamingTests.swift::testHydratedCommitReplacesLivePreviewWithoutDuplicatingText` | The hydrated saved message replaces the live preview; a late indexed replay adds no duplicate text | omnigent-core::reducer | `hydrated_commit_replaces_live_preview_without_duplicating_text` | sse/LocalServerHydrationStreaming--HydratedCommitReplacesLivePreviewWithoutDuplicatingText--before.jsonl; sse/LocalServerHydrationStreaming--HydratedCommitReplacesLivePreviewWithoutDuplicatingText--after.jsonl; items/LocalServerHydrationStreaming--HydratedCommitReplacesLivePreviewWithoutDuplicatingText--history.json | port | todo | yes: hydration handoff plus commit reconcile |
| `LocalServerHydrationStreamingTests.swift::testConsumedInputIsPublishedImmediatelyAndItsEffectIsNotRepeatedOnHydration` | session.input.consumed publishes the next user message at once; hydration does not repeat its effect | omnigent-core::reconcile | `consumed_input_is_published_immediately_and_its_effect_is_not_repeated_on_hydration` | sse/LocalServerHydrationStreaming--ConsumedInputIsPublishedImmediatelyAndItsEffectIsNotRepeatedOnHydration--live.jsonl; items/LocalServerHydrationStreaming--ConsumedInputIsPublishedImmediatelyAndItsEffectIsNotRepeatedOnHydration--history.json | port | todo | no |

### NativeLab: SessionConfigurationTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `SessionConfigurationTests.swift::testStreamEventCrossingSnapshotReadRejectsStaleConfiguration` | A session.model event crossing a configuration snapshot read rejects it as changedElsewhere and caches nothing | omnigent-core::reconcile | `stream_event_crossing_snapshot_read_rejects_stale_configuration` | sessions/SessionConfiguration--StreamEventCrossingSnapshotReadRejectsStaleConfiguration--snapshot.json; sse/SessionConfiguration--StreamEventCrossingSnapshotReadRejectsStaleConfiguration--event.jsonl | port | todo | no |
| `SessionConfigurationTests.swift::testListEventCrossingSnapshotReadRejectsStaleConfiguration` | A WS changed-list frame crossing a snapshot read rejects it as changedElsewhere and caches the newer model | omnigent-core::reconcile | `list_event_crossing_snapshot_read_rejects_stale_configuration` | sessions/SessionConfiguration--ListEventCrossingSnapshotReadRejectsStaleConfiguration--snapshot.json; sessions/SessionConfiguration--ListEventCrossingSnapshotReadRejectsStaleConfiguration--ws.jsonl | port | todo | no |
| `SessionConfigurationTests.swift::testSlowHistoryCannotRollbackNewerMetadata` | A slow history read cannot roll back a newer model delivered by a list change that arrived meanwhile | omnigent-core::reconcile | `slow_history_cannot_rollback_newer_metadata` | sessions/SessionConfiguration--SlowHistoryCannotRollbackNewerMetadata--session.json; items/SessionConfiguration--SlowHistoryCannotRollbackNewerMetadata--items.json; sessions/SessionConfiguration--SlowHistoryCannotRollbackNewerMetadata--ws.jsonl | port | todo | yes: history plus list reconcile |
| `SessionConfigurationTests.swift::testSlowListAndInventoryCannotRollbackNewerMetadata` | Slow list and inventory reads cannot roll back a newer model delivered by a WS frame | omnigent-core::reconcile | `slow_list_and_inventory_cannot_rollback_newer_metadata` | sessions/SessionConfiguration--SlowListAndInventoryCannotRollbackNewerMetadata--list.json; sessions/SessionConfiguration--SlowListAndInventoryCannotRollbackNewerMetadata--ws.jsonl | port | todo | no |
| `SessionConfigurationTests.swift::testHydrationCompletionPreservesAcknowledgedConfigurationAndSchedulesFollowup` | Hydration completion keeps the acknowledged external model and schedules a follow-up hydration when a mutation arrived | omnigent-core::reconcile | `hydration_completion_preserves_acknowledged_configuration_and_schedules_followup` | sessions/SessionConfiguration--HydrationCompletionPreservesAcknowledgedConfigurationAndSchedulesFollowup.json | port | todo | no |
| `SessionConfigurationTests.swift::testStableConfigurationReadSupersedesBufferedSettingsButKeepsText` | A stable configuration read supersedes buffered older settings events but keeps buffered text deltas | omnigent-core::reconcile | `stable_configuration_read_supersedes_buffered_settings_but_keeps_text` | sessions/SessionConfiguration--StableConfigurationReadSupersedesBufferedSettingsButKeepsText.json; sse/SessionConfiguration--StableConfigurationReadSupersedesBufferedSettingsButKeepsText--buffered.jsonl | port | todo | no |
| `SessionConfigurationTests.swift::testListReadAlsoUpdatesReducerBeforeNextStreamPublication` | A session list read updates the reducer so the next published snapshot carries the external model | omnigent-core::reconcile | `list_read_also_updates_reducer_before_next_stream_publication` | sessions/SessionConfiguration--ListReadAlsoUpdatesReducerBeforeNextStreamPublication.json | port | todo | no |
| `SessionConfigurationTests.swift::testSparseChangeHydrationCannotOverwriteLaterCompleteMetadata` | A delayed hydration started by a sparse change cannot overwrite later complete metadata (newer-model) | omnigent-core::reconcile | `sparse_change_hydration_cannot_overwrite_later_complete_metadata` | sessions/SessionConfiguration--SparseChangeHydrationCannotOverwriteLaterCompleteMetadata--session.json; sessions/SessionConfiguration--SparseChangeHydrationCannotOverwriteLaterCompleteMetadata--ws.jsonl | port | todo | yes: WS frames plus delayed hydrate plus reconcile |

## WP4 interaction — tests

### NativeLab: EventParityTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `EventParityTests.swift::testElicitationResolutionRequiresExactIDAndToolOutputCannotResolveIt` | Only elicitation_resolved with the exact id clears the pending request; a tool output with the same call id does not. | omnigent-core::decisions | `elicitation_resolution_requires_exact_id_and_tool_output_cannot_resolve_it` | events/EventParity--ElicitationResolutionRequiresExactIDAndToolOutputCannotResolveIt.jsonl | port | done (`decisions::ledger`; the reducer turn status is WP3) | yes - pending decisions state crosses WP3 reducer |
| `EventParityTests.swift::testUnsupportedSchemaAndIncompleteURLModeCannotBecomeBinaryApproval` | Array schema, oneOf schema and URL mode without URL each decode with unsupportedReason. | omnigent-core::decisions | `unsupported_schema_and_incomplete_url_mode_cannot_become_binary_approval` | decisions/EventParity--UnsupportedSchemaAndIncompleteURLModeCannotBecomeBinaryApproval.jsonl | port | done (`decisions`) | no |

### NativeLab: LiveConversationReducerTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `LiveConversationReducerTests.swift::testApprovalAndSingleFieldQuestionUseOriginatingSession` | Single-field enum question keeps the child target session, options and answer key, and clears on resolve. | omnigent-core::decisions | `approval_and_single_field_question_use_originating_session` | events/LiveConversationReducer--ApprovalAndSingleFieldQuestionUseOriginatingSession.jsonl | port | done (`decisions::ledger`; the reducer turn status is WP3) | yes - reducer pending state plus decision model |
| `LiveConversationReducerTests.swift::testMultiFieldFormsUseTypedFieldsInsteadOfBinaryApprovals` | Multi-field request becomes a typed form with sorted keys and integer/text kinds, not a binary approval. | omnigent-core::decisions | `multi_field_forms_use_typed_fields_instead_of_binary_approvals` | decisions/LiveConversationReducer--MultiFieldFormsUseTypedFieldsInsteadOfBinaryApprovals.json | port | done (`decisions`) | no |

### NativeLab: LiveEventReconciliationTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `LiveEventReconciliationTests.swift::testResolvedElicitationReplayCannotReappearAndUnknownResolutionDoesNotStopResponse` | A resolved elicitation cannot come back on replay or stale reconcile; an unknown resolution id does not stop the response. | omnigent-core::decisions | `resolved_elicitation_replay_cannot_reappear_and_unknown_resolution_does_not_stop_response` | events/LiveEventReconciliation--ResolvedElicitationReplayCannotReappearAndUnknownResolutionDoesNotStopResponse.jsonl | port | done (`decisions::ledger`: an unknown id is `ResolvedOutcome::Unknown`; keeping the response running is WP3) | yes - reconcile plus decisions state |

### NativeLab: DecisionFormTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `DecisionFormTests.swift::testTypedSchemaHasNativeFieldsAndValidatesWithoutCoercion` | Typed object schema becomes a native form; validation enforces min length, integer range and no string-to-number coercion. | omnigent-core::decisions | `typed_schema_has_native_fields_and_validates_without_coercion` | decisions/DecisionForm--TypedSchemaHasNativeFieldsAndValidatesWithoutCoercion.json | port | done (`decisions`) | no |
| `DecisionFormTests.swift::testUnsupportedNestedSchemaNeverBecomesApproval` | Nested object property yields unsupportedReason and no form. | omnigent-core::decisions | `unsupported_nested_schema_never_becomes_approval` | decisions/DecisionForm--UnsupportedNestedSchemaNeverBecomesApproval.json | port | done (`decisions`) | no |
| `DecisionFormTests.swift::testUnsupportedPatternNeverSilentlyDisappears` | A pattern constraint is reported as unsupported rather than dropped. | omnigent-core::decisions | `unsupported_pattern_never_silently_disappears` | decisions/DecisionForm--UnsupportedPatternNeverSilentlyDisappears.json | port | done (`decisions`) | no |
| `DecisionFormTests.swift::testSchemaWithoutPropertiesAndMissingURLNeverBecomeApproval` | Schemas without object properties and URL mode without a URL are unsupported. | omnigent-core::decisions | `schema_without_properties_and_missing_url_never_become_approval` | decisions/DecisionForm--SchemaWithoutPropertiesAndMissingURLNeverBecomeApproval.jsonl | port | done (`decisions`) | no |
| `DecisionFormTests.swift::testMalformedConstraintsFailClosed` | Malformed constraint values (required string, fractional or negative lengths, string minimum, min greater than max) fail closed. | omnigent-core::decisions | `malformed_constraints_fail_closed` | decisions/DecisionForm--MalformedConstraintsFailClosed.jsonl | port | done (`decisions`) | no |
| `DecisionFormTests.swift::testCommandPolicyAndMetadataRemainExplicit` | Command approval keeps the execpolicy amendment and shows working directory and reason. | omnigent-core::decisions | `command_policy_and_metadata_remain_explicit` | decisions/DecisionForm--CommandPolicyAndMetadataRemainExplicit.json | port | done (`decisions`) | no |
| `DecisionFormTests.swift::testArrayChoicesValidateCountAndMembership` | Array choices enforce min and max item count, enum membership and uniqueness. | omnigent-core::decisions | `array_choices_validate_count_and_membership` | decisions/DecisionForm--ArrayChoicesValidateCountAndMembership.json | port | done (`decisions`) | no |
| `DecisionFormTests.swift::testAskUserQuestionPreservesIDsAndSupportsCustomAndMultiAnswers` | AskUserQuestion keeps question ids, allows custom and multi-select answers, and requires an answer for each question. | omnigent-core::decisions | `ask_user_question_preserves_i_ds_and_supports_custom_and_multi_answers` | decisions/DecisionForm--AskUserQuestionPreservesIDsAndSupportsCustomAndMultiAnswers.json | port | done (`decisions`) | no |
| `DecisionFormTests.swift::testQuestionPreviewFallbackProducesForm` | A question embedded in content_preview is parsed into a form field keyed by its text. | omnigent-core::decisions | `question_preview_fallback_produces_form` | decisions/DecisionForm--QuestionPreviewFallbackProducesForm.json | port | done (`decisions`) | no |
| `DecisionFormTests.swift::testMalformedQuestionCannotBecomeApproval` | A question without options is unsupported, never a binary approval. | omnigent-core::decisions | `malformed_question_cannot_become_approval` | decisions/DecisionForm--MalformedQuestionCannotBecomeApproval.json | port | done (`decisions`) | no |
| `DecisionFormTests.swift::testExternalRequestOnlyExposesSafeExplicitHandoff` | https confirmation link is exposed as an explicit handoff; javascript: URLs are not exposed. | omnigent-core::decisions | `external_request_only_exposes_safe_explicit_handoff` | decisions/DecisionForm--ExternalRequestOnlyExposesSafeExplicitHandoff.jsonl | port | done (`decisions`) | no |
| `DecisionFormTests.swift::testPlanAndRememberCapabilitiesAreExplicit` | Plan review and remember-scope requests set explicit capability flags and label. | omnigent-core::decisions | `plan_and_remember_capabilities_are_explicit` | decisions/DecisionForm--PlanAndRememberCapabilitiesAreExplicit.jsonl | port | done (`decisions`) | no |
| `DecisionFormTests.swift::testDecisionValuesEncodeAsFlatMCPScalars` | Decision values encode as flat JSON scalars and arrays and decode back equal. | omnigent-core::decisions | `decision_values_encode_as_flat_mcp_scalars` | decisions/DecisionForm--DecisionValuesEncodeAsFlatMCPScalars.json | port | done (`decisions`) | no |
| `DecisionFormTests.swift::testUnknownResponseFieldIsRejected` | A form response with a key not in the schema fails validation. | omnigent-core::decisions | `unknown_response_field_is_rejected` | inline | port | done (`decisions`) | no |

### NativeLab: AttachmentDraftTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `AttachmentDraftTests.swift::testSupportedTypesExactCapsAndFilenameValidation` | Each supported type accepts exactly its size cap and rejects one byte more; unsupported and unsafe filenames or media types are rejected. | omnigent-core::attachments | `supported_types_exact_caps_and_filename_validation` | attachments/AttachmentDraft--SupportedTypesExactCapsAndFilenameValidation.json | port | done (`attachments::policy`) | no |
| `AttachmentDraftTests.swift::testFileReaderRejectsOversizeFoldersAndLinksBeforeBuffering` | Reading a file reads its bytes; symlinks, folders and oversize files are rejected before buffering. | omnigent-core::attachments | `file_reader_rejects_oversize_folders_and_links_before_buffering` | inline | port | done (`attachments::policy`; the host does the stat and reads through `UploadFileReader`) | no |
| `AttachmentDraftTests.swift::testDraftCountAndAggregateByteLimits` | Draft caps: 8 files per session, 20 MiB per large file and a global aggregate byte limit. | omnigent-core::attachments | `draft_count_and_aggregate_byte_limits` | inline | port | done (`attachments::draft`) | no |
| `AttachmentDraftTests.swift::testSuccessfulUploadIsReusedOnExplicitSendRetryAndScopedToSession` | A successful upload is reused, not re-uploaded, across send and retry, and drafts are scoped per session and server. | omnigent-core::attachments | `successful_upload_is_reused_on_explicit_send_retry_and_scoped_to_session` | inline | port | done (`attachments::draft`) | no |
| `AttachmentDraftTests.swift::testAcceptedSnapshotOnlyRemovesCapturedFilesEvenAfterScopeSwitch` | An accepted send removes only the files captured in that batch, even after scope switches or a later add. | omnigent-core::attachments | `accepted_snapshot_only_removes_captured_files_even_after_scope_switch` | inline | port | done (`attachments::draft`) | no |
| `AttachmentDraftTests.swift::testUncertainSendRetainsFilesAndBlocksDuplicateUntilExplicitReview` | An uncertain send keeps files, blocks new submissions until explicit acknowledgment in the same scope, then allows a reviewed retry. | omnigent-core::attachments | `uncertain_send_retains_files_and_blocks_duplicate_until_explicit_review` | inline | port | done (`attachments::draft`) | no |
| `AttachmentDraftTests.swift::testRejectedUploadRetainsFileAndExplicitRetryOnlyUploadsFailedItem` | A rejected upload keeps the file; explicit retry uploads only the failed item, not already-uploaded ones. | omnigent-core::attachments | `rejected_upload_retains_file_and_explicit_retry_only_uploads_failed_item` | inline | port | done (`attachments::draft`) | no |
| `AttachmentDraftTests.swift::testUncertainUploadCannotBeRetriedOrBecomeTranscriptSubmission` | An uncertain upload cannot be retried or submitted and keeps its uncertain state and bytes. | omnigent-core::attachments | `uncertain_upload_cannot_be_retried_or_become_transcript_submission` | inline | port | done (`attachments::draft`) | no |
| `AttachmentDraftTests.swift::testCancelInFlightPreservesBytesAndPreventsConcurrentDuplicateUpload` | Cancelling an in-flight upload keeps bytes and uncertain state; a concurrent duplicate upload is prevented. | omnigent-core::attachments | `cancel_in_flight_preserves_bytes_and_prevents_concurrent_duplicate_upload` | inline | port | done (`attachments::draft`; sans-IO: the host cancels and reports `TransportError::Cancelled`) | yes - async cancellation and progress semantics |
| `AttachmentDraftTests.swift::testTransportAndStoreKeepExactRefsAfterRejectedSendAndBlockUncertainRetry` | Denied submit keeps exact attachment refs for retry; uncertain network failure blocks retry; exactly one file POST and two event POSTs. | omnigent-core::attachments | `transport_and_store_keep_exact_refs_after_rejected_send_and_block_uncertain_retry` | attachments/AttachmentDraft--TransportAndStoreKeepExactRefsAfterRejectedSendAndBlockUncertainRetry.json | port | todo | yes - depends on WP5 client submitMessage transport |

### NativeLab: SubmissionLedgerTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `SubmissionLedgerTests.swift::testPendingSendRemainsBlockedWhenReconnectingToSameScope` | A pending send keeps its session blocked after reconnecting to the same scope but not in other scopes. | omnigent-core::ledger | `pending_send_remains_blocked_when_reconnecting_to_same_scope` | inline | port | done | no |
| `SubmissionLedgerTests.swift::testLateAcceptedCompletionClearsSameDraftInReconnectedScope` | A late accepted completion clears the draft in the reconnected scope. | omnigent-core::ledger | `late_accepted_completion_clears_same_draft_in_reconnected_scope` | inline | port | done | no |
| `SubmissionLedgerTests.swift::testLateAcceptedCompletionPreservesEditedDraft` | A late accepted completion keeps a draft the user edited meanwhile. | omnigent-core::ledger | `late_accepted_completion_preserves_edited_draft` | inline | port | done | no |
| `SubmissionLedgerTests.swift::testUncertainCompletionRetainsDraftAndBlocksAcrossScopeSwitchUntilReview` | Uncertain completion keeps the draft and blocks the session until acknowledged, across scope switches. | omnigent-core::ledger | `uncertain_completion_retains_draft_and_blocks_across_scope_switch_until_review` | inline | port | done | no |
| `SubmissionLedgerTests.swift::testRejectedCompletionRetainsDraftWithoutForcingAutomaticRetry` | A rejected send keeps the draft and unblocks it, with no automatic retry. | omnigent-core::ledger | `rejected_completion_retains_draft_without_forcing_automatic_retry` | inline | port | done | no |
| `SubmissionLedgerTests.swift::testDuplicateOldCompletionCannotFinishNewerOperation` | An old duplicate completion cannot finish a newer operation for the same session. | omnigent-core::ledger | `duplicate_old_completion_cannot_finish_newer_operation` | inline | port | done | no |
| `SubmissionLedgerTests.swift::testSameSessionIDOnOtherServerOrAccountHasIndependentDeliveryState` | The same session id on another server or account has independent delivery state. | omnigent-core::ledger | `same_session_id_on_other_server_or_account_has_independent_delivery_state` | inline | port | done | no |

### NativeLab: NativeNotificationTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `NativeNotificationTests.swift::testScopedRouteCanonicalizesOriginAndRejectsUntrustedNavigation` | Notification route canonicalizes the origin and rejects bad session ids, file/credentialed/query/encoded URLs. | omnigent-core::notifications | `scoped_route_canonicalizes_origin_and_rejects_untrusted_navigation` | inline | port | done (`notifications::route`) | no |
| `NativeNotificationTests.swift::testDedupPersistsAndScopesEveryIdentityComponent` | Notification dedupe persists across encode/decode and is scoped by server, user, workspace, session and event. | omnigent-core::notifications | `dedup_persists_and_scopes_every_identity_component` | inline | port | done (`notifications::route`) | no |
| `NativeNotificationTests.swift::testLedgerIsBoundedAndRetainsRecentEvents` | The dedupe ledger is bounded at 512 entries and still rejects recent events while evicting old ones. | omnigent-core::notifications | `ledger_is_bounded_and_retains_recent_events` | inline | port | done (`notifications::route`) | no |
| `NativeNotificationTests.swift::testLoopbackDevelopmentScopeIsExact` | Only exact 127.0.0.1 and [::1] loopback origins count as development; localhost and look-alike hosts do not. | omnigent-core::notifications | `loopback_development_scope_is_exact` | inline | port | done (`notifications::route`) | no |
| `NativeNotificationTests.swift::testHTTPRegistrationContractAndRedirectRejection` | Device registration is a PUT to the devices path with sorted unique session ids and no user id; redirects are rejected. | omnigent-core::notifications | `http_registration_contract_and_redirect_rejection` | inline | port | done (`notifications::push`; hosts never follow redirects, so the redirect case is a 3xx) | yes - HTTP client shared with WP5 transport |

### NativeLab: LocalServerSessionClientTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `LocalServerSessionClientTests.swift::testStructuredFormPostsTypedContentWithoutCoercion` | Typed form values resolve as accept with exact JSON types (string, number, bool, string array) | omnigent-core::decisions | `structured_form_posts_typed_content_without_coercion` | decisions/LocalServerSessionClient--StructuredFormPostsTypedContentWithoutCoercion.jsonl | port | done (`decisions::resolve`; the editable-session preflight GET is WP5) | no |
| `LocalServerSessionClientTests.swift::testInvalidStructuredFormDoesNotPostOrBecomeApproval` | Invalid typed forms (out-of-range, string for int, empty, approve) fail invalidDecision and never POST | omnigent-core::decisions | `invalid_structured_form_does_not_post_or_become_approval` | decisions/LocalServerSessionClient--InvalidStructuredFormDoesNotPostOrBecomeApproval.jsonl | port | done (`decisions::resolve`; the editable-session preflight GET is WP5) | no |
| `LocalServerSessionClientTests.swift::testExplicitPermissionResponsesMatchMainAppWire` | Four permission responses (allow-all-edits, remember, exit-plan decline with feedback, command policy) match the main-app content wire | omnigent-core::decisions | `explicit_permission_responses_match_main_app_wire` | decisions/LocalServerSessionClient--ExplicitPermissionResponsesMatchMainAppWire--allow-all-edits.jsonl; decisions/LocalServerSessionClient--ExplicitPermissionResponsesMatchMainAppWire--remember-scope.jsonl; decisions/LocalServerSessionClient--ExplicitPermissionResponsesMatchMainAppWire--exit-plan-mode.jsonl; decisions/LocalServerSessionClient--ExplicitPermissionResponsesMatchMainAppWire--command-policy.jsonl | port | done (`decisions::resolve`; the editable-session preflight GET is WP5) | no |
| `LocalServerSessionClientTests.swift::testUnadvertisedPermissionOptionsNeverPost` | Permission options absent from requestedSchema are rejected invalidDecision before any POST | omnigent-core::decisions | `unadvertised_permission_options_never_post` | decisions/LocalServerSessionClient--UnadvertisedPermissionOptionsNeverPost.jsonl | port | done (`decisions::resolve`; the editable-session preflight GET is WP5) | no |
| `LocalServerSessionClientTests.swift::testQuestionResolutionUsesRequestedAnswerKey` | A single-select question resolves as accept with content keyed by the requested field name | omnigent-core::decisions | `question_resolution_uses_requested_answer_key` | decisions/LocalServerSessionClient--QuestionResolutionUsesRequestedAnswerKey.jsonl | port | done (`decisions::resolve`; the editable-session preflight GET is WP5) | no |
| `LocalServerSessionClientTests.swift::testTypedQuestionNeverPostsBinaryApproval` | A typed question cannot be answered with a binary approve; no POST is made | omnigent-core::decisions | `typed_question_never_posts_binary_approval` | decisions/LocalServerSessionClient--TypedQuestionNeverPostsBinaryApproval.jsonl | port | done (`decisions::resolve`; the editable-session preflight GET is WP5) | no |

### NativeLab: LocalServerUploadTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `LocalServerUploadTests.swift::testUpload201UsesExactMultipartFieldBytesAndSafeSessionTransport` | Upload posts multipart with the escaped filename and exact bytes, returns the server file ID, and sends no auth, cookie or origin headers | omnigent-core::attachments | `upload201_uses_exact_multipart_field_bytes_and_safe_session_transport` | attachments/LocalServerUpload--Upload201UsesExactMultipartFieldBytesAndSafeSessionTransport.json; sessions/LocalServerUpload--_shared--session-summary.json | port | done (`attachments::upload`; the editable-session preflight GET is WP5) | no |
| `LocalServerUploadTests.swift::testMessageUsesUploadedRefsBeforeExactTextAndSupportsAttachmentsOnly` | Message content lists uploaded image and file refs before the exact text; an attachment-only message omits text | omnigent-core::attachments | `message_uses_uploaded_refs_before_exact_text_and_supports_attachments_only` | attachments/LocalServerUpload--MessageUsesUploadedRefsBeforeExactTextAndSupportsAttachmentsOnly.jsonl; sessions/LocalServerUpload--_shared--session-summary.json | port | todo | yes: upload plus message wire spans two modules |
| `LocalServerUploadTests.swift::testUploadFallbackFilenameMatchesWebContract` | When the upload response has no metadata filename, the requested filename is kept and a non-image is not treated as image | omnigent-core::attachments | `upload_fallback_filename_matches_web_contract` | attachments/LocalServerUpload--UploadFallbackFilenameMatchesWebContract.json; sessions/LocalServerUpload--_shared--session-summary.json | port | done (`attachments::upload`) | no |
| `LocalServerUploadTests.swift::testIndeterminateUploadFailuresDoNotRetryPOST` | Uncertain upload outcomes (500, bad body, wrong ID, transport loss, cancel, redirected URL) are uploadUncertain and not retried | omnigent-core::attachments | `indeterminate_upload_failures_do_not_retry_post` | attachments/LocalServerUpload--IndeterminateUploadFailuresDoNotRetryPOST.jsonl; sessions/LocalServerUpload--_shared--session-summary.json | port | done (`attachments::upload`; the redirected-URL case is a 3xx because hosts never follow redirects) | no |
| `LocalServerUploadTests.swift::testRejectedUploadCanBeReportedWithoutSendingTranscriptMessage` | 403, 413 and 415 uploads surface explicit errors; 401 revokes the connection; no transcript message is sent | omnigent-core::attachments | `rejected_upload_can_be_reported_without_sending_transcript_message` | attachments/LocalServerUpload--RejectedUploadCanBeReportedWithoutSendingTranscriptMessage.jsonl; sessions/LocalServerUpload--_shared--session-summary.json | port | done (`attachments::upload`; dropping the connection on `Unauthorized` is WP5) | no |
| `LocalServerUploadTests.swift::testPreflightBlocksWrongScopeReadOnlyArchiveAndUnreadyStreamWithoutPOST` | Upload and message are blocked before any POST for not-connected, bad ID, read-only, archived, unready stream, and foreign session or server refs | omnigent-core::attachments | `preflight_blocks_wrong_scope_read_only_archive_and_unready_stream_without_post` | sessions/LocalServerUpload--PreflightBlocksWrongScopeReadOnlyArchiveAndUnreadyStreamWithoutPOST--summaries.jsonl | port | todo | no |

### NativeLab: LocalAttachmentTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `LocalAttachmentTests.swift::testReferenceResolutionAcceptsOnlyExactSessionResources` | Only exact same-server, same-session resource references resolve to a file ID; other hosts, queries, fragments, traversal, data: and file: URLs do not | omnigent-core::attachments | `reference_resolution_accepts_only_exact_session_resources` | attachments/LocalAttachment--ReferenceResolutionAcceptsOnlyExactSessionResources.json | port | done (`attachments::preview`) | no |
| `LocalAttachmentTests.swift::testExplicitFetchUsesSessionResourceGETAndPreservesBytesWithoutCredentials` | Attachment fetch is a session-scoped GET that returns the exact bytes, png extension, and no credentials | omnigent-core::attachments | `explicit_fetch_uses_session_resource_get_and_preserves_bytes_without_credentials` | attachments/LocalAttachment--ExplicitFetchUsesSessionResourceGETAndPreservesBytesWithoutCredentials.json | port | done (`attachments::preview`) | no |
| `LocalAttachmentTests.swift::testDisconnectedAndMalformedIdentifiersMakeNoAttachmentRequests` | Fetch is refused when disconnected or given a malformed session or file ID, with no request | omnigent-core::attachments | `disconnected_and_malformed_identifiers_make_no_attachment_requests` | inline | port | partial (`attachments::preview`: malformed ids; the not-connected guard is WP5) | no |
| `LocalAttachmentTests.swift::testSupportedMIMETypesHaveFixedSafeExtensions` | 17 supported MIME types map to fixed safe extensions; charset parameters are ignored | omnigent-core::attachments | `supported_mime_types_have_fixed_safe_extensions` | attachments/LocalAttachment--SupportedMIMETypesHaveFixedSafeExtensions--mime-table.json | port | done (`attachments::preview`) | no |
| `LocalAttachmentTests.swift::testUnsupportedActiveOrUnknownMIMEIsRejected` | text/html, SVG, JavaScript, octet-stream and a missing MIME type are unsupportedMedia | omnigent-core::attachments | `unsupported_active_or_unknown_mime_is_rejected` | attachments/LocalAttachment--UnsupportedActiveOrUnknownMIMEIsRejected.jsonl | port | done (`attachments::preview`) | no |
| `LocalAttachmentTests.swift::testAdvertisedContentLengthOverLimitIsRejected` | A Content-Length above 10 MiB is rejected as tooLarge before the body is read | omnigent-core::attachments | `advertised_content_length_over_limit_is_rejected` | attachments/LocalAttachment--AdvertisedContentLengthOverLimitIsRejected.json | port | done (`attachments::preview`) | no |
| `LocalAttachmentTests.swift::testStreamingLengthLimitDoesNotTrustMissingContentLength` | A streamed body over 10 MiB with no Content-Length is rejected as tooLarge | omnigent-core::attachments | `streaming_length_limit_does_not_trust_missing_content_length` | attachments/LocalAttachment--StreamingLengthLimitDoesNotTrustMissingContentLength.json | port | done (`attachments::preview`) | no |
| `LocalAttachmentTests.swift::testRedirectsDifferentResponseOriginsAndHTTPFailuresAreExplicit` | 302, cross-origin response, 401, 403, 404 and 500 each map to an explicit error; 401 revokes reads until reconnect | omnigent-core::attachments | `redirects_different_response_origins_and_http_failures_are_explicit` | attachments/LocalAttachment--RedirectsDifferentResponseOriginsAndHTTPFailuresAreExplicit.jsonl | port | done (`attachments::preview`; cross-origin responses cannot occur without redirects; revoking reads after 401 is WP5) | no |

### NativeLab: HostedServerAuthenticationTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `HostedServerAuthenticationTests.swift::testMountedUploadCarriesBearerAndReturnedAttachmentIdentity` | Mounted upload carries the bearer; the returned attachment is bound to the server URL and user ID | omnigent-core::attachments | `mounted_upload_carries_bearer_and_returned_attachment_identity` | attachments/HostedServerAuthentication--MountedUploadCarriesBearerAndReturnedAttachmentIdentity.jsonl | port | todo | no |
| `HostedServerAuthenticationTests.swift::testUnauthorizedClearsConnectionAndMountedNotificationMutationUsesBearer` | Notification device DELETE carries the bearer; a 401 clears the connection | omnigent-core::notifications | `unauthorized_clears_connection_and_mounted_notification_mutation_uses_bearer` | inline | port | done (`notifications::push`; dropping the connection on `Unauthorized` is WP5) | no |
| `HostedServerAuthenticationTests.swift::testAttachmentReferencesStayWithinMountAndIdentity` | Attachment refs resolve only within this mount and account; other hosts, ports, query strings and other users are rejected | omnigent-core::attachments | `attachment_references_stay_within_mount_and_identity` | attachments/HostedServerAuthentication--AttachmentReferencesStayWithinMountAndIdentity.json | port | done (`attachments::upload`) | no |
| `HostedServerAuthenticationTests.swift::testNotificationScopeIncludesMountAndAccount` | NotificationScope normalizes the server URL and differs by mount and by user | omnigent-core::notifications | `notification_scope_includes_mount_and_account` | inline | port | done (`notifications::route`) | no |

### NativeLab: DatabricksRoutingTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `DatabricksRoutingTests.swift::testUploadsAndPreviewRequestsPreserveScopeAndRejectCrossOrgAttachments` | Upload and preview keep the org scope; an attachment from another org is rejected with no request | omnigent-core::attachments | `uploads_and_preview_requests_preserve_scope_and_reject_cross_org_attachments` | attachments/DatabricksRouting--UploadsAndPreviewRequestsPreserveScopeAndRejectCrossOrgAttachments.jsonl; sessions/DatabricksRouting--_shared--configure.jsonl | port | todo | yes: org auth scope plus attachments |
| `DatabricksRoutingTests.swift::testAttachmentReferencesResolveWithScopeQueryAndRejectDifferentOrg` | Attachment refs accept ?o=123 scope and reject ?o=456, duplicated or encoded org queries, and other hosts | omnigent-core::attachments | `attachment_references_resolve_with_scope_query_and_reject_different_org` | attachments/DatabricksRouting--AttachmentReferencesResolveWithScopeQueryAndRejectDifferentOrg.json | port | done (`attachments::preview`) | no |
| `DatabricksRoutingTests.swift::testBothNotificationClientsUseHeaderAndStripScopeQuery` | Both notification clients send the org header and strip the scope query on the unregister DELETE | omnigent-core::notifications | `both_notification_clients_use_header_and_strip_scope_query` | inline | port | done (`notifications::push`) | no |

### NativeLab: DemoSessionClientTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `DemoSessionClientTests.swift::testBinaryDecisionsResolveOnceAndPublish` | Approve or decline resolves once and publishes the decision; a second resolve is decisionAlreadyResolved | omnigent-core::decisions | `binary_decisions_resolve_once_and_publish` | inline | port | done (`decisions::ledger`; publishing the snapshot is WP5 `demo`) | no |
| `DemoSessionClientTests.swift::testQuestionRejectsUnknownAnswerAndBinaryResponsesThenAcceptsAnOption` | A question decision rejects unknown answers and binary responses; a listed option resolves once | omnigent-core::decisions | `question_rejects_unknown_answer_and_binary_responses_then_accepts_an_option` | inline | port | done (`decisions::ledger`) | no |
| `DemoSessionClientTests.swift::testDecisionCannotBeAnsweredThroughAnotherSessionOrWithWrongKind` | A decision cannot be answered through another session, with the wrong kind, or in a read-only session | omnigent-core::decisions | `decision_cannot_be_answered_through_another_session_or_with_wrong_kind` | inline | port | done (`decisions::ledger`; the read-only flag comes from the WP5 session) | no |

## WP5 sessions-client — tests

### NativeLab: MobileCoreTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `MobileCoreTests.swift::testQueriesSearchContextAndGroupPinsBeforeRecents` | Session list puts pinned sessions first, then recents; text search matches title, workspace, agent and preview with case folding. | omnigent-core::session_query (new) | `queries_search_context_and_group_pins_before_recents` | inline | port | todo | no |
| `MobileCoreTests.swift::testArchivedDecisionsStayInAttentionAndFiltersAreExclusive` | Archived sessions still needing a response stay in attention; running, needs-response and archived filters are exclusive. | omnigent-core::session_query (new) | `archived_decisions_stay_in_attention_and_filters_are_exclusive` | inline | port | todo | no |
| `MobileCoreTests.swift::testEqualTimestampsHaveStableOrdering` | Sessions with equal timestamps sort by id. | omnigent-core::session_query (new) | `equal_timestamps_have_stable_ordering` | inline | port | todo | no |
| `MobileCoreTests.swift::testRenamePinArchiveRestoreAndReadOnlyGuards` | Demo client renames (trimmed), pins and archives with a revision bump and no updatedAt change; sends fail when archived; read-only sessions reject edits. | omnigent-core::client | `rename_pin_archive_restore_and_read_only_guards` | sessions/DemoFixtures--demo-design.json, sessions/DemoFixtures--demo-notes.json | port | todo | yes - demo transport plus session-edit rules |
| `MobileCoreTests.swift::testInvalidRenameDoesNotMutateSession` | Blank or over-120-character titles are rejected and leave the session unchanged. | omnigent-core::client | `invalid_rename_does_not_mutate_session` | sessions/DemoFixtures--demo-design.json | port | todo | no |
| `MobileCoreTests.swift::testPersistenceRoundTripsOrganizationAndExactDrafts` | Workspace save/load round-trips snapshots and exact draft text (including unicode and newlines). | omnigent-core::workspace_store (new) | `persistence_round_trips_organization_and_exact_drafts` | sessions/DemoFixtures--demo-design.json | port | todo | yes - new persistence module |
| `MobileCoreTests.swift::testRecoveryPreservesPartialTextAndEndsStreaming` | On restart a running reply keeps partial text with a note, ends streaming, bumps revision and keeps drafts. | omnigent-core::workspace_store (new) | `recovery_preserves_partial_text_and_ends_streaming` | inline | port | todo | yes - recovery reuses WP3 streaming rules |
| `MobileCoreTests.swift::testRestartDoesNotReuseMessageOrSessionIDs` | After restart from saved snapshots, new message and session ids do not collide with old ones. | omnigent-core::client | `restart_does_not_reuse_message_or_session_i_ds` | inline | port | todo | no |
| `MobileCoreTests.swift::testCorruptOrFutureStoreThrowsAndLeavesFileUntouched` | A corrupt or future-version workspace file throws on load and is left byte-identical. | omnigent-core::workspace_store (new) | `corrupt_or_future_store_throws_and_leaves_file_untouched` | inline | port | todo | no |
| `MobileCoreTests.swift::testDuplicateSessionIDsAreRejectedByStore` | Saving then loading a workspace with duplicate session ids throws. | omnigent-core::workspace_store (new) | `duplicate_session_i_ds_are_rejected_by_store` | sessions/DemoFixtures--demo-design.json | port | todo | no |

### NativeLab: LocalServerSessionClientTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `LocalServerSessionClientTests.swift::testChangedFilesInvalidationFetchesSessionScopedDetailsWithoutPolling` | Invalidation does one session-scoped GET of changes, publishes file details, and sends no non-GET requests | omnigent-core::client | `changed_files_invalidation_fetches_session_scoped_details_without_polling` | sessions/LocalServerSessionClient--ChangedFilesInvalidationFetchesSessionScopedDetailsWithoutPolling.json | port | todo | yes: REST fetch plus reducer publish |
| `LocalServerSessionClientTests.swift::testChangedFilesFailureIsVisibleAndWrongSessionNeverFetches` | A failed changes fetch shows as unavailable in the files section; invalidation for another session makes no request | omnigent-core::client | `changed_files_failure_is_visible_and_wrong_session_never_fetches` | inline | port | todo | no |
| `LocalServerSessionClientTests.swift::testSubmitUsesRealMessageWireAndRetainsAcceptedQueueIdentity` | Message POST uses the exact message wire (input_text block) and keeps accepted item and pending IDs; no auth or cookie headers | omnigent-core::client | `submit_uses_real_message_wire_and_retains_accepted_queue_identity` | sessions/LocalServerSessionClient--SubmitUsesRealMessageWireAndRetainsAcceptedQueueIdentity.jsonl; sessions/LocalServerSessionClient--_shared--writable-session.json | port | todo | no |
| `LocalServerSessionClientTests.swift::testSendRequiresHydratedLiveStreamAndDoesNotRetryUncertainPOST` | Send is refused until the stream is hydrated; a lost POST is deliveryUncertain and never retried | omnigent-core::client | `send_requires_hydrated_live_stream_and_does_not_retry_uncertain_post` | sessions/LocalServerSessionClient--SendRequiresHydratedLiveStreamAndDoesNotRetryUncertainPOST.jsonl; sessions/LocalServerSessionClient--_shared--writable-session.json | port | todo | no |
| `LocalServerSessionClientTests.swift::testDeniedAndMalformedAcknowledgementsAreNotSuccess` | A denied acknowledgement is reported as denied; an empty acknowledgement is deliveryUncertain, not success | omnigent-core::client | `denied_and_malformed_acknowledgements_are_not_success` | sessions/LocalServerSessionClient--DeniedAndMalformedAcknowledgementsAreNotSuccess.jsonl | port | todo | no |
| `LocalServerSessionClientTests.swift::testInterruptUsesInterruptNotOwnerStopSession` | Interrupt posts type=interrupt to /events rather than an owner stop-session call | omnigent-core::client | `interrupt_uses_interrupt_not_owner_stop_session` | sessions/LocalServerSessionClient--InterruptUsesInterruptNotOwnerStopSession.json | port | todo | no |
| `LocalServerSessionClientTests.swift::testInventoryFollowsLaterPageAndWatchesPendingSessionOutsideVisiblePage` | Inventory follows has_more pages (limit 500, kind any, archived included) and finds a pending archived session off the visible page; the WS watch list includes it | omnigent-core::client | `inventory_follows_later_page_and_watches_pending_session_outside_visible_page` | sessions/LocalServerSessionClient--InventoryFollowsLaterPageAndWatchesPendingSessionOutsideVisiblePage--pages.jsonl; sessions/LocalServerSessionClient--InventoryFollowsLaterPageAndWatchesPendingSessionOutsideVisiblePage--conv-later.json; sessions/LocalServerSessionClient--InventoryFollowsLaterPageAndWatchesPendingSessionOutsideVisiblePage--ws.jsonl; items/LocalServerSessionClient--InventoryFollowsLaterPageAndWatchesPendingSessionOutsideVisiblePage--conv-later-items.json | port | todo | yes: paged REST inventory plus WS watch plus decisions |
| `LocalServerSessionClientTests.swift::testOptInLocalServerFixtureSmoke` | Against a seeded live server (env-gated), pages sessions with cursors and reads 60 history messages in order | omnigent-core::client | `opt_in_local_server_fixture_smoke` | inline | port (opt-in live server) | todo | yes: needs seeded live server |
| `LocalServerSessionClientTests.swift::testReadsRequireSuccessfulConnect` | sessions, conversation and history reads fail notConnected before connect, with no request | omnigent-core::client | `reads_require_successful_connect` | inline | port | todo | no |
| `LocalServerSessionClientTests.swift::testSessionPagesPreserveOrderAndReadOnlyMetadata` | Session page keeps server order, drops a repeated ID, derives read-only/pinned/status/title, and sends order, sort_by, limit, after and include_archived | omnigent-core::client | `session_pages_preserve_order_and_read_only_metadata` | sessions/LocalServerSessionClient--SessionPagesPreserveOrderAndReadOnlyMetadata--page1.json | port | todo | no |
| `LocalServerSessionClientTests.swift::testConversationPageLoadsMetadataAndLatestHistoryWithIncreasingRevisions` | Conversation page combines session metadata (include_items=false) with latest items; revisions increase; waiting maps to needsResponse and read-only | omnigent-core::client | `conversation_page_loads_metadata_and_latest_history_with_increasing_revisions` | sessions/LocalServerSessionClient--ConversationPageLoadsMetadataAndLatestHistoryWithIncreasingRevisions--session.json; items/LocalServerSessionClient--ConversationPageLoadsMetadataAndLatestHistoryWithIncreasingRevisions--items.json | port | todo | no |
| `LocalServerSessionClientTests.swift::testInvalidAndRepeatedPaginationCursorsFail` | has_more without a usable last_id, an empty last_id, or a cursor that repeats fails invalidPagination | omnigent-core::client | `invalid_and_repeated_pagination_cursors_fail` | sessions/LocalServerSessionClient--InvalidAndRepeatedPaginationCursorsFail.jsonl | port | todo | no |
| `LocalServerSessionClientTests.swift::testStatusFailuresAndRedirectResponsesAreExplicit` | 301/302 map to redirectNotAllowed; 401, 403, 404, 500 and 204 each map to a distinct explicit error | omnigent-core::client | `status_failures_and_redirect_responses_are_explicit` | inline | port | todo | no |
| `LocalServerSessionClientTests.swift::testResponseFromDifferentURLIsRejected` | A response whose final URL differs from the request is rejected as redirectNotAllowed | omnigent-core::client | `response_from_different_url_is_rejected` | inline | port | todo | no |
| `LocalServerSessionClientTests.swift::testTransportFailureAndCancellationAreDistinct` | Transport errors, auth-required URL errors and cancellation map to three distinct errors | omnigent-core::client | `transport_failure_and_cancellation_are_distinct` | inline | port | todo | no |
| `LocalServerSessionClientTests.swift::testAuthenticationLossRevokesReadAccessUntilReconnected` | A 401 on a read clears the connection; later reads fail notConnected until reconnect | omnigent-core::client | `authentication_loss_revokes_read_access_until_reconnected` | inline | port | todo | no |
| `LocalServerSessionClientTests.swift::testInvalidIdentifiersAndLimitsNeverMakeResourceRequests` | Invalid session IDs and page limits (0, -1, 1001) or an empty cursor are rejected with no resource request | omnigent-core::client | `invalid_identifiers_and_limits_never_make_resource_requests` | inline | port | todo | no |
| `LocalServerSessionClientTests.swift::testReadOnlyPermissionPreventsMutationRequests` | Permission level 1 blocks send, interrupt, resolve, rename and archive as readOnly; only GETs go out; createSession needs a host | omnigent-core::client | `read_only_permission_prevents_mutation_requests` | sessions/LocalServerSessionClient--ReadOnlyPermissionPreventsMutationRequests.json | port | todo | no |

### NativeLab: HostedServerAuthenticationTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `HostedServerAuthenticationTests.swift::testDisconnectDiscardsInFlightInventory` | Disconnect while the session inventory request is in flight discards it (notConnected, zero summaries) | omnigent-core::client | `disconnect_discards_in_flight_inventory` | sessions/HostedServerAuthentication--DisconnectDiscardsInFlightInventory.json | port | todo | no |

### NativeLab: DemoSessionClientTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `DemoSessionClientTests.swift::testInitialUpdatesIncludeEverySessionAndNewSessionsArePublished` | Initial updates publish every demo session; create trims the title and publishes it; a blank title becomes 'New conversation' | omnigent-core::client | `initial_updates_include_every_session_and_new_sessions_are_published` | inline | port | todo | no |
| `DemoSessionClientTests.swift::testSendConstraintsLeaveExistingStateUnchanged` | Send to a read-only session, a session awaiting a decision, or with empty input fails and leaves state unchanged | omnigent-core::client | `send_constraints_leave_existing_state_unchanged` | inline | port | todo | no |
| `DemoSessionClientTests.swift::testReplyStreamsIncreasingRevisionsAndFinishesInItsOwnSession` | Demo reply streams increasing revisions and finishes only in its own session with the sample reply text | omnigent-core::client | `reply_streams_increasing_revisions_and_finishes_in_its_own_session` | inline | port | todo | yes: streamed revisions also feed the reducer |
| `DemoSessionClientTests.swift::testInterruptCancelsReplyAndDoesNotChangeAnotherRunningSession` | Interrupt stops only that session's reply ('Reply stopped.'); a second send to a running session is busy | omnigent-core::client | `interrupt_cancels_reply_and_does_not_change_another_running_session` | inline | port | todo | no |
| `DemoSessionClientTests.swift::testCancellingSubscriberRemovesItsContinuation` | Cancelling an updates subscriber removes its continuation (count 1, then 0) | omnigent-core::client | `cancelling_subscriber_removes_its_continuation` | inline | port | todo | no |
| `DemoSessionClientTests.swift::testUnknownSessionOperationsFailWithoutCreatingState` | Conversation, send, interrupt and resolve on an unknown session fail sessionNotFound and create no state | omnigent-core::client | `unknown_session_operations_fail_without_creating_state` | inline | port | todo | no |

### NativeLab: SessionCreationTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `SessionCreationTests.swift::testOnlyExplicitReadinessAllowsCreation` | Only explicit ready harness readiness allows creation; not-ready, unknown and needs-auth block, with a sign-in reason | omnigent-core::creation | `only_explicit_readiness_allows_creation` | inline | port | todo | no |
| `SessionCreationTests.swift::testOfflineManagedUnknownHarnessAndMissingReadinessAreUnavailable` | Offline hosts, managed sandbox hosts, unconfigured hosts, and unknown or future harnesses are unavailable | omnigent-core::creation | `offline_managed_unknown_harness_and_missing_readiness_are_unavailable` | inline | port | todo | no |
| `SessionCreationTests.swift::testWorkspaceAndModelAreValidatedWithoutGuessing` | Workspace must be an absolute path without NUL or ~; model must be an advertised, non-hidden wire value, not its ID | omnigent-core::creation | `workspace_and_model_are_validated_without_guessing` | inline | port | todo | no |
| `SessionCreationTests.swift::testCanonicalNativeAliasesPreserveWrapperContract` | Six native harness IDs map to their fixed wrapper names | omnigent-core::creation | `canonical_native_aliases_preserve_wrapper_contract` | inline | port | todo | no |
| `SessionCreationTests.swift::testCatalogPaginatesAndDeduplicatesDurableAgentIDs` | Agent catalog follows the after-cursor and dedupes repeated durable agent IDs; only GETs are sent | omnigent-core::client | `catalog_paginates_and_deduplicates_durable_agent_i_ds` | sessions/SessionCreation--CatalogPaginatesAndDeduplicatesDurableAgentIDs.jsonl | port | todo | no |
| `SessionCreationTests.swift::testDirectoryPaginationUsesPathAndDoesNotOfferFiles` | Directory listing pages by path cursor and offers only absolute directories, never files | omnigent-core::client | `directory_pagination_uses_path_and_does_not_offer_files` | sessions/SessionCreation--DirectoryPaginationUsesPathAndDoesNotOfferFiles.jsonl | port | todo | no |
| `SessionCreationTests.swift::testRepeatedDirectoryCursorStopsInsteadOfLooping` | A directory listing whose cursor does not advance fails invalidPagination | omnigent-core::client | `repeated_directory_cursor_stops_instead_of_looping` | sessions/SessionCreation--RepeatedDirectoryCursorStopsInsteadOfLooping.json | port | todo | no |
| `SessionCreationTests.swift::test201PostsExactExternalHostContractWithoutInitialPrompt` | Creation POSTs the exact external-host body (trimmed workspace and title, model override, UI and wrapper labels) with no auth header and no events POST | omnigent-core::client | `posts_201_exact_external_host_contract_without_initial_prompt` | sessions/SessionCreation--201PostsExactExternalHostContractWithoutInitialPrompt.json; sessions/SessionCreation--_shared--hosts.json; sessions/SessionCreation--_shared--agents.json; sessions/SessionCreation--_shared--model-options.json | port | todo | no |
| `SessionCreationTests.swift::testDefaultsOmitModelAndBlankTitle` | Default creation omits model_override, title, initial_items, harness_override and launch args, and skips the model-options fetch | omnigent-core::client | `defaults_omit_model_and_blank_title` | sessions/SessionCreation--DefaultsOmitModelAndBlankTitle.json | port | todo | no |
| `SessionCreationTests.swift::testReadinessAndModelAreRevalidatedImmediatelyBeforePost` | Readiness is re-fetched right before the POST; a host that went offline blocks creation with no POST | omnigent-core::creation | `readiness_and_model_are_revalidated_immediately_before_post` | sessions/SessionCreation--ReadinessAndModelAreRevalidatedImmediatelyBeforePost.json; sessions/SessionCreation--_shared--hosts.json; sessions/SessionCreation--_shared--agents.json | port | todo | no |
| `SessionCreationTests.swift::testUnadvertisedModelBlocksPostButDefaultNeedsNoModelCatalog` | A hidden or unadvertised model blocks creation; the default selection needs no model catalog | omnigent-core::creation | `unadvertised_model_blocks_post_but_default_needs_no_model_catalog` | sessions/SessionCreation--UnadvertisedModelBlocksPostButDefaultNeedsNoModelCatalog.json | port | todo | no |
| `SessionCreationTests.swift::testAcceptedIDSurvivesUnknownSnapshotShapeAndFailedHydration` | A 201 with an unknown status keeps the accepted ID with a nil summary; failed hydration does not resubmit | omnigent-core::client | `accepted_id_survives_unknown_snapshot_shape_and_failed_hydration` | sessions/SessionCreation--AcceptedIDSurvivesUnknownSnapshotShapeAndFailedHydration.json | port | todo | no |
| `SessionCreationTests.swift::testUncertainWritesAreNeverAutomaticallyRetried` | Eleven uncertain POST outcomes (transport loss, timeout, proxy HTML, 5xx, 409, 404, 403, 302, bad ID) are uncertain and the POST is never retried | omnigent-core::client | `uncertain_writes_are_never_automatically_retried` | sessions/SessionCreation--UncertainWritesAreNeverAutomaticallyRetried.jsonl | port | todo | no |
| `SessionCreationTests.swift::testValidationRejectionProvidesServerExplanation` | A 400 creation rejection surfaces the server error message | omnigent-core::client | `validation_rejection_provides_server_explanation` | sessions/SessionCreation--ValidationRejectionProvidesServerExplanation.json | port | todo | no |

### NativeLab: SessionConfigurationTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `SessionConfigurationTests.swift::testMissingIdentifiersAreNotDefaultsOrModelMatches` | Missing harness, model and effort show 'not reported'; explicit nulls show 'Harness default'; a nil ID never matches | omnigent-core::config::session | `missing_identifiers_are_not_defaults_or_model_matches` | sessions/SessionConfiguration--MissingIdentifiersAreNotDefaultsOrModelMatches--missing.json; sessions/SessionConfiguration--MissingIdentifiersAreNotDefaultsOrModelMatches--cleared.json | port | todo | no |
| `SessionConfigurationTests.swift::testUnknownIDsRemainVisibleAndUnchangedSelectionIsValid` | Unknown harness, model and effort IDs stay visible as labels, and an unchanged selection validates | omnigent-core::config::session | `unknown_i_ds_remain_visible_and_unchanged_selection_is_valid` | inline | port | todo | no |
| `SessionConfigurationTests.swift::testDefaultEffortUsesRunnerDefaultNotAgentSpecModel` | Effort choices come from the selected model or the runner default; an unadvertised model offers none | omnigent-core::config::session | `default_effort_uses_runner_default_not_agent_spec_model` | inline | port | todo | no |
| `SessionConfigurationTests.swift::testSelectingModelClearsOnlyUnsupportedEffort` | Selecting a model clears only the effort it does not support; an unsupported effort fails validation | omnigent-core::config::session | `selecting_model_clears_only_unsupported_effort` | inline | port | todo | no |
| `SessionConfigurationTests.swift::testHiddenAndUnknownModelsCannotBeNewSelections` | Hidden or unknown models cannot be newly selected, but a current hidden override is kept; smart routing shows its own label | omnigent-core::config::session | `hidden_and_unknown_models_cannot_be_new_selections` | inline | port | todo | no |
| `SessionConfigurationTests.swift::testCatalogChangesRevalidateChoicesButDoNotInventSelectionConflict` | A catalog removal revalidates the edit without inventing a conflict; a changed effort gives changedElsewhere | omnigent-core::config::session | `catalog_changes_revalidate_choices_but_do_not_invent_selection_conflict` | inline | port | todo | no |
| `SessionConfigurationTests.swift::testHarnessAndHostChangesDoNotBorrowStaleCapabilities` | A harness or host change drops the old model, wrapper and liveness capabilities | omnigent-core::config::session | `harness_and_host_changes_do_not_borrow_stale_capabilities` | sessions/SessionConfiguration--HarnessAndHostChangesDoNotBorrowStaleCapabilities.json | port | todo | no |
| `SessionConfigurationTests.swift::testConfigurationFlagsDecodeFromOlderSavedConfiguration` | A saved configuration without modelReported or effortReported still decodes; effort reported is nil | omnigent-core::config::session | `configuration_flags_decode_from_older_saved_configuration` | sessions/SessionConfiguration--ConfigurationFlagsDecodeFromOlderSavedConfiguration.json | port | todo | no |
| `SessionConfigurationTests.swift::testHarnessSafetyRequiresCorrectOnlineConfiguredHostAndHistorySupport` | A harness switch target must be built-in, on the same host, online, configured, not a child, and not the current harness | omnigent-core::config::session | `harness_safety_requires_correct_online_configured_host_and_history_support` | inline | port | todo | no |
| `SessionConfigurationTests.swift::testProviderFamiliesMatchBackendCarrySettingsPolicy` | Harness IDs map to openai, anthropic or gemini provider families per backend policy; unknown IDs map to nil | omnigent-core::config::session | `provider_families_match_backend_carry_settings_policy` | inline | port | todo | no |
| `SessionConfigurationTests.swift::testModelAndEffortPatchAreOrderedAndUseExplicitResetSentinels` | Model PATCH then effort PATCH, in order, with a 'default' sentinel for reset; a re-GET between them | omnigent-core::config::session | `model_and_effort_patch_are_ordered_and_use_explicit_reset_sentinels` | sessions/SessionConfiguration--ModelAndEffortPatchAreOrderedAndUseExplicitResetSentinels.jsonl | port | todo | no |
| `SessionConfigurationTests.swift::testBusyReadOnlyArchivedOfflineAndUnstreamedSessionsNeverPatch` | Running, read-only, archived, offline or pending sessions, and an unstreamed client, never PATCH | omnigent-core::config::session | `busy_read_only_archived_offline_and_unstreamed_sessions_never_patch` | sessions/SessionConfiguration--BusyReadOnlyArchivedOfflineAndUnstreamedSessionsNeverPatch.jsonl | port | todo | no |
| `SessionConfigurationTests.swift::testChangedSelectionAndRemovedCatalogOptionNeverPatch` | An externally changed model or a removed catalog option blocks the PATCH | omnigent-core::config::session | `changed_selection_and_removed_catalog_option_never_patch` | sessions/SessionConfiguration--ChangedSelectionAndRemovedCatalogOptionNeverPatch.jsonl | port | todo | no |
| `SessionConfigurationTests.swift::testUncertainModelPatchIsNeverRetriedOrFollowedByEffortPatch` | A transport loss on the model PATCH is deliveryUncertain, is not retried, and no effort PATCH follows | omnigent-core::config::session | `uncertain_model_patch_is_never_retried_or_followed_by_effort_patch` | sessions/SessionConfiguration--UncertainModelPatchIsNeverRetriedOrFollowedByEffortPatch.jsonl | port | todo | no |
| `SessionConfigurationTests.swift::testPartialSuccessRequiresReviewWhenSecondWriteFails` | Model PATCH succeeds and the effort PATCH returns 403, reported as deliveryUncertain (partial) needing review | omnigent-core::config::session | `partial_success_requires_review_when_second_write_fails` | sessions/SessionConfiguration--PartialSuccessRequiresReviewWhenSecondWriteFails.jsonl | port | todo | no |
| `SessionConfigurationTests.swift::testUnacknowledgedAndMalformedMutationSnapshotsAreUncertain` | PATCH responses that lack the requested change, carry an unknown status, or are empty are deliveryUncertain | omnigent-core::config::session | `unacknowledged_and_malformed_mutation_snapshots_are_uncertain` | sessions/SessionConfiguration--UnacknowledgedAndMalformedMutationSnapshotsAreUncertain.jsonl | port | todo | no |
| `SessionConfigurationTests.swift::testHarnessSwitchRetainsSessionAndChecksTargetAcknowledgement` | Harness switch POSTs switch-agent with the target agent, keeps the session ID, clears the model, and requires target acknowledgement | omnigent-core::config::session | `harness_switch_retains_session_and_checks_target_acknowledgement` | sessions/SessionConfiguration--HarnessSwitchRetainsSessionAndChecksTargetAcknowledgement.jsonl | port | todo | yes: catalog reads plus switch mutation |
| `SessionConfigurationTests.swift::testDemoUpgradeAndNewSessionsPublishReportedConfiguration` | Upgraded and new demo sessions publish the demo configuration; configure keeps messages | omnigent-core::config::session | `demo_upgrade_and_new_sessions_publish_reported_configuration` | inline | port | todo | no |
| `SessionConfigurationTests.swift::testHostPreviewStaysSeparateAndCannotFollowAnotherHarness` | Host model-options preview stays separate from confirmed metadata and does not follow a different harness; no PATCH | omnigent-core::config::session | `host_preview_stays_separate_and_cannot_follow_another_harness` | sessions/SessionConfiguration--HostPreviewStaysSeparateAndCannotFollowAnotherHarness.jsonl | port | todo | yes: host preview plus harness catalog |
| `SessionConfigurationTests.swift::testHostPreviewFailureDoesNotHideHarnessCatalog` | A host model-options 502 is recorded as modelOptionsError while harness agents still load | omnigent-core::config::session | `host_preview_failure_does_not_hide_harness_catalog` | sessions/SessionConfiguration--HostPreviewFailureDoesNotHideHarnessCatalog.jsonl | port | todo | no |
| `SessionConfigurationTests.swift::testApplyRevalidatesHostPreviewBeforeAnyWrite` | Apply re-checks the host model preview; a model removed from it is rejected before any PATCH | omnigent-core::config::session | `apply_revalidates_host_preview_before_any_write` | sessions/SessionConfiguration--ApplyRevalidatesHostPreviewBeforeAnyWrite.jsonl | port | todo | no |
| `SessionConfigurationTests.swift::testChangedEventDuringMutationUsesFreshAcknowledgementNotStaleResponse` | An external model event during the PATCH makes the outcome deliveryUncertain and keeps the fresh external model | omnigent-core::config::session | `changed_event_during_mutation_uses_fresh_acknowledgement_not_stale_response` | sessions/SessionConfiguration--ChangedEventDuringMutationUsesFreshAcknowledgementNotStaleResponse.jsonl; sse/SessionConfiguration--ChangedEventDuringMutationUsesFreshAcknowledgementNotStaleResponse--event.jsonl | port | todo | yes: concurrent stream event plus PATCH |
| `SessionConfigurationTests.swift::testConcurrentConfigurationMutationIsRejectedBeforeSecondWrite` | A second configuration apply while one is in flight is rejected busy before any second PATCH | omnigent-core::config::session | `concurrent_configuration_mutation_is_rejected_before_second_write` | sessions/SessionConfiguration--ConcurrentConfigurationMutationIsRejectedBeforeSecondWrite.jsonl | port | todo | no |
| `SessionConfigurationTests.swift::testMetadataVersionRejectsOlderCallbacksWithoutChangingConversationIdentity` | Older metadata revisions cannot replace newer ones; metadata for a different session is ignored | omnigent-core::config::session | `metadata_version_rejects_older_callbacks_without_changing_conversation_identity` | inline | port | todo | no |

### NativeLab: SessionExecutionReadinessTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `SessionExecutionReadinessTests.swift::testReadinessUsesExecutionMetadataRatherThanHarnessOrPermissions` | Readiness follows execution metadata (runner and host liveness, resumability), not harness or permission, across 15 scenarios | omnigent-core::config::session | `readiness_uses_execution_metadata_rather_than_harness_or_permissions` | sessions/SessionExecutionReadiness--ReadinessUsesExecutionMetadataRatherThanHarnessOrPermissions.json | port | todo | no |
| `SessionExecutionReadinessTests.swift::testSparseProjectionKeepsNoConnectionReasonAndWritePermissions` | A sparse projection without permission keeps the no-connection reason and write access | omnigent-core::config::session | `sparse_projection_keeps_no_connection_reason_and_write_permissions` | sessions/SessionExecutionReadiness--SparseProjectionKeepsNoConnectionReasonAndWritePermissions.json | port | todo | no |
| `SessionExecutionReadinessTests.swift::testSparseProjectionPreservesManagedResumeButExplicitFalseDisablesIt` | A sparse runner update keeps managed resumability; an explicit host_resumable false disables it | omnigent-core::config::session | `sparse_projection_preserves_managed_resume_but_explicit_false_disables_it` | sessions/SessionExecutionReadiness--SparseProjectionPreservesManagedResumeButExplicitFalseDisablesIt.json | port | todo | no |
| `SessionExecutionReadinessTests.swift::testExplicitNullClearsResumeAndChangingHostsClearsOldLiveness` | An explicit null clears resumability; changing or unbinding the host clears the old liveness | omnigent-core::config::session | `explicit_null_clears_resume_and_changing_hosts_clears_old_liveness` | sessions/SessionExecutionReadiness--ExplicitNullClearsResumeAndChangingHostsClearsOldLiveness.json | port | todo | no |
| `SessionExecutionReadinessTests.swift::testHarnessChangeDoesNotEraseSessionExecutionMetadata` | A harness change keeps host and runner liveness and resumability | omnigent-core::config::session | `harness_change_does_not_erase_session_execution_metadata` | sessions/SessionExecutionReadiness--HarnessChangeDoesNotEraseSessionExecutionMetadata.json | port | todo | no |
| `SessionExecutionReadinessTests.swift::testOlderSavedConfigurationWithoutResumabilityRemainsDecodable` | An older saved configuration without hostResumable still decodes with a nil unavailable reason | omnigent-core::config::session | `older_saved_configuration_without_resumability_remains_decodable` | sessions/SessionExecutionReadiness--OlderSavedConfigurationWithoutResumabilityRemainsDecodable.json | port | todo | no |
| `SessionExecutionReadinessTests.swift::testUnboundFailedSessionKeepsFailureHistorySeparateFromReadiness` | A failed unbound session keeps its failure message separate from the no-connection readiness and stays writable | omnigent-core::config::session | `unbound_failed_session_keeps_failure_history_separate_from_readiness` | sessions/SessionExecutionReadiness--UnboundFailedSessionKeepsFailureHistorySeparateFromReadiness.json | port | todo | no |
| `SessionExecutionReadinessTests.swift::testUnavailableSessionNeverPostsTextOrAttachmentMessage` | Unavailable sessions reject text and attachment sends with executionUnavailable and never POST | omnigent-core::config::session | `unavailable_session_never_posts_text_or_attachment_message` | sessions/SessionExecutionReadiness--UnavailableSessionNeverPostsTextOrAttachmentMessage.jsonl | port | todo | no |
| `SessionExecutionReadinessTests.swift::testConnectedHostAndWakeableHostAllowStoppedRunnerSubmissions` | A connected or wakeable host lets a message POST queue while the runner is stopped | omnigent-core::client | `connected_host_and_wakeable_host_allow_stopped_runner_submissions` | sessions/SessionExecutionReadiness--ConnectedHostAndWakeableHostAllowStoppedRunnerSubmissions.jsonl | port | todo | no |

### web/ios: DatabricksSessionClientTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `DatabricksSessionClientTests.swift::testCreatesSessionAndSendsScopedCookiesWithoutForwardingBearer` | Create sends Bearer to session endpoint, gets DBAUTH cookie, page request sends cookie only | omnigent-core::client | `session_create_sends_bearer_then_cookie_only` | session/create-302-set-cookie.json (proposed) | port + mock HTTP | todo | no |
| `DatabricksSessionClientTests.swift::testCanonicalToSharedHostRedirectKeepsDomainAndWorkspaceContext` | Redirect from canonical to shared host keeps workspace context, cookie domain and page fragment | omnigent-core::client | `session_redirect_canonical_to_shared_host_keeps_context` | session/create-302-shared-host.json (proposed) | port + mock HTTP | todo | no |
| `DatabricksSessionClientTests.swift::testWorkspaceTokenUsesIssuerOriginButAccountTokenUsesChosenOrigin` | Workspace-issuer token uses issuer origin; account-issuer token uses the chosen origin | omnigent-core::client | `session_issuer_origin_choice_workspace_vs_account` | session/create-302-set-cookie.json (proposed) | port + mock HTTP | todo | no |
| `DatabricksSessionClientTests.swift::testAccountGrantWithoutWorkspaceContextDoesNotChooseADefaultWorkspace` | Account grant with no workspace context fails with workspaceRequired; no request sent | omnigent-core::client | `session_account_grant_requires_workspace_context` | inline | port | todo | no |
| `DatabricksSessionClientTests.swift::testBlocksUnsafeRedirectsAndWorkspaceChanges` | Off-origin, http, protocol-relative redirects give unsafeRedirect; changed o= gives workspaceChanged | omnigent-core::client | `session_blocks_unsafe_redirects_and_workspace_changes` | inline | port + mock HTTP | todo | no |
| `DatabricksSessionClientTests.swift::testRedirectLoopIsBounded` | Redirect loop stops after 9 total requests with unsafeRedirect | omnigent-core::client | `session_redirect_loop_bounded_at_nine_requests` | inline | port + mock HTTP | todo | no |
| `DatabricksSessionClientTests.swift::testMissingExpiredAndInsecureSessionCookiesFailClosed` | Missing, empty, expired, non-Secure or non-HttpOnly DBAUTH cookie fails with missingCookie or unsafeCookie | omnigent-core::client | `session_missing_expired_insecure_cookie_fails_closed` | session/cookie-*.json (proposed) | port + mock HTTP | todo | no |
| `DatabricksSessionClientTests.swift::testExpiredDeletionCookieCanPrecedeFreshSession` | Max-Age=0 deletion cookie before a fresh cookie does not block session | omnigent-core::client | `session_expired_deletion_cookie_precedes_fresh` | session/cookie-deletion-then-fresh.json (proposed) | port + mock HTTP | todo | no |
| `DatabricksSessionClientTests.swift::testRejectsCookieDomainWideningAndMatchesCookiePaths` | Cookie domain widening rejected as unsafeCookie; cookie path matching respects segment boundaries | omnigent-core::client | `session_cookie_domain_widening_rejected_and_path_match` | inline | port | todo | no |
| `DatabricksSessionClientTests.swift::testErrorStatusAndLoginPageAreNotSuccessfulSessions` | 401, 403, 500 give rejected(status); redirect to /login gives unexpectedLanding | omnigent-core::client | `session_error_status_and_login_landing_not_success` | inline | port + mock HTTP | todo | no |

## WP6 auth-config — tests

### NativeLab: LocalServerSessionClientTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `LocalServerSessionClientTests.swift::testHTTPRequiresLiteralLoopbackRoots` | Only literal loopback http roots (127.0.0.1 or [::1], no userinfo, path, query, fragment; valid port) are accepted (server_url.rs) | omnigent-core::auth::endpoint | `http_requires_literal_loopback_roots` | inline | port | done | no |
| `LocalServerSessionClientTests.swift::testConnectVerifiesDiscoveryAndIdentityWithoutCredentials` | connect GETs /v1/info then /v1/me with no auth header, cookie or body | omnigent-core::auth::hosted | `connect_verifies_discovery_and_identity_without_credentials` | sessions/LocalServerSessionClient--_shared--info.json; sessions/LocalServerSessionClient--_shared--me.json | port | done | no |
| `LocalServerSessionClientTests.swift::testUnsupportedAuthenticationFailsClosed` | Discovery that is neither single-user-only nor accounts-only fails unsupportedAuthentication and blocks reads | omnigent-core::auth::hosted | `unsupported_authentication_fails_closed` | sessions/LocalServerSessionClient--UnsupportedAuthenticationFailsClosed.jsonl | port | done | no |
| `LocalServerSessionClientTests.swift::testMissingOrDifferentIdentityFailsClosed` | A null, missing or mismatched /v1/me user_id fails identityUnavailable and blocks reads | omnigent-core::auth::hosted | `missing_or_different_identity_fails_closed` | sessions/LocalServerSessionClient--MissingOrDifferentIdentityFailsClosed.jsonl | port | done | no |

### NativeLab: HostedServerAuthenticationTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `HostedServerAuthenticationTests.swift::testPublicConnectionStateBecomesFalseAfter401` | A 401 on sessions flips the public connection state to false and blocks later requests | omnigent-core::auth::hosted | `public_connection_state_becomes_false_after401` | sessions/HostedServerAuthentication--_shared--hosted-configure.jsonl; sessions/HostedServerAuthentication--PublicConnectionStateBecomesFalseAfter401.json | port | done | no |
| `HostedServerAuthenticationTests.swift::testHostedProxyConfirmsIdentityAndScopesEveryRequestToMountedAPI` | Hosted proxy confirms identity and sends every request under /api/2.0/omnigent with Bearer and no cookie or forwarded-email header | omnigent-core::auth::hosted | `hosted_proxy_confirms_identity_and_scopes_every_request_to_mounted_api` | sessions/HostedServerAuthentication--_shared--hosted-configure.jsonl | port | done | no |
| `HostedServerAuthenticationTests.swift::testBearerHeaderAndMountApplyToSSEWebSocketUploadConfigurationAndNotifications` | Bearer header and mount prefix apply to stream, file, configuration and notification paths; WebSocket uses wss | omnigent-core::auth::endpoint | `bearer_header_and_mount_apply_to_sse_web_socket_upload_configuration_and_notifications` | inline | port | done | no |
| `HostedServerAuthenticationTests.swift::testHostedConnectionsRequireBearerAndNonemptyConfirmedIdentity` | No bearer fails unauthorized before /me; null or blank /me user_id fails identityUnavailable | omnigent-core::auth::hosted | `hosted_connections_require_bearer_and_nonempty_confirmed_identity` | sessions/HostedServerAuthentication--HostedConnectionsRequireBearerAndNonemptyConfirmedIdentity.jsonl | port | done | no |
| `HostedServerAuthenticationTests.swift::testHostedSingleUserFallbackIsNotMistakenForBearerAuthentication` | Single-user discovery on a hosted server with bearer is unsupportedAuthentication after one request | omnigent-core::auth::hosted | `hosted_single_user_fallback_is_not_mistaken_for_bearer_authentication` | sessions/HostedServerAuthentication--HostedSingleUserFallbackIsNotMistakenForBearerAuthentication.json | port | done | no |
| `HostedServerAuthenticationTests.swift::testExpectedIdentityAndReconnectPinningRejectDifferentAccounts` | Expected user ID and reconnect pinning reject a different account with identityMismatch | omnigent-core::auth::hosted | `expected_identity_and_reconnect_pinning_reject_different_accounts` | sessions/HostedServerAuthentication--ExpectedIdentityAndReconnectPinningRejectDifferentAccounts.jsonl | port | done | no |
| `HostedServerAuthenticationTests.swift::testEndpointRejectsUnsafeURLsAndCanonicalizesMount` | ServerEndpoint canonicalizes host, port and trailing slash; rejects http, userinfo, query, fragment, dot-segments, encoded slash, and empty or padded bearer tokens | omnigent-core::auth::endpoint | `endpoint_rejects_unsafe_ur_ls_and_canonicalizes_mount` | inline | port | done | no |
| `HostedServerAuthenticationTests.swift::testAccountLoginUsesActualContractAndDoesNotCarryAmbientCredentials` | Account login POSTs username and password to the login path, returns token and expiry, and the credential is redacted in reflection | omnigent-core::auth::accounts | `account_login_uses_actual_contract_and_does_not_carry_ambient_credentials` | inline | port | done | no |
| `HostedServerAuthenticationTests.swift::testProxyDiscoveryNeverTurnsIntoPasswordOrOIDCLogin` | Proxy-mode discovery exposes no password or browser login; a 401 on discovery is unauthorized | omnigent-core::auth::ticket | `proxy_discovery_never_turns_into_password_or_oidc_login` | inline | port | done | no |
| `HostedServerAuthenticationTests.swift::testOIDCBrowserTicketPendingSuccessExpiryAndServerScope` | OIDC ticket: the login URL is server-scoped; poll returns pending then the token; cross-origin poll is rejected; 410 is expired | omnigent-core::auth::ticket | `oidc_browser_ticket_pending_success_expiry_and_server_scope` | inline | port | done (PKCE ticket, D1) | no |
| `HostedServerAuthenticationTests.swift::testOIDCRejectsUntrustedBrowserURLsAndAPIRedirects` | Untrusted browser login URLs (other host, protocol-relative, extra return_to, different ticket) and API redirects are rejected | omnigent-core::auth::ticket | `oidc_rejects_untrusted_browser_ur_ls_and_api_redirects` | inline | port | done (PKCE ticket, D1) | no |
| `HostedServerAuthenticationTests.swift::testDelegateRejectsRedirectAndUsesPlatformTLSValidation` | URLSession delegate cancels redirects and defers only server-trust challenges to the platform | omnigent-core::auth | `delegate_rejects_redirect_and_uses_platform_tls_validation` | inline | keep Swift | keep Swift (host transport contract) | no |

### NativeLab: SecureServerStoreTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `SecureServerStoreTests.swift::testPreferencesContainOnlyAccountMetadata` | Saved account ID is server URL plus newline plus user ID; metadata JSON has no token; an invalid token is refused before persisting | omnigent-core::auth::accounts | `preferences_contain_only_account_metadata` | inline | keep Swift | done (portable part) | no |
| `SecureServerStoreTests.swift::testKeychainSeparatesAccountsAndMountsAndDeletesOnlySelectedCredential` | Keychain credentials stay separate per account and mount; removing one leaves the others | omnigent-core::auth::accounts | `keychain_separates_accounts_and_mounts_and_deletes_only_selected_credential` | inline | keep Swift | done (portable part; Keychain CRUD stays Swift) | no |
| `SecureServerStoreTests.swift::testKeychainSeparatesDatabricksWorkspacesForTheSameAccount` | The same user on two Databricks workspaces (o=123 and o=456) keeps separate credentials | omnigent-core::auth::accounts | `keychain_separates_databricks_workspaces_for_the_same_account` | inline | keep Swift | done (portable part; Keychain CRUD stays Swift) | no |

### NativeLab: DatabricksRoutingTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `DatabricksRoutingTests.swift::testSelectorCanonicalizationAndDocumentedHostBoundaries` | The ?o= selector canonicalizes; documented Databricks hosts are accepted; the org is never inferred from the hostname | omnigent-core::auth::endpoint | `selector_canonicalization_and_documented_host_boundaries` | inline | port | done | no |
| `DatabricksRoutingTests.swift::testRejectsMalformedSelectorsAndOtherHostsWithoutMakingRequests` | Malformed, duplicate or non-numeric org selectors and look-alike Databricks hosts are rejected at construction | omnigent-core::auth::endpoint | `rejects_malformed_selectors_and_other_hosts_without_making_requests` | inline | port | done | no |
| `DatabricksRoutingTests.swift::testEveryTransportCarriesOrgHeaderWithoutPollutingEndpointQuery` | Every REST and WebSocket request carries X-Databricks-Org-Id and keeps o= out of the endpoint query; a conflicting o= query is rejected | omnigent-core::auth::endpoint | `every_transport_carries_org_header_without_polluting_endpoint_query` | inline | port | done | no |
| `DatabricksRoutingTests.swift::testIdentityNotificationAndDraftScopesSeparateOrgsOnSameHost` | Identity, notification and attachment-draft scopes differ between two orgs on one host; the sessions page carries the org header | omnigent-core::auth::hosted | `identity_notification_and_draft_scopes_separate_orgs_on_same_host` | sessions/DatabricksRouting--_shared--configure.jsonl; sessions/DatabricksRouting--IdentityNotificationAndDraftScopesSeparateOrgsOnSameHost.json | port | done (identity scope; notification/draft keys are WP4) | no |
| `DatabricksRoutingTests.swift::testOrgScopedAuthDiscoveryUsesHeaderAndRejectsStandaloneLoginBeforeSendingSecrets` | Workspace discovery uses the org header; standalone browser and password login are unsupported before any secret is sent | omnigent-core::auth::ticket | `org_scoped_auth_discovery_uses_header_and_rejects_standalone_login_before_sending_secrets` | sessions/DatabricksRouting--OrgScopedAuthDiscoveryUsesHeaderAndRejectsStandaloneLoginBeforeSendingSecrets.json | port | done | no |

### web/ios: ConnectionErrorTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `ConnectionErrorTests.swift::testDNSFailuresShowJAMFHintOnlyWhenEnabled` | cannotFindHost and dnsLookupFailed show Jamf hint only when enabled, else localized text | omnigent-core::auth::error_text | `dns_failure_shows_jamf_hint_only_when_enabled` | inline | port | done | no |
| `ConnectionErrorTests.swift::testDNSMappingDoesNotDependOnLocalizedDescription` | DNS classification keys on domain and code, not on localized description | omnigent-core::auth::error_text | `dns_mapping_ignores_localized_description` | inline | port | done | no |
| `ConnectionErrorTests.swift::testOtherNetworkErrorsKeepTheirOriginalMessage` | Other URL error codes (timeout, TLS, offline, cancelled) keep original message | omnigent-core::auth::error_text | `other_network_errors_keep_original_message` | inline | port | done | no |
| `ConnectionErrorTests.swift::testSameCodeInAnotherDomainIsNotADNSFailure` | Same numeric codes in a non-URL domain are not DNS failures | omnigent-core::auth::error_text | `same_code_other_domain_is_not_dns` | inline | port | done | no |
| `ConnectionErrorTests.swift::testNavigationFailureCallbacksUseCurrentFlag` | Failure callbacks ignore cancelled and off-origin errors and pick message by current flag; WKNavigationDelegate wiring stays Swift | omnigent-core::auth::error_text | `navigation_failure_message_uses_current_flag` | inline | port logic, Swift shim | done (logic; WKNavigationDelegate wiring stays Swift) | no |

### web/ios: DeepLinkTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `DeepLinkTests.swift::testParsesLoopbackHostWithPortAsHTTP` | Loopback host and port (IPv4 and IPv6 literal) map to http origin | omnigent-core::deeplink | `deeplink_loopback_host_maps_to_http` | inline | port | done | no |
| `DeepLinkTests.swift::testParsesRemoteHostAsHTTPS` | Remote host maps to https origin with path /c/<id> | omnigent-core::deeplink | `deeplink_remote_host_maps_to_https` | inline | port | done | no |
| `DeepLinkTests.swift::testPreservesNonDefaultPortOnRemoteHost` | Non-default port kept on remote https origin | omnigent-core::deeplink | `deeplink_keeps_non_default_port_remote` | inline | port | done | no |
| `DeepLinkTests.swift::testParsesIPv6LoopbackAsHTTP` | [::1] with port maps to http origin | omnigent-core::deeplink | `deeplink_ipv6_loopback_maps_to_http` | inline | port | done | no |
| `DeepLinkTests.swift::testStripsTrailingSlashFromPath` | Trailing slash removed so forwarded path is /c/<id> | omnigent-core::deeplink | `deeplink_strips_trailing_slash` | inline | port | done | no |
| `DeepLinkTests.swift::testAcceptsDashedUuidId` | Dashed UUID id accepted and forwarded as-is | omnigent-core::deeplink | `deeplink_accepts_dashed_uuid` | inline | port | done | no |
| `DeepLinkTests.swift::testAcceptsLegacyConvPrefixedId` | conv_ prefixed legacy id accepted and forwarded | omnigent-core::deeplink | `deeplink_accepts_conv_prefix` | inline | port | done | no |
| `DeepLinkTests.swift::testAcceptsLegacyAgPrefixedId` | ag_ prefixed legacy id accepted and forwarded | omnigent-core::deeplink | `deeplink_accepts_ag_prefix` | inline | port | done | no |
| `DeepLinkTests.swift::testAcceptsUppercaseHexId` | Uppercase hex id accepted and forwarded unchanged | omnigent-core::deeplink | `deeplink_accepts_uppercase_hex` | inline | port | done | no |
| `DeepLinkTests.swift::testRejectsNonOmnigentScheme` | https and vscode schemes rejected | omnigent-core::deeplink | `deeplink_rejects_non_omnigent_scheme` | inline | port | done | no |
| `DeepLinkTests.swift::testRejectsLinkWithNoHost` | omnigent:// and omnigent:///c/<id> rejected (no host) | omnigent-core::deeplink | `deeplink_rejects_missing_host` | inline | port | done | no |
| `DeepLinkTests.swift::testRejectsNonConversationPaths` | Only /c/<id> paths accepted; /inbox, /settings, empty id, extra segment, root rejected | omnigent-core::deeplink | `deeplink_rejects_non_conversation_paths` | inline | port | done | no |
| `DeepLinkTests.swift::testRejectsSmuggledQueryViaEncodedQuestionMark` | Encoded %3F smuggling a query into the id rejected | omnigent-core::deeplink | `deeplink_rejects_smuggled_query` | inline | port | done | no |
| `DeepLinkTests.swift::testRejectsSmuggledFragmentViaEncodedHash` | Encoded %23 smuggling a fragment rejected | omnigent-core::deeplink | `deeplink_rejects_smuggled_fragment` | inline | port | done | no |
| `DeepLinkTests.swift::testRejectsEncodedPathSeparator` | Encoded %2F path separator rejected | omnigent-core::deeplink | `deeplink_rejects_encoded_separator` | inline | port | done | no |
| `DeepLinkTests.swift::testRejectsEncodedDotAndDotDot` | %2E, %2e%2e and .. traversal segments rejected | omnigent-core::deeplink | `deeplink_rejects_dot_segments` | inline | port | done | no |
| `DeepLinkTests.swift::testRejectsControlCharacters` | %00, %0A, %7F control characters in id rejected | omnigent-core::deeplink | `deeplink_rejects_control_chars` | inline | port | done | no |
| `DeepLinkTests.swift::testRejectsMalformedPercentEscape` | Malformed %zz escape rejected | omnigent-core::deeplink | `deeplink_rejects_malformed_percent` | inline | port | done | no |
| `DeepLinkTests.swift::testAcceptsBenignNonCanonicalIds` | Denylist (not grammar): short, wrong-prefix, long, non-hex ids accepted | omnigent-core::deeplink | `deeplink_accepts_benign_non_canonical_ids` | inline | port | done | no |
| `DeepLinkTests.swift::testConversationURLPreservesWorkspaceQueryAndFragment` | AppRootView.conversationURL keeps mount, o= query and fragment, adds /c/<id> | omnigent-core::deeplink | `deeplink_conversation_url_preserves_query_and_fragment` | inline | port | done | no |

### web/ios: ManagedConfigurationTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `ManagedConfigurationTests.swift::testAbsentKeyOffersNoServers` | Absent serverUrls key offers no servers | omnigent-core::config::managed | `managed_absent_key_offers_no_servers` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testEmptyListOffersNoServers` | Empty serverUrls list offers no servers | omnigent-core::config::managed | `managed_empty_list_offers_no_servers` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testAdministratorOrderIsPreserved` | Administrator server order preserved | omnigent-core::config::managed | `managed_preserves_admin_order` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testBareHostGetsHTTPS` | Bare host normalized to https origin | omnigent-core::config::managed | `managed_bare_host_gets_https` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testWorkspaceMountIsPreserved` | Workspace mount path in preset URL kept | omnigent-core::config::managed | `managed_preserves_workspace_mount` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testDuplicateOriginsAreDroppedKeepingTheFirst` | Duplicate origins dropped, first kept (case and trailing slash ignored) | omnigent-core::config::managed | `managed_dedupes_origins_keeping_first` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testMaximumEntriesIsAccepted` | Exactly maxServerURLs entries accepted | omnigent-core::config::managed | `managed_accepts_max_entries` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testInternalFeaturesDefaultToDisabled` | Databricks internal features flag defaults to disabled | omnigent-core::config::managed | `managed_internal_features_default_disabled` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testInternalFeaturesAcceptBooleansWithoutPresetServers` | Boolean flag accepted with no preset servers | omnigent-core::config::managed | `managed_internal_flag_bool_without_servers` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testMalformedInternalFeaturesFlagFailsClosedWithoutDroppingServers` | Non-boolean flag values fail closed to false and keep servers | omnigent-core::config::managed | `managed_malformed_flag_fails_closed_keeps_servers` | managed/flag-malformed-values.json (proposed) | port | done | no |
| `ManagedConfigurationTests.swift::testLegacyInternalFeaturesFlagUpdatesAndCanBeRemoved` | Legacy flag read only as true bool; removal yields false (UserDefaults read stays Swift) | omnigent-core::config::managed | `managed_legacy_flag_only_true_bool_enables` | managed/legacy-flag-values.json (proposed) | port logic, Swift shim | done | no |
| `ManagedConfigurationTests.swift::testDeclarativeDisabledOrOmittedFlagOverridesLegacyEnabledFlag` | Declarative config that omits or disables flag overrides legacy enabled flag | omnigent-core::config::managed | `managed_declarative_overrides_legacy_flag` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testFlagOnlyDeclarativeConfigurationWinsWhileKeepingServerFallback` | Flag-only declarative config wins for flag; servers fall back to legacy | omnigent-core::config::managed | `managed_flag_only_declarative_keeps_legacy_servers` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testInternalFeaturesFallBackToLegacyOnlyWhenDeclarativeIsAbsent` | Legacy flag used only when declarative config is absent | omnigent-core::config::managed | `managed_legacy_flag_only_when_declarative_absent` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testInvalidURLIsRejected` | Unparseable entry rejected with invalid-URL code | omnigent-core::config::managed | `managed_rejects_invalid_url` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testBlankEntryIsRejected` | Blank entry rejected with invalid-URL code | omnigent-core::config::managed | `managed_rejects_blank_entry` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testInsecureHTTPIsRejected` | http entry rejected with not-HTTPS code | omnigent-core::config::managed | `managed_rejects_insecure_http` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testNonWebSchemeIsRejected` | ftp entry rejected with not-HTTPS code | omnigent-core::config::managed | `managed_rejects_non_web_scheme` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testTooManyEntriesAreRejected` | maxServerURLs plus one entries rejected with too-many code | omnigent-core::config::managed | `managed_rejects_too_many_entries` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testAStringInsteadOfAListIsRejected` | serverUrls given as string rejected with wrong-type code | omnigent-core::config::managed | `managed_rejects_string_instead_of_list` | managed/serverurls-string.json (proposed) | port | done | no |
| `ManagedConfigurationTests.swift::testOneBadEntryRejectsTheWholeConfiguration` | One bad entry rejects the whole list | omnigent-core::config::managed | `managed_one_bad_entry_rejects_all` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testLegacyDictionaryIsRead` | Legacy dictionary parsed into server URLs (UserDefaults read stays Swift) | omnigent-core::config::managed | `managed_legacy_dict_parsed` | managed/legacy-dict.json (proposed) | port logic, Swift shim | done | no |
| `ManagedConfigurationTests.swift::testAbsentLegacyKeyOffersNoServers` | Absent legacy key offers no servers | omnigent-core::config::managed | `managed_absent_legacy_offers_none` | inline | port logic, Swift shim | done | no |
| `ManagedConfigurationTests.swift::testInvalidLegacyDictionaryIsIgnoredRatherThanThrowing` | Invalid legacy dictionary (http) ignored, yields empty | omnigent-core::config::managed | `managed_invalid_legacy_ignored_not_thrown` | managed/legacy-dict-insecure.json (proposed) | port logic, Swift shim | done | no |
| `ManagedConfigurationTests.swift::testLegacyDictionaryWithUnrelatedKeysIsTolerated` | Extra unrelated keys in legacy dictionary tolerated | omnigent-core::config::managed | `managed_legacy_dict_tolerates_extra_keys` | managed/legacy-dict-extra-keys.json (proposed) | port logic, Swift shim | done | no |
| `ManagedConfigurationTests.swift::testDeclarativeConfigurationWinsOverLegacy` | Declarative server list wins over legacy | omnigent-core::config::managed | `managed_declarative_wins_over_legacy` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testLegacyIsUsedWhenNoDeclarativeConfigurationExists` | Legacy list used when no declarative list | omnigent-core::config::managed | `managed_legacy_used_without_declarative` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testNeitherChannelOffersNothing` | No channel gives empty list | omnigent-core::config::managed | `managed_neither_channel_offers_nothing` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testRecentsDropAServerTheAdministratorAlreadyPresets` | Recents exclude servers already preset by admin | omnigent-core::config::managed | `managed_recents_drop_preset_servers` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testRecentsAreUntouchedWithoutAConfiguration` | Recents untouched without managed config | omnigent-core::config::managed | `managed_recents_untouched_without_config` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testDifferingPortIsADifferentServer` | Same host, different port is a different server in recents | omnigent-core::config::managed | `managed_recents_differing_port_is_distinct` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testUnparseableRecentIsKept` | Unparseable recent kept (not dropped) | omnigent-core::config::managed | `managed_recents_keeps_unparseable` | inline | port | done | no |
| `ManagedConfigurationTests.swift::testPresetServersComeFirst` | Merged list puts preset servers first | omnigent-core::config::managed | `managed_merged_presets_first` | inline | port | done | no |

### web/ios: OidcCredentialStoreTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `OidcCredentialStoreTests.swift::testRejectsEmptyGrantsAndInvalidRecords` | Empty refresh token rejected; invalid JSON, bad version, empty token, missing token in record rejected as invalidData | omnigent-core::auth::oidc | `oidc_grant_record_rejects_invalid` | inline | port logic, Swift shim | done | no |

### web/ios: OidcCredentialsTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `OidcCredentialsTests.swift::testSignInUsesMountedLoginAndExchangesWithPKCE` | Login URL has native redirect, state, S256 challenge; exchange POSTs code and verifier and stores grant | omnigent-core::auth::oidc | `oidc_sign_in_builds_login_url_and_exchanges_pkce` | inline | port + mock HTTP | done | no |
| `OidcCredentialsTests.swift::testInvalidCallbacksAndCancellationNeverExchange` | Callback state mismatch, missing or empty code, wrong path, error without state rejected; no exchange (sheet cancel stays Swift) | omnigent-core::auth::oidc | `oidc_invalid_callbacks_never_exchange` | inline | port + mock HTTP | done | no |
| `OidcCredentialsTests.swift::testCallbackQueryDecodesAsAFormLikeTheServerEncodesIt` | Callback query decoded as form (+ is space, %2B is plus); duplicate state rejected; error description surfaced | omnigent-core::auth::oidc | `oidc_callback_query_decodes_as_form` | inline | port | done | no |
| `OidcCredentialsTests.swift::testExchangeWithoutRefreshTokenForgetsStaleGrant` | Exchange without refresh token deletes stale grant and returns session token without expiry | omnigent-core::auth::oidc | `oidc_exchange_without_refresh_forgets_stale_grant` | inline | port + fake store | done | no |
| `OidcCredentialsTests.swift::testOversizedExpiresInIsCapped` | Huge expires_in capped at max session lifetime | omnigent-core::auth::oidc | `oidc_expires_in_capped_at_max_lifetime` | inline | port + mock HTTP | done | no |
| `OidcCredentialsTests.swift::testExchangeWithoutRefreshTokenSucceedsWhenTheStaleGrantCannotBeDeleted` | Stale grant delete failure does not fail exchange | omnigent-core::auth::oidc | `oidc_exchange_succeeds_when_stale_grant_delete_fails` | inline | port + fake store | done | no |
| `OidcCredentialsTests.swift::testUnsafeSessionTokensAreRefused` | Tokens unsafe for Cookie header refused on exchange and refresh; grant unchanged; safe charset accepted | omnigent-core::auth::oidc | `oidc_unsafe_session_tokens_refused` | inline | port + mock HTTP | done | no |
| `OidcCredentialsTests.swift::testServerErrorDuringExchangeIsAnExchangeFailure` | Exchange 500 gives exchangeFailed with fixed user-facing message | omnigent-core::auth::oidc | `oidc_exchange_server_error_is_exchange_failure` | inline | port + mock HTTP | done | no |
| `OidcCredentialsTests.swift::testRejectedExchangeFailsAndKeepsStoredGrant` | Exchange 400 invalid_grant fails and keeps stored grant | omnigent-core::auth::oidc | `oidc_rejected_exchange_keeps_stored_grant` | inline | port + mock HTTP | done | no |
| `OidcCredentialsTests.swift::testCancelDuringExchangeStillStoresGrant` | Cancel during exchange still stores the returned grant | omnigent-core::auth::oidc | `oidc_cancel_during_exchange_still_stores_grant` | inline | port + mock HTTP | done | no |
| `OidcCredentialsTests.swift::testUnsavableGrantIsRevoked` | Grant that cannot be saved is revoked with its refresh token; Keychain error surfaced | omnigent-core::auth::oidc | `oidc_unsavable_grant_is_revoked` | inline | port + fake store | done | no |
| `OidcCredentialsTests.swift::testExchangeDoesNotFollowRedirects` | Exchange 302 not followed; leak endpoint not hit; grant not stored | omnigent-core::auth::oidc | `oidc_exchange_does_not_follow_redirects` | inline | port + mock HTTP | done | no |
| `OidcCredentialsTests.swift::testRefreshDoesNotFollowRedirects` | Refresh 302 not followed; grant kept | omnigent-core::auth::oidc | `oidc_refresh_does_not_follow_redirects` | inline | port + mock HTTP | done | no |
| `OidcCredentialsTests.swift::testRefreshMintsFromStoredGrant` | Refresh POSTs grant_type and refresh_token, mints session with expiry, keeps grant | omnigent-core::auth::oidc | `oidc_refresh_mints_from_stored_grant` | inline | port + mock HTTP | done | no |
| `OidcCredentialsTests.swift::testDeadGrantsAreForgotten` | invalid_grant gives grantRejected, expired_token gives grantExpired, 404 gives noStoredGrant; grant removed; messages fixed | omnigent-core::auth::oidc | `oidc_dead_grants_forgotten_with_messages` | inline | port + mock HTTP | done | no |
| `OidcCredentialsTests.swift::testServerAndTransportFailuresKeepGrant` | 500, invalid_request and unreachable host give network error; grant kept | omnigent-core::auth::oidc | `oidc_server_and_transport_failures_keep_grant` | inline | port + mock HTTP | done | no |
| `OidcCredentialsTests.swift::testRefreshWithoutGrantMakesNoRequest` | Refresh with no stored grant gives noStoredGrant and sends nothing | omnigent-core::auth::oidc | `oidc_refresh_without_grant_sends_nothing` | inline | port + mock HTTP | done | no |
| `OidcCredentialsTests.swift::testConcurrentRefreshesShareOneRequest` | Concurrent refreshes for same origin (different spellings) share one request | omnigent-core::auth::oidc | `oidc_concurrent_refreshes_share_one_request` | inline | port + mock HTTP | done | no |
| `OidcCredentialsTests.swift::testSignOutForgetsGrantBeforeRevoking` | Sign-out forgets grant locally before POST /oauth/revoke with refresh_token | omnigent-core::auth::oidc | `oidc_sign_out_forgets_grant_before_revoke` | inline | port + mock HTTP | done | no |
| `OidcCredentialsTests.swift::testSignOutDropsRefreshInFlight` | Sign-out drops in-flight refresh; later refresh finds no grant | omnigent-core::auth::oidc | `oidc_sign_out_drops_in_flight_refresh` | inline | port + mock HTTP | done | no |
| `OidcCredentialsTests.swift::testSignOutSurvivesRevokeFailure` | Revoke 500 or unreachable host still clears local grant; nothing to revoke when none stored | omnigent-core::auth::oidc | `oidc_sign_out_survives_revoke_failure` | inline | port + mock HTTP | done | no |
| `OidcCredentialsTests.swift::testIsAcceptedMapsMeStatus` | GET /v1/me with ap_session cookie: 200 accepted; 401, 403, 302 not; 500 and unreachable give network error | omnigent-core::auth::oidc | `oidc_is_accepted_maps_me_status` | inline | port + mock HTTP | done | no |
| `OidcCredentialsTests.swift::testSessionCookieAttributes` | Session cookie: __Host- name, Secure, HttpOnly, SameSite=Lax, expiry; plain http cookie session-only | omnigent-core::auth::oidc_session | `oidc_session_cookie_attributes` | inline | port | done | no |

### web/ios: OidcLoginManagerTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `OidcLoginManagerTests.swift::testTicketAndPollSendMatchingPKCEProof` | POST /auth/cli-login sends S256 challenge; GET /auth/cli-poll sends verifier header and returns token | omnigent-core::auth::ticket | `oidc_cli_ticket_and_poll_send_pkce_proof` | inline | port + mock HTTP | done | no |
| `OidcLoginManagerTests.swift::testDeniedPollReturnsNoToken` | Poll 400, 403 or 410 ends polling with no token and no retry | omnigent-core::auth::ticket | `oidc_cli_denied_poll_ends_without_token` | inline | port + mock HTTP | done | no |
| `OidcLoginManagerTests.swift::testTicketAcceptsRootedSameOriginLoginPath` | Ticket login_url accepted when rooted and same-origin | omnigent-core::auth::ticket | `oidc_ticket_accepts_rooted_login_path` | inline | port | done | no |
| `OidcLoginManagerTests.swift::testTicketRejectsAbsoluteAndSchemeRelativeLoginURLs` | Absolute, scheme-relative and relative login_url rejected | omnigent-core::auth::ticket | `oidc_ticket_rejects_absolute_and_relative_login_url` | inline | port | done | no |
| `OidcLoginManagerTests.swift::testTokenRejectsCookieInjectionCharacters` | Token must be three dot-separated parts without ;, empty parts or spaces | omnigent-core::auth::ticket | `oidc_token_rejects_cookie_injection` | inline | port | done | no |
| `OidcLoginManagerTests.swift::testHTTPSCookieUsesHostPrefixAndSecureFlag` | HTTPS session cookie named __Host-ap_session, Secure, path / | omnigent-core::auth::oidc_session | `oidc_https_cookie_host_prefix_and_secure` | inline | port | done | no |
| `OidcLoginManagerTests.swift::testDebugHTTPCookieUsesUnprefixedName` | Debug http cookie named ap_session, not Secure | omnigent-core::auth::oidc_session | `oidc_http_cookie_unprefixed` | inline | port | done | no |

### web/ios: OidcWebSessionTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `OidcWebSessionTests.swift::testMatchesLoginAndLogoutAtTheOriginRoot` | /auth/login and /auth/logout matched at origin root, query ignored, host case ignored | omnigent-core::auth::oidc_session | `oidc_auth_route_matches_login_logout_at_root` | inline | port | done | no |
| `OidcWebSessionTests.swift::testMatchesRoutesUnderTheMountOnly` | Auth routes matched only under the server mount | omnigent-core::auth::oidc_session | `oidc_auth_route_matches_only_under_mount` | inline | port | done | no |
| `OidcWebSessionTests.swift::testIgnoresOtherPagesAndOtherOrigins` | Trailing slash, cli-login, v1 prefix, http, other port, other origin not matched | omnigent-core::auth::oidc_session | `oidc_auth_route_ignores_other_pages_and_origins` | inline | port | done | no |
| `OidcWebSessionTests.swift::testAppPagesStayUnderTheMountAndExcludeAuthRoutes` | App pages under mount accepted; lookalike prefix, auth routes, other origins excluded | omnigent-core::auth::oidc_session | `oidc_is_page_under_mount_excludes_auth_routes` | inline | port | done | no |
| `OidcWebSessionTests.swift::testOidcWithThisAppsRedirectAndACookieUsesNativeSignIn` | Manifest oidc with cookie and this app's native redirect enables native sign-in | omnigent-protocol::manifest | `manifest_native_sign_in_cookie_enabled_when_redirect_matches` | inline | port | done | no |
| `OidcWebSessionTests.swift::testMissingRedirectOrCookieKeepsTheLegacyFlow` | Missing cookie, non-matching redirects or missing redirects keep legacy flow | omnigent-protocol::manifest | `manifest_native_sign_in_legacy_when_redirect_or_cookie_missing` | inline | port | done | no |
| `OidcWebSessionTests.swift::testOtherModesAndTheBaselineKeepTheLegacyFlow` | accounts, header, custom, none modes and baseline keep legacy flow | omnigent-protocol::manifest | `manifest_native_sign_in_only_for_oidc_mode` | inline | port | done | no |
| `OidcWebSessionTests.swift::testASecondSignInRequestWithinFifteenSecondsIsRejected` | Second renewal within 15 seconds rejected | omnigent-core::auth::oidc_session | `oidc_renewal_guard_rejects_within_15s` | inline | port | done | no |
| `OidcWebSessionTests.swift::testARequestAfterTheWindowRenewsAgain` | Renewal allowed again at 15 seconds | omnigent-core::auth::oidc_session | `oidc_renewal_guard_allows_after_window` | inline | port | done | no |
| `OidcWebSessionTests.swift::testARequestDuringAPendingRenewalJoinsIt` | Request during pending renewal joins and restarts window | omnigent-core::auth::oidc_session | `oidc_renewal_guard_joins_pending_and_restarts_window` | inline | port | done | no |
| `OidcWebSessionTests.swift::testSignOutInvalidatesWorkStartedBeforeIt` | Sign-out bumps origin generation; earlier work is not current | omnigent-core::auth::oidc_session | `oidc_sign_out_generation_invalidates_prior_work` | inline | port | done | no |
| `OidcWebSessionTests.swift::testSignOutLeavesOtherOriginsAlone` | Sign-out does not affect other origin generation | omnigent-core::auth::oidc_session | `oidc_sign_out_generation_is_per_origin` | inline | port | done | no |
| `OidcWebSessionTests.swift::testLiveSessionCookieMatchesNameHostAndExpiry` | Live session cookie chosen by name, host and unexpired date | omnigent-core::auth::oidc_session | `oidc_live_session_cookie_matches_name_host_expiry` | inline | port | done | no |
| `OidcWebSessionTests.swift::testSecureCookieIsNeverOfferedToAnHttpServerOnTheSameHost` | Secure cookie not offered to http server on same host; offered to https | omnigent-core::auth::oidc_session | `oidc_secure_cookie_not_offered_to_http` | inline | port | done | no |
| `OidcWebSessionTests.swift::testCookiePathMustCoverTheServersMount` | Cookie path must cover mount (segment boundary); root path matches everything | omnigent-core::auth::oidc_session | `oidc_cookie_path_must_cover_mount` | inline | port | done | no |
| `OidcWebSessionTests.swift::testOnlyARefusedSignInStopsAutoOpening` | Only signInRefused stops auto-open; other errors do not | omnigent-core::auth::oidc_session | `oidc_only_refused_sign_in_stops_auto_open` | inline | port | done | no |
| `OidcWebSessionTests.swift::testABackgroundRenewalsLostGrantExplainsTheNextPrompt` | Remembered renewal cause (expired or rejected) explains next prompt message | omnigent-core::auth::oidc_session | `oidc_renewal_lost_grant_explains_next_prompt` | inline | port | done | no |
| `OidcWebSessionTests.swift::testRenewalDelayLeavesAMarginBeforeExpiry` | Renewal scheduled 60 seconds before expiry; zero or past expiry gives 0 | omnigent-core::auth::oidc_session | `oidc_renewal_delay_leaves_60s_margin` | inline | port | done | no |
| `OidcWebSessionTests.swift::testOversizedRenewalDelayIsBounded` | Huge or distant-future expiry bounded to max renewal delay | omnigent-core::auth::oidc_session | `oidc_renewal_delay_bounded_to_max` | inline | port | done | no |
| `OidcWebSessionTests.swift::testReauthenticationMessagesNameTheCause` | Reauthentication and signed-out message text per cause | omnigent-core::auth::oidc_session | `oidc_reauthentication_messages_name_cause` | inline | port | done | no |
| `OidcWebSessionTests.swift::testClosingTheSheetKeepsOnlyAnEndedSessionsReason` | Closing sheet keeps only ended-session reasons (expired, rejected, session rejected) | omnigent-core::auth::oidc_session | `oidc_cancelled_sign_in_keeps_only_ended_reason` | inline | port | done | no |

### web/ios: ServerManifestTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `ServerManifestTests.swift::testReadsOidcManifestAtTheOriginWithCookieAndNativeRedirects` | GET /.well-known/omnigent.json at origin; parses oidc mode, session cookie, string-only native redirects | omnigent-core::client + omnigent-protocol::manifest | `fetches_manifest_at_the_origin_and_maps_it`, `oidc_manifest_with_cookie_and_native_redirects_drops_non_string_redirects` | inline | port + mock HTTP | done | no |
| `ServerManifestTests.swift::testAuthWithoutNativeRedirectsHasNone` | accounts mode and null redirects yield empty native redirect list | omnigent-protocol::manifest | `auth_without_native_redirects_has_none` | inline | port | done | no |
| `ServerManifestTests.swift::testUnknownModeDropsAuthButKeepsVersion` | Unknown auth mode drops auth but keeps manifest_version | omnigent-protocol::manifest | `unknown_mode_is_kept_verbatim_with_version` | inline | port | done (diverges: mode kept as Unknown, see README) | no |
| `ServerManifestTests.swift::testUnknownSessionCookieIsDropped` | Unknown session cookie name dropped | omnigent-protocol::manifest | `unknown_session_cookie_is_untrusted` | inline | port | done | no |
| `ServerManifestTests.swift::testHostPrefixedCookieOnlyForHTTPS` | __Host- cookie kept only for https server | omnigent-protocol::manifest | `host_prefixed_cookie_only_for_https` | inline | port | done | no |
| `ServerManifestTests.swift::testNotFoundIsBaseline` | 404 gives baseline manifest | omnigent-core::client | `not_found_is_baseline` | inline | port + mock HTTP | done | no |
| `ServerManifestTests.swift::testHTMLFromSPACatchAllIsBaseline` | text/html SPA catch-all gives baseline | omnigent-core::client | `html_from_spa_catch_all_is_baseline` | inline | port + mock HTTP | done | no |
| `ServerManifestTests.swift::testMalformedJSONIsBaseline` | Malformed JSON gives baseline | omnigent-core::client | `malformed_json_is_a_decode_error` | inline | port + mock HTTP | done (diverges: typed Decode error, see README) | no |
| `ServerManifestTests.swift::testNonNumericVersionIsBaseline` | String, boolean, null or missing manifest_version gives baseline | omnigent-core::client + omnigent-protocol::manifest | `non_numeric_version_is_a_decode_error`, `non_numeric_or_missing_version_is_an_error` | inline | port | done (diverges: typed Decode error, see README) | no |
| `ServerManifestTests.swift::testRedirectIsNotFollowed` | Manifest 302 not followed; baseline returned | omnigent-core::client | `other_statuses_are_errors_with_body` | inline | port + mock HTTP | done (diverges: 302 is HttpStatus, never followed) | no |
| `ServerManifestTests.swift::testUnreachableServerIsBaseline` | Unreachable server gives baseline | omnigent-core::client | `transport_errors_keep_their_kind` | inline | port | done (diverges: typed Transport error) | no |
| `ServerManifestTests.swift::testCancellationPropagates` | Caller cancellation propagates as cancellation error | omnigent-core::client | `transport_errors_keep_their_kind` | inline | port + mock HTTP | done (caller cancel = dropping the future; Cancelled kind kept) | no |
| `ServerManifestTests.swift::testTransportCancellationWithoutCallerCancellationIsBaseline` | Transport-level cancel with caller not cancelled gives baseline | omnigent-core::client | `transport_errors_keep_their_kind` | inline | port + mock HTTP | done (diverges: Transport(Cancelled)) | no |

### web/ios: ServerSwitcherVisibilityTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `ServerSwitcherVisibilityTests.swift::testRecoveryPageAppliesOnlyToTheDestinationItWasRecordedFor` | Recovery page URL applies only to exact recorded destination | omnigent-core::auth::error_text | `recovery_page_applies_only_to_recorded_destination` | inline | port | done | no |
| `ServerSwitcherVisibilityTests.swift::testRecoveryAppliesOnlyToTheDestinationItWasStartedFor` | Recovery intent is recover only for the started workspace URL; other URLs are connect | omnigent-core::auth::error_text | `recovery_intent_applies_only_to_started_destination` | inline | port | done | no |

### web/ios: ServerURLTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `ServerURLTests.swift::testReleasePolicyDefaultsBareHostToHTTPS` | Release policy: bare host becomes https | omnigent-core::server_url | `release_policy_defaults_bare_host_to_https` | inline | port | done | no |
| `ServerURLTests.swift::testDebugPolicyDefaultsBareHostToHTTP` | Debug policy: bare localhost:port becomes http | omnigent-core::server_url | `debug_policy_defaults_bare_host_to_http` | inline | port | done | no |
| `ServerURLTests.swift::testDebugPolicyStillDefaultsRemoteHostToHTTPS` | Debug policy: remote bare host still https | omnigent-core::server_url | `debug_policy_still_defaults_remote_host_to_https` | inline | port | done | no |
| `ServerURLTests.swift::testDebugPolicyDefaultsLoopbackVariantsToHTTP` | Debug policy: 127.0.0.1 variant defaults to http | omnigent-core::server_url | `debug_policy_defaults_loopback_variants_to_http` | inline | port | done | no |
| `ServerURLTests.swift::testDebugPolicyHonoursExplicitHTTPForRemoteHost` | Debug policy honours explicit http:// for remote host | omnigent-core::server_url | `debug_policy_honours_explicit_http_for_remote_host` | inline | port | done | no |
| `ServerURLTests.swift::testReleasePolicyRejectsHTTP` | Release policy rejects http with insecureHTTPNotAllowed | omnigent-core::server_url | `release_policy_rejects_http` | inline | port | done | no |
| `ServerURLTests.swift::testRejectsNonWebSchemes` | ftp scheme rejected with unsupportedScheme(ftp) | omnigent-core::server_url | `rejects_non_web_schemes` | inline | port | done | no |
| `ServerURLTests.swift::testClassifiesWorkspaceHosts` | databricks.com, cloud and azure workspace hosts (any case) classified workspace | omnigent-core::auth::mode | `auth_classifies_workspace_hosts` | inline | port | done | no |
| `ServerURLTests.swift::testClassifiesAppsSeparatelyFromWorkspaces` | Databricks apps hosts classified databricksApp | omnigent-core::auth::mode | `auth_classifies_apps_separately` | inline | port | done | no |
| `ServerURLTests.swift::testOtherHostsAndLookalikesUseOIDC` | Other hosts, lookalike domains, invalid URLs, nil and empty use oidc | omnigent-core::auth::mode | `auth_other_and_lookalike_hosts_use_oidc` | inline | port | done | no |
| `ServerURLTests.swift::testClassificationDependsOnlyOnHost` | Port, path, query and scheme ignored; host alone decides | omnigent-core::auth::mode | `auth_classification_depends_only_on_host` | inline | port | done | no |
| `ServerURLTests.swift::testHostAndOriginClassificationAgree` | Host-only and origin-based classification agree | omnigent-core::auth::mode | `auth_host_and_origin_classification_agree` | inline | port | done | no |
| `ServerURLTests.swift::testOnlyAppsAuthenticationRemainsInline` | Only databricksApp uses in-WebView auth | omnigent-core::auth::mode | `auth_only_apps_uses_inline_webview` | inline | port | done | no |
| `ServerURLTests.swift::testAppendsRouteUnderTheServerMount` | omnigentEndpoint appends route under server mount, ignores query and fragment, keeps encoded mount | omnigent-core::server_url | `endpoint_appends_route_under_mount` | inline | port | done | no |
| `ServerURLTests.swift::testRejectsRelativeRoute` | omnigentEndpoint rejects relative route | omnigent-core::server_url | `endpoint_rejects_relative_route` | inline | port | done | no |

### web/ios: SettingsStoreTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `SettingsStoreTests.swift::testRecentServersAreDedupedAndCapped` | Recent servers deduped (most recent first) and capped at 5 | omnigent-core::config::settings | `settings_recent_servers_deduped_capped` | inline | port logic, Swift shim | done | no |
| `SettingsStoreTests.swift::testProtocolGrantsAreScopedByOrigin` | Protocol grant (vscode) scoped to origin | omnigent-core::config::settings | `settings_protocol_grant_scoped_by_origin` | inline | port logic, Swift shim | done | no |
| `SettingsStoreTests.swift::testOidcSignOutStopsAutoOpeningOnlyThatServer` | OIDC sign-out clears auto-open only for that origin | omnigent-core::config::settings | `settings_oidc_signout_stops_auto_open_for_one_server` | inline | port logic, Swift shim | done | no |
| `SettingsStoreTests.swift::testOidcSignOutStopsAutoOpeningAnIPv6Server` | Same as above for IPv6 host with port | omnigent-core::config::settings | `settings_oidc_signout_ipv6_origin` | inline | port logic, Swift shim | done | no |
| `SettingsStoreTests.swift::testRefusedServerStaysPrefilledButIsNotReopened` | Refused server stays prefilled, not auto-opened; suppression survives relaunch; reconnect clears on success | omnigent-core::config::settings | `settings_refused_server_prefilled_not_reopened` | inline | port logic, Swift shim | done | no |
| `SettingsStoreTests.swift::testChoosingAnotherServerEndsTheSuppression` | Choosing another server ends suppression for the old one | omnigent-core::config::settings | `settings_choosing_other_server_ends_suppression` | inline | port logic, Swift shim | done | no |
| `SettingsStoreTests.swift::testKnownServerURLMatchesByOrigin` | Known server URL matched by origin, returning recorded URL with mount | omnigent-core::config::settings | `settings_known_server_url_matches_origin` | inline | port logic, Swift shim | done | no |
| `SettingsStoreTests.swift::testKnownServerURLReturnsNilForNeverConnectedOrigin` | Unseen origin yields no known server URL | omnigent-core::config::settings | `settings_known_server_url_none_for_unseen` | inline | port logic, Swift shim | done | no |

### web/ios: WorkspaceURLExpanderRedirectTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `WorkspaceURLExpanderRedirectTests.swift::testBlocksCrossOriginRedirect` | Probe 302 to other port not followed; response stays on approved origin | omnigent-core::auth::workspace | `probe_blocks_cross_origin_redirect` | inline | port + mock HTTP | done (core follows only same-origin 3xx) | no |
| `WorkspaceURLExpanderRedirectTests.swift::testFollowsSameOriginRedirect` | Same-origin 302 followed to 200 | omnigent-core::auth::workspace | `probe_follows_same_origin_redirect` | inline | port + mock HTTP | done | no |

### web/ios: WorkspaceURLExpanderTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `WorkspaceURLExpanderTests.swift::testExpandsBareDatabricksWorkspaceRoot` | HEAD probe with server: databricks header expands bare root to /omnigent | omnigent-core::auth::workspace | `probe_expands_bare_workspace_root` | inline | port + mock HTTP | done | no |
| `WorkspaceURLExpanderTests.swift::testLeavesNonWorkspaceRootUnchanged` | HEAD probe with non-Databricks server leaves URL unchanged | omnigent-core::auth::workspace | `probe_leaves_non_workspace_root` | inline | port + mock HTTP | done | no |
| `WorkspaceURLExpanderTests.swift::testLeavesURLsWithPathsUnchangedWithoutProbe` | URL with path is unchanged and no probe sent | omnigent-core::auth::workspace | `probe_skipped_for_path_urls` | inline | port + mock HTTP | done | no |
| `WorkspaceURLExpanderTests.swift::testLeavesDatabricksAppsHostUnchangedWithoutProbe` | Apps hosts unchanged with no probe | omnigent-core::auth::workspace | `probe_skipped_for_apps_hosts` | inline | port + mock HTTP | done | no |
| `WorkspaceURLExpanderTests.swift::testAppsLookalikesAreStillProbed` | Lookalike apps hosts still probed and expanded | omnigent-core::auth::workspace | `probe_runs_for_apps_lookalikes` | inline | port + mock HTTP | done | no |
| `WorkspaceURLExpanderTests.swift::testRejectsResponseFromDifferentOrigin` | Probe response from other origin ignored; URL unchanged | omnigent-core::auth::workspace | `probe_rejects_response_from_other_origin` | inline | port + mock HTTP | done (sans-IO: cross-origin Location is never contacted) | no |
| `WorkspaceURLExpanderTests.swift::testRewritesBareWorkspaceRoots` | Bare workspace roots rewritten to /omnigent mount, including trailing slash and root domains | omnigent-core::server_url | `workspace_ui_url_rewrites_bare_roots` | inline | port | done | no |
| `WorkspaceURLExpanderTests.swift::testPreservesQueryAndFragment` | o= query and fragment preserved on rewrite | omnigent-core::server_url | `workspace_ui_url_preserves_query_fragment` | inline | port | done | no |
| `WorkspaceURLExpanderTests.swift::testPreservesPortAndNormalizesHostCase` | Port kept; host case kept as typed (test name says normalize, assertion keeps case) | omnigent-core::server_url | `workspace_ui_url_keeps_port_and_lowercases_host` | inline | port | done (diverges: url crate lowercases the host) | no |
| `WorkspaceURLExpanderTests.swift::testLeavesNonRootPathsAlone` | Non-root paths (/omnigent, /c/abc, /ml/omnigents) not rewritten | omnigent-core::server_url | `workspace_ui_url_leaves_non_root_paths` | inline | port | done | no |
| `WorkspaceURLExpanderTests.swift::testLeavesDatabricksAppsAndOtherHostsAlone` | Apps, example.com, localhost, dot-boundary lookalikes not rewritten | omnigent-core::server_url | `workspace_ui_url_leaves_apps_and_lookalikes` | inline | port | done | no |
| `WorkspaceURLExpanderTests.swift::testRejectsNonHTTPSchemes` | omnigent:// and file:// not rewritten | omnigent-core::server_url | `workspace_ui_url_rejects_non_http_schemes` | inline | port | done | no |

## WP7 databricks-auth — tests

### web/ios: DatabricksCredentialStoreTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `DatabricksCredentialStoreTests.swift::testScopeCanonicalizationAndIsolation` | Scope canonicalizes workspace (port 443, query, fragment) and isolates by client and workspace | omnigent-core::auth::databricks::scope | `databricks_scope_canonicalization_and_isolation` | inline | port | done | no (already WP7) |
| `DatabricksCredentialStoreTests.swift::testWorkspaceIDsSeparateScopesWithoutChangingLegacyKeys` | o= workspace id separates scopes; legacy account key format preserved; invalid o values rejected | omnigent-core::auth::databricks::scope | `databricks_workspace_id_scopes_and_legacy_key` | inline | port | done | no (already WP7) |
| `DatabricksCredentialStoreTests.swift::testIssuerAwareRecordsUpgradeToVersionTwo` | Record encodes issuer as version 2; version 1 decodes without issuer (Keychain round-trip stays Swift) | omnigent-core::auth::databricks::tokens | `databricks_credential_record_v1_v2_codec` | inline | port logic, Swift shim | done | no (already WP7) |
| `DatabricksCredentialStoreTests.swift::testRejectsMalformedAndFutureRecordsWithoutDeletingThem` | Decoder rejects bad JSON, future version, v2 missing or bad issuer, v1 with issuer (not deleting is Swift store behavior) | omnigent-core::auth::databricks::tokens | `databricks_credential_record_rejects_malformed_and_future` | inline | port logic, Swift shim | done | no (already WP7) |

### web/ios: DatabricksLoginManagerTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `DatabricksLoginManagerTests.swift::testCompletesHTTPSCallbackAndExchangesExactlyOnce` | Valid HTTPS callback exchanges code exactly once and stores tokens under scope (browser sheet stays Swift) | omnigent-core::auth::databricks::login | `databricks_login_completes_callback_and_exchanges_once` | inline | port + mock HTTP | done | no (already WP7) |
| `DatabricksLoginManagerTests.swift::testRejectsConcurrentLogin` | Second login while one is in flight is rejected with loginInProgress | omnigent-core::auth::databricks::login | `databricks_login_rejects_concurrent_login` | inline | port | done | no (already WP7) |
| `DatabricksLoginManagerTests.swift::testCancellationDoesNotNeedBrowserCompletionAndIgnoresStaleCallback` | After cancel, a stale callback is ignored and the newer login wins (generation logic in Rust) | omnigent-core::auth::databricks::login | `databricks_login_stale_callback_ignored_after_cancel` | inline | port logic, Swift shim | done | no (already WP7) |
| `DatabricksLoginManagerTests.swift::testCancelDuringExchangeCancelsNetworkOperation` | Cancel while token exchange is in flight aborts the network request | omnigent-core::auth::databricks::login | `databricks_login_cancel_during_exchange_aborts` | inline | port + mock HTTP | done | no (already WP7) |
| `DatabricksLoginManagerTests.swift::testInvalidCallbackAndBrowserFailureNeverExchangeCode` | Invalid state or browser error never reaches token endpoint; browser error text not leaked | omnigent-core::auth::databricks::login | `databricks_login_invalid_callback_never_exchanges` | inline | port + mock HTTP | done | no (already WP7) |
| `DatabricksLoginManagerTests.swift::testPersistenceFailureIsNotReportedAsSuccessfulLogin` | Store save failure surfaces as error, not login success (Keychain store is a fake here) | omnigent-core::auth::databricks::login | `databricks_login_save_failure_is_not_success` | inline | port + fake store | done | no (already WP7) |
| `DatabricksLoginManagerTests.swift::testClearOrNewerLoginRejectsOldLoginCommit` | Clear or a newer login makes an old in-flight login commit fail | omnigent-core::auth::databricks::login | `databricks_login_old_commit_rejected_after_clear_or_newer` | inline | port + fake store | done | no (already WP7) |
| `DatabricksLoginManagerTests.swift::testCancelledReplacementPreservesSavedCredentials` | Cancelling a replacement login keeps the previously saved credentials | omnigent-core::auth::databricks::login | `databricks_cancelled_replacement_keeps_saved_tokens` | inline | port + fake store | done | no (already WP7) |
| `DatabricksLoginManagerTests.swift::testIssuerDiscoveryKeepsSelectedWorkspaceContext` | o= from selected URL kept in authorize URL; discovered account issuer stored under selected scope only | omnigent-core::auth::databricks::login | `databricks_login_issuer_discovery_keeps_workspace_scope` | inline | port + mock HTTP | done | no (already WP7) |
| `DatabricksLoginManagerTests.swift::testUnsupportedCallbackIssuerNeverExchangesOrStoresTokens` | Unsupported callback iss rejected with invalidIssuer; no exchange, no store | omnigent-core::auth::databricks::login | `databricks_login_unsupported_issuer_never_stores` | inline | port + mock HTTP | done | no (already WP7) |

### web/ios: DatabricksOAuthClientTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `DatabricksOAuthClientTests.swift::testDecodesOpaqueTokensAndUsesResponseExpiry` | Token response decodes opaque tokens and computes expiry from expires_in | omnigent-core::auth::databricks::tokens | `databricks_token_response_decodes_opaque_tokens` | inline | port | done | no (already WP7) |
| `DatabricksOAuthClientTests.swift::testRejectsIncompleteOrInvalidTokenResponses` | Missing or empty fields, bad token_type, non-positive expires_in, non-JSON all rejected | omnigent-core::auth::databricks::tokens | `databricks_token_response_rejects_invalid` | inline | port | done | no (already WP7) |
| `DatabricksOAuthClientTests.swift::testExchangeUsesIsolatedSession` | Token exchange sends no Cookie header and uses no cookie store or cache | omnigent-core::auth::databricks::client | `databricks_token_exchange_uses_isolated_client` | inline | port + mock HTTP | done | no (already WP7) |
| `DatabricksOAuthClientTests.swift::testHTTPFailuresAndUnexpectedResponseOriginsAreRejected` | Status 302, 400, 401, 403, 500 or off-origin response URL map to tokenExchangeFailed without body leak | omnigent-core::auth::databricks::client | `databricks_token_exchange_http_failures_sanitized` | inline | port + mock HTTP | done | no (already WP7) |
| `DatabricksOAuthClientTests.swift::testNetworkErrorsAreSanitized` | Offline error maps to networkUnavailable | omnigent-core::auth::databricks::client | `databricks_token_exchange_network_error_sanitized` | inline | port + mock HTTP | done | no (already WP7) |
| `DatabricksOAuthClientTests.swift::testRefusesRealSameAndCrossOriginRedirects` | Token transport does not follow same-origin or cross-origin 307 redirects | omnigent-core::auth::databricks::client | `databricks_token_transport_does_not_follow_redirects` | inline | port + mock HTTP | done | no (already WP7) |
| `DatabricksOAuthClientTests.swift::testRefreshFormAndRotatedResponse` | Refresh POSTs grant_type, client_id, refresh_token form to /oidc/v1/token and accepts rotated refresh token | omnigent-core::auth::databricks::client | `databricks_refresh_form_and_rotated_response` | inline | port + mock HTTP | done | no (already WP7) |
| `DatabricksOAuthClientTests.swift::testRefreshRetainsOmittedTokenButRejectsMalformedReplacement` | Refresh without refresh_token keeps old one; empty, blank, null or numeric replacement rejected | omnigent-core::auth::databricks::tokens | `databricks_refresh_retains_omitted_refresh_token` | inline | port | done | no (already WP7) |
| `DatabricksOAuthClientTests.swift::testOnlyValidatedInvalidGrantResponseInvalidatesRefresh` | Only 400 with error invalid_grant gives invalidRefreshGrant; other errors do not | omnigent-core::auth::databricks::client | `databricks_only_invalid_grant_invalidates_refresh` | inline | port + mock HTTP | done | no (already WP7) |

### web/ios: DatabricksOAuthIssuerTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `DatabricksOAuthIssuerTests.swift::testPreservesWorkspaceAndAccountIssuerPaths` | Workspace and account issuers keep path; discovery and /v1/token endpoints derived | omnigent-core::auth::databricks::issuer | `databricks_issuer_preserves_paths_and_derives_endpoints` | inline | port | done | no (already WP7) |
| `DatabricksOAuthIssuerTests.swift::testRejectsUnsupportedIssuerAuthoritiesAndPaths` | Issuers with http, foreign host, apps host, userinfo, port, query, fragment, bad account path rejected | omnigent-core::auth::databricks::issuer | `databricks_issuer_rejects_unsupported_authorities` | inline | port | done | no (already WP7) |
| `DatabricksOAuthIssuerTests.swift::testDiscoveryMustConfirmExactIssuerAndTokenEndpoint` | Discovery doc must match exact issuer and token_endpoint; mismatches or missing fields rejected | omnigent-core::auth::databricks::issuer | `databricks_discovery_must_confirm_issuer_and_token_endpoint` | inline | port | done | no (already WP7) |
| `DatabricksOAuthIssuerTests.swift::testCallbackIssuerIsValidatedAlongsideState` | iss callback param validated with state; missing iss falls back to workspace /oidc; duplicate iss rejected | omnigent-core::auth::databricks::attempt | `databricks_callback_issuer_validated_with_state` | inline | port | done | no (already WP7) |
| `DatabricksOAuthIssuerTests.swift::testExchangeAndRefreshUseDiscoveredIssuerWithoutChangingDestination` | Exchange and refresh hit discovered account authority /oidc/accounts/.../v1/token, not page host | omnigent-core::auth::databricks::client | `databricks_exchange_and_refresh_use_discovered_issuer` | inline | port + mock HTTP | done | no (already WP7) |
| `DatabricksOAuthIssuerTests.swift::testInvalidDiscoveryNeverReceivesAuthorizationCode` | Discovery status 200 (bad body), 302 or 500 means invalidDiscovery and no token request | omnigent-core::auth::databricks::client | `databricks_invalid_discovery_never_exchanges` | inline | port + mock HTTP | done | no (already WP7) |

### web/ios: DatabricksOAuthTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `DatabricksOAuthTests.swift::testAcceptsBuildConfigurationOverrides` | Build config accepts custom client id and HTTPS redirect URL | omnigent-core::auth::databricks::config | `databricks_oauth_config_accepts_overrides` | inline | port | done | no (already WP7) |
| `DatabricksOAuthTests.swift::testRejectsMissingOrUnexpandedClientID` | Empty, blank, newline-containing or unexpanded $( client id rejected | omnigent-core::auth::databricks::config | `databricks_oauth_config_rejects_bad_client_id` | inline | port | done | no (already WP7) |
| `DatabricksOAuthTests.swift::testRequiresUnambiguousHTTPSCallback` | Redirect must be unambiguous HTTPS with no userinfo, port, query or fragment | omnigent-core::auth::databricks::config | `databricks_oauth_config_requires_unambiguous_https_redirect` | inline | port | done | no (already WP7) |
| `DatabricksOAuthTests.swift::testUsesWorkspaceIssuerAndPublicClientPKCE` | Authorize URL uses workspace host /oidc/v1/authorize, S256 PKCE, scope all-apis offline_access, o= kept | omnigent-core::auth::databricks::attempt | `databricks_authorize_url_uses_workspace_and_pkce` | inline | port | done | no (already WP7) |
| `DatabricksOAuthTests.swift::testPKCEMatchesRFC7636Vector` | PKCE S256 challenge matches RFC 7636 test vector | omnigent-core::auth::databricks::attempt | `pkce_s256_matches_rfc7636_vector` | inline | port | done | no |
| `DatabricksOAuthTests.swift::testEachAttemptHasFreshIndependentStateAndVerifier` | Each attempt gets fresh 43-char state and verifier from the unreserved charset | omnigent-core::auth::databricks::attempt | `databricks_attempt_state_and_verifier_are_fresh` | inline | port | done | no (already WP7) |
| `DatabricksOAuthTests.swift::testRejectsNonWorkspaceAndInsecureIssuers` | Non-workspace, http, apps, userinfo or port workspace URLs rejected with invalidWorkspace | omnigent-core::auth::databricks::attempt | `databricks_attempt_rejects_non_workspace_issuers` | inline | port | done | no (already WP7) |
| `DatabricksOAuthTests.swift::testValidatesConfiguredCallbackAndState` | Callback must match redirect exactly with matching state; code is percent-decoded | omnigent-core::auth::databricks::attempt | `databricks_callback_validates_redirect_and_state` | inline | port | done | no (already WP7) |
| `DatabricksOAuthTests.swift::testRejectsMissingDuplicateAndMixedCallbackParameters` | Missing, empty, duplicate or mixed code, state and error params rejected as invalidCallback | omnigent-core::auth::databricks::attempt | `databricks_callback_rejects_missing_duplicate_mixed_params` | inline | port | done | no (already WP7) |
| `DatabricksOAuthTests.swift::testProviderErrorsAreSanitizedAndStillRequireState` | access_denied and server_error map to fixed errors; description text never surfaced; state still required | omnigent-core::auth::databricks::attempt | `databricks_provider_errors_sanitized_and_need_state` | inline | port | done | no (already WP7) |
| `DatabricksOAuthTests.swift::testExchangeFormEncodesOpaqueValuesWithoutSecretsInURL` | Token request is POST form with percent-encoded opaque values, no client_secret, no '+' in body | omnigent-core::auth::databricks::attempt | `databricks_token_form_percent_encodes_opaque_values` | inline | port | done | no (already WP7) |

### web/ios: DatabricksTokenManagerTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `DatabricksTokenManagerTests.swift::testMissingAndUsableCredentialsNeverRefresh` | Missing returns nil; usable tokens load without refresh | omnigent-core::auth::databricks::token_manager | `token_manager_missing_and_usable_never_refresh` | inline | port + fake store | done | no (already WP7) |
| `DatabricksTokenManagerTests.swift::testRefreshesAtSafetyBoundaryAndPersistsRotationBeforeReturning` | Refresh starts at safety margin; rotated tokens persisted before returning | omnigent-core::auth::databricks::token_manager | `token_manager_refresh_at_margin_persists_before_return` | inline | port + fake store | done | no (already WP7) |
| `DatabricksTokenManagerTests.swift::testConcurrentWaitersShareRefreshAndOneCancellationDoesNotCancelOthers` | Concurrent waiters share one refresh; cancelling one waiter leaves the refresh running for others | omnigent-core::auth::databricks::token_manager | `token_manager_waiters_share_refresh_and_survive_cancel` | inline | port | done | no (already WP7) |
| `DatabricksTokenManagerTests.swift::testRefreshStillPersistsAfterAllOriginalWaitersCancel` | Refresh still persists rotated tokens after every original waiter is cancelled | omnigent-core::auth::databricks::token_manager | `token_manager_refresh_persists_after_all_waiters_cancel` | inline | port | done | no (already WP7) |
| `DatabricksTokenManagerTests.swift::testDifferentWorkspacesDoNotShareRefreshOperations` | Refreshes for two workspace scopes run independently | omnigent-core::auth::databricks::token_manager | `token_manager_scopes_do_not_share_refresh` | inline | port | done | no (already WP7) |
| `DatabricksTokenManagerTests.swift::testInvalidGrantClearsOnlyMatchingScopeAndRequiresReauthentication` | invalidRefreshGrant returns nil and clears only the matching scope | omnigent-core::auth::databricks::token_manager | `token_manager_invalid_grant_clears_only_matching_scope` | inline | port + fake store | done | no (already WP7) |
| `DatabricksTokenManagerTests.swift::testTransientErrorsAndMalformedResponsesRetainCredentials` | networkUnavailable, tokenExchangeFailed, invalidTokenResponse keep saved credentials | omnigent-core::auth::databricks::token_manager | `token_manager_transient_errors_retain_credentials` | inline | port + fake store | done | no (already WP7) |
| `DatabricksTokenManagerTests.swift::testLockedKeychainDoesNotBecomeMissingCredentials` | Store load failure is an error, not missing credentials; no refresh attempted (Keychain stays Swift) | omnigent-core::auth::databricks::token_manager | `token_manager_store_error_is_not_missing` | inline | port logic, Swift shim | done | no (already WP7) |
| `DatabricksTokenManagerTests.swift::testFailedRotationWriteRetriesPersistenceWithoutReusingOldGrant` | Failed write after rotation surfaces error; retry persists rotated tokens with one refresh call | omnigent-core::auth::databricks::token_manager | `token_manager_failed_rotation_write_retries_without_reuse` | inline | port + fake store | done | no (already WP7) |
| `DatabricksTokenManagerTests.swift::testRejectsRefreshThatDropsIssuerContext` | Refresh response that drops issuer context is invalidTokenResponse; saved tokens kept | omnigent-core::auth::databricks::token_manager | `token_manager_rejects_refresh_dropping_issuer` | inline | port + fake store | done | no (already WP7) |
| `DatabricksTokenManagerTests.swift::testSameOriginWorkspaceContextsKeepTheirOwnTokens` | Two workspaces on same origin with different o= keep separate tokens; clear affects one | omnigent-core::auth::databricks::token_manager | `token_manager_same_origin_workspaces_keep_own_tokens` | inline | port + fake store | done | no (already WP7) |
| `DatabricksTokenManagerTests.swift::testFailedClearDoesNotAllowOldCredentialsToReappear` | Failed delete surfaces error; later reads return nil and do not refresh old tokens | omnigent-core::auth::databricks::token_manager | `token_manager_failed_clear_does_not_resurrect` | inline | port + fake store | done | no (already WP7) |
| `DatabricksTokenManagerTests.swift::testClearAndNewLoginRejectLateRefreshResults` | Late refresh result after clear or new login is discarded (success or failure) | omnigent-core::auth::databricks::token_manager | `token_manager_late_refresh_rejected_after_clear_or_login` | inline | port | done | no (already WP7) |
| `DatabricksTokenManagerTests.swift::testRejectedUnexpiredAccessTokenCanBeRefreshedOnce` | refresh(rejected:) refreshes an unexpired but server-rejected token once | omnigent-core::auth::databricks::token_manager | `token_manager_rejected_unexpired_refreshes_once` | inline | port + fake store | done | no (already WP7) |
| `DatabricksTokenManagerTests.swift::testRejectedTokenCannotRefreshANewerLogin` | Rejected token that no longer matches stored tokens yields changed error; no refresh | omnigent-core::auth::databricks::token_manager | `token_manager_rejected_stale_token_cannot_refresh_newer` | inline | port + fake store | done | no (already WP7) |

### web/ios: DatabricksWebContextTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `DatabricksWebContextTests.swift::testStableStoreIdentitySeparatesWorkspacesAndClients` | Store identifier stable across equivalent URLs; differs by workspace and client; pageURL normalized | omnigent-core::auth::databricks::web_context | `web_context_store_identity_separates_workspace_and_client` | inline | port | done | no (already WP7) |
| `DatabricksWebContextTests.swift::testAppsAndGenericServersKeepTheirExistingStrategy` | Apps and generic servers resolve to no Databricks context; login and authorize URLs rejected | omnigent-core::auth::databricks::web_context | `web_context_apps_and_generic_have_no_databricks_context` | inline | port | done | no (already WP7) |
| `DatabricksWebContextTests.swift::testNavigationBindingRejectsOtherWorkspacesAndLoginDestinations` | Navigation normalizes to bound workspace; other workspace, login and http destinations rejected | omnigent-core::auth::databricks::web_context | `web_session_navigation_binds_to_workspace` | inline | port | done | no (already WP7) |

### web/ios: DatabricksWorkspaceBootstrapTests.swift

| Source::test | Behaviour | Rust crate::module | Rust test | Fixture(s) | Port mode | Status | Split? |
|---|---|---|---|---|---|---|---|
| `DatabricksWorkspaceBootstrapTests.swift::testCachedGrantSkipsBrowserAndWaitsForCookieInstallation` | Cached grant skips browser login and creates session; cookie write completes before prepare returns | omnigent-core::auth::databricks::bootstrap | `bootstrap_cached_grant_skips_login` | inline | port + fake store | done | no (already WP7) |
| `DatabricksWorkspaceBootstrapTests.swift::testInteractiveLoginClearsOnlySelectedWebStore` | No grant starts browser login; only the selected store is cleared, other store untouched | omnigent-core::auth::databricks::bootstrap | `bootstrap_interactive_login_clears_only_selected_store` | inline | port + fake store | done | no (already WP7) |
| `DatabricksWorkspaceBootstrapTests.swift::testFailedCookieBootstrapCannotLeaveOldAccountDataForTheNextAttempt` | Failed session after store clear leaves store empty; next attempt logs in again | omnigent-core::auth::databricks::bootstrap | `bootstrap_failed_session_leaves_no_old_store_data` | inline | port + fake store | done | no (already WP7) |
| `DatabricksWorkspaceBootstrapTests.swift::testStorageAndSessionErrorsDoNotTriggerBrowserFallbackOrInstallCookies` | Storage error or session 403 never starts browser or writes cookies; grant kept | omnigent-core::auth::databricks::bootstrap | `bootstrap_storage_and_session_errors_no_browser_fallback` | inline | port + fake store | done | no (already WP7) |
| `DatabricksWorkspaceBootstrapTests.swift::testCancellationDuringSessionRequestDiscardsLateResult` | Cancel during session request discards late result; no store writes | omnigent-core::auth::databricks::bootstrap | `bootstrap_cancel_discards_late_session_result` | inline | port + fake store | done | no (already WP7) |
| `DatabricksWorkspaceBootstrapTests.swift::testWrongStoreCannotReceiveWorkspaceCookies` | Store with another identifier rejected with workspaceChanged; no login or session call | omnigent-core::auth::databricks::bootstrap | `bootstrap_wrong_store_identifier_rejected` | inline | port | done | no (already WP7) |
| `DatabricksWorkspaceBootstrapTests.swift::testClearedGrantCannotInstallACompletedCookieExchange` | Grant cleared during session exchange rejects completion with credentialsChanged; no cookies installed | omnigent-core::auth::databricks::bootstrap | `bootstrap_cleared_grant_rejects_completed_exchange` | inline | port + fake store | done | no (already WP7) |
| `DatabricksWorkspaceBootstrapTests.swift::testCancellationReturnsToSetupWithoutAnErrorMessage` | Cancellation and DatabricksSessionError.cancelled produce no user message | omnigent-core::auth::databricks::error | `error_cancellation_has_no_message` | inline | port logic, Swift shim | done | no |
| `DatabricksWorkspaceBootstrapTests.swift::testConfigurationAndSessionFailuresStillHaveMessages` | Config, missing cookie, network and rejected(403) errors keep localized messages | omnigent-core::auth::databricks::error | `error_auth_failures_keep_messages` | inline | port logic, Swift shim | done | no |
| `DatabricksWorkspaceBootstrapTests.swift::testUnreachableManagedHostKeepsTheSharedPageLoadGuidance` | Unreachable host gives same guidance as page-load path; cancellation stays silent | omnigent-core::auth::databricks::error | `error_unreachable_workspace_matches_page_guidance` | inline | port logic, Swift shim | done | no |
| `DatabricksWorkspaceBootstrapTests.swift::testSilentRecoveryDoesNotPresentBrowserWhenGrantIsMissing` | Recover intent with no grant gives reauthenticationRequired; no login or session call | omnigent-core::auth::databricks::bootstrap | `bootstrap_recover_without_grant_requires_reauth` | inline | port + fake store | done | no (already WP7) |
| `DatabricksWorkspaceBootstrapTests.swift::testRecoveryPreservesCurrentPageWithoutChangingCredentialContext` | Recovery keeps current page URL; no alias credential scope created | omnigent-core::auth::databricks::bootstrap | `bootstrap_recovery_preserves_page_url` | inline | port + fake store | done | no (already WP7) |
| `DatabricksWorkspaceBootstrapTests.swift::testSession401RefreshesOnceThenRetriesWithoutBrowser` | Session 401 refreshes token once, retries session, no browser | omnigent-core::auth::databricks::bootstrap | `bootstrap_session_401_refreshes_once_then_retries` | inline | port + mock HTTP | done | no (already WP7) |
| `DatabricksWorkspaceBootstrapTests.swift::testRepeated401DoesNotLoopOrEraseAValidRefreshGrant` | Repeated 401 bounded to two session calls and one refresh; grant kept | omnigent-core::auth::databricks::bootstrap | `bootstrap_repeated_401_bounded_keeps_grant` | inline | port + mock HTTP | done | no (already WP7) |
| `DatabricksWorkspaceBootstrapTests.swift::testDebugTokenFaultsKeepTheRefreshGrantUntilItIsTheChosenFault` | DEBUG token faults (expiry, access, refresh) mutate only the chosen field | omnigent-core::auth::databricks::bootstrap | `bootstrap_debug_token_faults_touch_only_chosen_field` | inline | port + fake store | done | no (already WP7) |
| `DatabricksWorkspaceBootstrapTests.swift::testDebugFaultNeedsSavedCredentialsAndTheSelectedStore` | Fault needs saved credentials; store from another workspace rejected | omnigent-core::auth::databricks::bootstrap | `bootstrap_debug_fault_needs_credentials_and_store` | inline | port + fake store | done | no (already WP7) |
| `DatabricksWorkspaceBootstrapTests.swift::testInjectedAccessTokenFaultRecoversWithoutBrowserSignIn` | Injected access-token fault recovers via one refresh; no browser sign-in | omnigent-core::auth::databricks::bootstrap | `bootstrap_injected_access_fault_recovers_without_login` | inline | port + mock HTTP | done | no (already WP7) |
| `DatabricksWorkspaceBootstrapTests.swift::testInjectedRefreshFaultAsksForSignInInsteadOfOpeningTheBrowser` | Injected refresh fault (invalid_grant) clears grant and asks for sign-in; no browser | omnigent-core::auth::databricks::bootstrap | `bootstrap_injected_refresh_fault_requires_reauth` | inline | port + mock HTTP | done | no (already WP7) |
| `DatabricksWorkspaceBootstrapTests.swift::testRecoveryRequiresHealthyPageAndCooldownBeforeAnotherAttempt` | Recovery needs a healthy-page mark and a 60-second cooldown before another attempt (DatabricksRecoveryPolicy) | omnigent-core::auth::databricks::bootstrap | `recovery_policy_requires_ready_and_cooldown` | inline | port | done | no (already WP7) |
| `DatabricksWorkspaceBootstrapTests.swift::testRecoveryPageKeepsStoreIdentityAndRejectsAnotherWorkspace` | context.navigating keeps scope and store id; other workspace rejected | omnigent-core::auth::databricks::web_context | `web_context_navigating_keeps_store_rejects_other_workspace` | inline | port | done | no (already WP7) |
| `DatabricksWorkspaceBootstrapTests.swift::testSignOutClearsOnlyItsContextAndSuppressesAutoOpen` | Sign-out clears only its context's tokens and suppresses auto-open for it | omnigent-core::auth::databricks::bootstrap | `sign_out_clears_only_its_context_and_suppresses_auto_open` | inline | port + fake store | done | no (already WP7) |
| `DatabricksWorkspaceBootstrapTests.swift::testFailedSignOutIsRetriedAfterManagerRecreationBeforeNewLogin` | Failed sign-out pending marker survives manager recreation; retried before new login (marker persistence in UserDefaults stays Swift) | omnigent-core::auth::databricks::bootstrap | `sign_out_failed_retried_before_new_login` | inline | port logic, Swift shim | done | no (already WP7) |
| `DatabricksWorkspaceBootstrapTests.swift::testPendingSignOutRejectsLateCookieBootstrap` | Pending sign-out rejects late bootstrap with credentialsChanged; no cookie write | omnigent-core::auth::databricks::bootstrap | `sign_out_pending_rejects_late_bootstrap` | inline | port + fake store | done | no (already WP7) |
| `DatabricksWorkspaceBootstrapTests.swift::testCompletedSignOutRejectsLateBootstrapEvenIfCredentialsReappear` | Completed sign-out generation rejects late bootstrap even if credentials reappear | omnigent-core::auth::databricks::bootstrap | `sign_out_completed_generation_rejects_late_bootstrap` | inline | port + fake store | done | no (already WP7) |
| `DatabricksWorkspaceBootstrapTests.swift::testLogoutURLsAreDistinctFromExpiredLoginAndOtherContexts` | /auth/logout, /logout, login.html?logout=1 are sign-out URLs; login.html is auth; other contexts excluded | omnigent-core::auth::databricks::web_context | `logout_urls_distinct_from_login_and_other_contexts` | inline | port | done | no (already WP7) |
| `DatabricksWorkspaceBootstrapTests.swift::testCoordinatorRecovers401ButDoesNotRetry403` | Workspace HTTP 401 triggers one recovery; 403 surfaces failure message without retry | omnigent-core::auth::databricks::bootstrap | `workspace_http_status_401_recovers_403_fails` | inline | port logic, Swift shim | done | no (already WP7) |

## Stays Swift

These tests exercise WebView, UIKit, SwiftUI, Keychain, WebKit cookie stores or
`ASWebAuthenticationSession`. They are not ported; they move with the Swift code into
`OmnigentServices` / `OmnigentPlatform`. NativeLab rows marked `keep Swift` in the package
tables above are repeated here; their portable part is named in the module column.

| Source::test | Behaviour | Reason | Status |
|---|---|---|---|
| `HostedServerAuthenticationTests.swift::testDelegateRejectsRedirectAndUsesPlatformTLSValidation` | URLSession delegate cancels redirects and defers only server-trust challenges to the platform | omnigent-core::auth | stays Swift |
| `SecureServerStoreTests.swift::testPreferencesContainOnlyAccountMetadata` | Saved account ID is server URL plus newline plus user ID; metadata JSON has no token; an invalid token is refused before persisting | UserDefaults/Keychain); portable part omnigent-core::auth | stays Swift |
| `SecureServerStoreTests.swift::testKeychainSeparatesAccountsAndMountsAndDeletesOnlySelectedCredential` | Keychain credentials stay separate per account and mount; removing one leaves the others | Keychain CRUD); portable part omnigent-core::auth | stays Swift |
| `SecureServerStoreTests.swift::testKeychainSeparatesDatabricksWorkspacesForTheSameAccount` | The same user on two Databricks workspaces (o=123 and o=456) keeps separate credentials | Keychain CRUD); portable part omnigent-core::auth | stays Swift |
| `DatabricksCredentialStoreTests.swift::testKeychainRoundTripRotationAndScopedDeletion` | Keychain save, load, rotate and scoped delete with accessibility attributes | Keychain | stays Swift |
| `DatabricksLoginManagerTests.swift::testStartFailureAndUserCancellationReleaseSession` | Browser start failure gives browserUnavailable; user cancel releases session | ASWebAuthenticationSession | stays Swift |
| `DatabricksLoginManagerTests.swift::testCancellingCallerCancelsBrowser` | Cancelling the caller task cancels the browser session | ASWebAuthenticationSession | stays Swift |
| `DatabricksLoginManagerTests.swift::testAlreadyCancelledCallerDoesNotPresentBrowser` | Task cancelled before start never presents the browser | ASWebAuthenticationSession | stays Swift |
| `DatabricksOAuthTests.swift::testReadsProcessedBuildSettings` | Reads processed DatabricksOAuthClientID and redirect from Info.plist | Info.plist/Bundle | stays Swift |
| `DatabricksWebContextTests.swift::testNamedWebKitStoresPersistSeparatelyAndClearOnlyTheirOwnData` | Named WKWebsiteDataStore per context; cookies persist and clear per store | WebKit | stays Swift |
| `DatabricksWebContextTests.swift::testCookieInstallerWaitsForCanceledWritesBeforeReplacingSession` | Cookie install serializes writes: waits for canceled write before clear and new write | WebKit cookie store | stays Swift |
| `DatabricksWebContextTests.swift::testCookieInstallerValidatesBeforeMutatingTheStore` | Installer validates before touching the cookie store; failed validation leaves store untouched | WebKit cookie store | stays Swift |
| `DatabricksWorkspaceBootstrapTests.swift::testCoordinatorLoadsOnlyAfterNativeBootstrapIntoItsNamedStore` | WKWebView loads only after native bootstrap, in its named store, with server switcher state | WebView | stays Swift |
| `DatabricksWorkspaceBootstrapTests.swift::testCoordinatorDetachDefersPublishedCleanupUntilAfterTeardown` | Coordinator detach defers published model cleanup past teardown | WebView/SwiftUI | stays Swift |
| `DatabricksWorkspaceBootstrapTests.swift::testDebugCookieFaultClearsOnlyTheSessionCookie` | DEBUG fault clears only the DBAUTH cookie from WKHTTPCookieStore | WKHTTPCookieStore, DEBUG harness | stays Swift |
| `DatabricksWorkspaceBootstrapTests.swift::testSignOutWaitsBehindAnAlreadyStartedCookieWrite` | Sign-out waits for an already-started WebKit cookie write, then clears | WKHTTPCookieStore | stays Swift |
| `DatabricksWorkspaceBootstrapTests.swift::testForegroundMissingCookieRequestsOneRecovery` | Foreground activation with missing cookie requests one recovery (UIApplication notification) | UIApplication, WKHTTPCookieStore | stays Swift |
| `DatabricksWorkspaceBootstrapTests.swift::testNativeSignOutActionDetachesAndCompletesScopedCleanup` | Native sign-out bridge action detaches view and completes scoped cleanup | WebView bridge | stays Swift |
| `DeepLinkTests.swift::testThemeSourceMapsToUserInterfaceStyle` | ThemeSource maps to UIUserInterfaceStyle | UIKit | stays Swift |
| `DeepLinkTests.swift::testThemeSourceMapsToColorScheme` | ThemeSource maps to SwiftUI ColorScheme | SwiftUI | stays Swift |
| `DeepLinkTests.swift::testThemeSourceParsesFromRawString` | ThemeSource raw-string parsing (UI enum) | theme UI enum | stays Swift |
| `KeyboardViewportTests.swift::testCompactHardwareToolbarKeepsFullHeight` | iPad hardware toolbar frame keeps full viewport height | UIKit keyboard frame | stays Swift |
| `KeyboardViewportTests.swift::testHardwareToolbarTransitionNeverShrinksTheViewport` | Hardware toolbar transition frames never shrink viewport | UIKit keyboard frame | stays Swift |
| `KeyboardViewportTests.swift::testHardwareKeyboardDoesNotSuppressTheFullSoftwareKeyboard` | Software keyboard still reserves space with hardware keyboard attached | UIKit keyboard frame | stays Swift |
| `KeyboardViewportTests.swift::testShortDockedFrameIsPreservedWithoutAnIPadHardwareKeyboard` | Short docked frame preserved without hardware keyboard | UIKit keyboard frame | stays Swift |
| `KeyboardViewportTests.swift::testFloatingKeyboardKeepsFullHeightEvenAtBottomEdge` | Floating keyboard keeps full height | UIKit keyboard frame | stays Swift |
| `KeyboardViewportTests.swift::testUndockedFullWidthKeyboardKeepsFullHeight` | Undocked full-width keyboard keeps full height | UIKit keyboard frame | stays Swift |
| `KeyboardViewportTests.swift::testDockedSoftwareKeyboardReservesSpaceInBothOrientations` | Docked software keyboard reserves space in landscape and portrait | UIKit keyboard frame | stays Swift |
| `KeyboardViewportTests.swift::testDismissedKeyboardKeepsFullHeight` | Dismissed or zero-size keyboard keeps full height | UIKit keyboard frame | stays Swift |
| `KeyboardViewportTests.swift::testNewDocumentReceivesGeometryBeforeSlowResourcesFinish` | New document gets native viewport geometry before pending resources finish (WKWebView) | WebView | stays Swift |
| `KeyboardViewportTests.swift::testNativePanLockLeavesInnerScrollersAndOtherDocumentsScrollable` | Pan lock on page scroll view only during provisional navigation; inner scrollers unaffected (UIScrollView) | UIKit scroll view | stays Swift |
| `ManagedConfigurationTests.swift::testOurErrorCodesAreNotSystemReserved` | Our codes are below ManagedApp's reserved range | ManagedApp framework codes | stays Swift |
| `OidcCredentialStoreTests.swift::testKeychainRoundTripIsPerOriginAndDeviceOnly` | Keychain save, load, delete per origin, device-only attributes (grant JSON v1 shape noted) | Keychain | stays Swift |
| `OidcCredentialsTests.swift::testCancellingSignInCancelsSheet` | Cancelling sign-in cancels the browser sheet | ASWebAuthenticationSession | stays Swift |
| `OidcCredentialsTests.swift::testSheetStartFailureIsBrowserUnavailable` | Sheet start failure gives browserUnavailable | ASWebAuthenticationSession | stays Swift |
| `OidcWebSessionTests.swift::testPayloadCarriesCanSignOut` | Server picker JSON payload carries canSignOut, origins and recents (WebView bridge payload) | WebView bridge | stays Swift |
| `OidcWebSessionTests.swift::testBridgeExposesSignOutOfServerForEveryConnectionAndPassesCanSignOut` | JS bridge exposes signOutOfServer and canSignOut mapping | WKUserScript bridge | stays Swift |
| `OidcWebSessionTests.swift::testPersistedCookiesLoadBeforeTheyAreRead` | Cold WebKit cookie jar loads persisted cookies before reading (class OidcPersistedCookiesTests) | WKHTTPCookieStore | stays Swift |
| `ServerSwitcherVisibilityTests.swift::testSidebarSelectionHidesTheNativeSwitcherForEveryServerKind` | Native switcher visibility follows serverSwitcherHidden flag (SwiftUI state) | SwiftUI view state | stays Swift |
| `ServerSwitcherVisibilityTests.swift::testWatchdogRevealsTheWorkspaceSwitcherWhenThePageDoesNotRespond` | Watchdog reveals switcher after timeout (Combine timer) | Combine timer | stays Swift |
| `ServerSwitcherVisibilityTests.swift::testCancelledWatchdogKeepsSelectionInTheSidebar` | Cancelled watchdog never reveals switcher | Combine timer | stays Swift |
| `ServerURLTests.swift::testAppSupportsIPhoneAndIPad` | UIDeviceFamily in Info.plist is [1, 2] | Info.plist/UIKit | stays Swift |
| `ServerURLTests.swift::testIPadSupportsAllOrientations` | iPad supported orientations in Info.plist | Info.plist/UIKit | stays Swift |
| `ServerURLTests.swift::testPrivacyUsageDescriptionsArePresent` | Camera, microphone, speech usage strings in Info.plist | Info.plist | stays Swift |
| `ThemeBackgroundTests.swift::testExplicitThemesColorTheWindowAndHostingView` | Explicit light/dark theme colors window and hosting view | UIKit window | stays Swift |
| `ThemeBackgroundTests.swift::testSystemThemeBackgroundsResolveForBothAppearances` | System theme resolves backgrounds in both appearances | UIKit window | stays Swift |
| `ThemeBackgroundTests.swift::testSwitchingThemesUpdatesAnExistingWindow` | Switching theme updates existing window | UIKit window | stays Swift |
| `ThemeBackgroundTests.swift::testOverlayWindowsKeepTheirTransparentBackgrounds` | Overlay windows keep transparent backgrounds | UIKit window | stays Swift |
| `WebAuthenticationBrowserTests.swift::testReturnsCallbackURLForTheRequestedCallback` | Returns callback URL for matching callback; late completion ignored | ASWebAuthenticationSession | stays Swift |
| `WebAuthenticationBrowserTests.swift::testStartFailureIsUnavailable` | Start failure gives unavailable | ASWebAuthenticationSession | stays Swift |
| `WebAuthenticationBrowserTests.swift::testRejectsSecondPresentation` | Second presentation rejected with inProgress | ASWebAuthenticationSession | stays Swift |
| `WebAuthenticationBrowserTests.swift::testCompletionErrorsMapToBrowserErrors` | Canceled, failed, missing-callback completions map to browser errors | ASWebAuthenticationSession | stays Swift |
| `WebAuthenticationBrowserTests.swift::testCancelResumesWithoutCompletionAndIgnoresStaleCallback` | Cancel resumes without completion; stale callback ignored | ASWebAuthenticationSession | stays Swift |
| `WebAuthenticationBrowserTests.swift::testCancellingCallerCancelsSession` | Cancelling caller cancels session | ASWebAuthenticationSession | stays Swift |
| `WebAuthenticationBrowserTests.swift::testAlreadyCancelledCallerDoesNotPresent` | Already-cancelled caller never presents | ASWebAuthenticationSession | stays Swift |
| `WorkspaceChromeScriptTests.swift::testCSSPromotesTheEmbedRootToAFullViewportOverlay` | Chrome-hide CSS identical to Electron and Android copies | JS injection | stays Swift |
| `WorkspaceChromeScriptTests.swift::testSourceInstallsTheStylesheetAtMostOncePerDocument` | Injected script installs stylesheet at most once per document | JS injection | stays Swift |
| `WorkspaceChromeScriptTests.swift::testSourceEmbedsTheCSSAsAnEscapedStringLiteral` | CSS embedded as escaped string literal in script | JS injection | stays Swift |
