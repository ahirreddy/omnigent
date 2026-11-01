# Item and history fixtures

Formats:

- **`.json`**: one payload, or one HTTP exchange envelope.
- **`.jsonl`**: an ordered sequence, one JSON value per line:
  - an event sequence: one stream event object (the SSE `data:` payload) per line, in apply order;
  - SSE frames: `{id, event, data, raw?}`, where `data` is parsed JSON when the payload is JSON;
    `raw` is the exact frame text and is present where bytes matter;
  - an HTTP script: one envelope per line, served in file order per (method, path);
  - WebSocket: `{direction: "send"|"recv", message}`.
- **HTTP envelope**:
  - `{"request": {"method", "path", "query"?, "body"?}, "status", "headers"?, "response"}`.
  - `response` is a string when the body is not JSON. `error` replaces status and response for transport failures.
  - Optional fields: `response_url`, `delay_ms`, and `response_base64`/`response_generated` for binary bodies.
  - `query` lists only the parameters the test asserts.
  - Hosted and Databricks paths include the mount `/api/2.0/omnigent`.

Naming:

- `recorded-*` was captured from a real server; see below.
- `<SwiftSuiteStem>--<TestNameWithoutTestPrefix>[--<label>]` was extracted from that NativeLab test (see
  `client-core/docs/port-checklist.md` for the Rust test that uses it).
- `<Suite>--_shared--*` is a payload shared by several tests in one suite.
- `EventGallery--*` and `DemoFixtures--*` come from `EventGalleryFixtures.swift` and `DemoFixtures.swift`.

Fixtures carry inputs only. Each bullet below states the expected outcome, and the Rust test asserts it.
Swift string interpolation was resolved to the concrete values each test uses, and loops were unrolled in order.

## Recorded from a live server

Recorded on 2026-10-31 from this repo's own server, `python -m omnigent server` on 127.0.0.1, with an isolated data/config home and a sibling `python -m omnigent.runner._entry`. The agent was `fixture_agent` (harness `openai-agents`, model `gpt-4o-mini`). Its LLM was the repo's scripted Responses-API mock, `tests/server/integration/mock_llm_server.py`, so no provider credentials were used. Turn 1 makes a `sys_os_shell` tool call (`echo fixture-hello`) and then streams text; turns 2 and 3 stream text only. Loopback single-user mode, no auth headers. Placeholders: hosts are `127.0.0.1:8000` or `{{base_url}}`, runner ids are `runner_token_placeholder`, and the tool cwd is under `/workspace/...`. Session, item and timestamp values are real and consistent across `sse/`, `items/` and `sessions/`.

- `recorded-items-page-1.json`: `GET /v1/sessions/{id}/items?limit=2&order=asc`, first page with no cursor. Envelope `{object, data, first_id, last_id, has_more}`.
- `recorded-items-page-2.json`: Second page: `after` is page 1's `last_id` (an opaque 32-hex item id).
- `recorded-items-page-3.json`: Last page: `has_more: false`. Pages 1-3 hold 6 items: user message, function_call, function_call_output, assistant message, user message, assistant message.
- `recorded-items-desc-page-1.json`: `order=desc&limit=2` sample: newest first.
- `recorded-session-snapshot-after-turn.json`: `GET /v1/sessions/{id}` (default `include_items=true`) after turns 1 and 2. A full `SessionResponse` with `items[]`, `pending_inputs`, `usage_by_model`, `runner_online` and `status`.

## Extracted from reducer-side NativeLab tests

- `ConversationItemPresentation--AttachmentDescriptorsPreserveTextWithoutEmbeddingOrFetchingContent.json`: User message with text plus image(file1), file(file2, application/pdf), inline image data URL and inline audio. Expect text 'Inspect these', attachment kinds [image,file,image,audio], embedded ones have no reference, no 'PRIVATE_' bytes in the encoded message.
- `ConversationItemPresentation--JSONEncodedToolArgumentsAndOutputAreSanitized.json`: Function call whose JSON-string arguments carry query 'weather' and api_key; output whose JSON string carries answer 'Clear skies' and refresh_token. Expect call text has 'weather', callID c1, responseID r1; output has 'Clear skies'; no PRIVATE_KEY/PRIVATE_TOKEN.
- `ConversationItemPresentation--LegacyConversationMessagesDecodeWithoutNewFields.json`: Legacy ConversationMessage (no activity/attachments/responseID/callID/interrupted/author/agent). Note: this is a ConversationMessage, not an ItemWire payload. Expect decode ok, text 'Hello', all new fields nil, round-trip equal.
- `ConversationItemPresentation--MessageAttributionPreservesHumanAndAgentIdentity.json`: Two messages: user created_by person (human author) and assistant model child-agent (agent). Expect user.author set and agent nil; assistant.agent set and author nil.
- `ConversationItemPresentation--MessagePrivateBlocksDoNotBecomeUnknownContentCards.json`: Assistant message mixing private thinking/redacted/reasoning blocks with one output_text. Expect text 'Visible', activity nil, no PRIVATE in the encoding.
- `ConversationItemPresentation--NestedUnknownPayloadSanitizesCredentialsAndPrivateReasoning.json`: Unknown future_result item with credentials, encrypted content, reasoning text and image data nested in payload. Expect kind unknown, 'Kept result' and 'Public output' kept, every PRIVATE_ value removed.
- `ConversationItemPresentation--NewContentBlocksHaveUsefulSafeDetails.json`: Assistant message with an unknown future_chart content block. Expect activity kind unknown, detail mentions 'Quarterly totals', no 'PRIVATE'.
- `ConversationItemPresentation--ReasoningNeverFallsBackToRawOrEncryptedContent.json`: Reasoning r1 with a summary_text plus hidden blocks and encrypted_content; r2 with no summary but a raw text block. Expect summary 'Checked the available options.' only; r2 summary 'No public reasoning summary was provided.'; no HIDDEN_/ENCRYPTED_/PRIVATE text anywhere.
- `ConversationItemPresentation--RefusalsAndInterruptedMessagesRemainVisible.json`: Interrupted assistant message with output text and a refusal block. Expect text 'Partial response\nI cannot provide that.' and interrupted true.
- `EventParity--AllSixteenPersistedFamiliesHaveMeaningfulTypedPresentation.json`: 16 persisted item families (message, function_call, function_call_output, error, reasoning, compaction, slash_command, routing_decision, terminal_command, and 7 native tool types), decoded with id item-<type>, response_id fixture-response, status completed. Expect 16 distinct typed presentations, each with visible content and no 'preview not supported'.
- `EventParity--ContextFilteringMatchesWholeLegacyNotificationNotLooseMarkers.json`: Six user message items. Items 1-2 are legacy context/notification messages that must be hidden; items 3-5 are visible text that merely mention the markers; item 6 has is_meta true and must be hidden. Expect nil for hidden, exact text for visible.
- `EventParity--EveryNativeToolSurvivesWrapperWithoutBecomingUnknown.json`: Seven native_tool wrapper payloads, one per native tool type, each with an inner item carrying fixture_detail 'Visible provider detail' and call_id 'call'. Expect activity kind nativeTool, status completed, callID 'call', detail visible.
- `EventParity--HistoryAndLiveCommitUseSamePresentationForEveryKnownFamily.json`: 16 item payloads (id commit-<type>), each delivered as a response.output_item.done event applied twice in the live path and once as history. Expect identical ConversationMessage for history and live, one row per commit.
- `EventParity--ResourceReceiptsDistinguishCreateAndDeleteWithoutLosingIdentity.json`: Resource created (title 'Terminal created', shows 'Build terminal' and term-1) and deleted (title 'Terminal deleted', shows term-1). Expect kind resource, both show term-1.
- `EventParity--RoutingDistinguishesAppliedFromSuggestion.json`: Applied routing (title 'Using fixture-model') and suggestion (title 'Would have picked fixture-model', agent child-agent, rationale shown). Expect the titles and that the suggestion display contains the rationale and agent.
- `EventParity--SlashReceiptDefaultsToSkillAndPreservesInvocationAndOutput.json`: Three slash_command receipts: no kind (defaults to skill), kind 'skill', kind 'command'. Expect activity kind command, display contains '/fixture:review two files' and 'Receipt output', title prefix 'Command' for kind command else 'Skill'.
- `EventParity--TerminalInputAndOutputStayDistinctAndKeepBothStreams.json`: Terminal input 'echo fixture' (title 'Terminal command') and output with stdout/stderr (title 'Terminal output', detail titles Standard output / Standard error). Expect both streams visible and distinct.
- `EventParity--ToolCallsAndResultsKeepResponseAndCallIdentity.json`: Function call and function_call_output both with call_id 'shared-call', response fixture-response. Expect callID shared-call, responseID fixture-response, id item-<type>.

## Extracted from client-side NativeLab tests

- `LocalServerHydrationStreaming--ConsumedInputIsPublishedImmediatelyAndItsEffectIsNotRepeatedOnHydration--history.json`: HTTP GET /v1/sessions/conv_a/items -> 200 (delayed 400ms); used by LocalServerHydrationStreamingTests.swift::testConsumedInputIsPublishedImmediatelyAndItsEffectIsNotRepeatedOnHydration; expected: session.input.consumed publishes the next user message at once; hydration does not repeat its effect.
- `LocalServerHydrationStreaming--HydratedCommitReplacesLivePreviewWithoutDuplicatingText--history.json`: HTTP GET /v1/sessions/conv_a/items -> 200 (delayed 400ms); used by LocalServerHydrationStreamingTests.swift::testHydratedCommitReplacesLivePreviewWithoutDuplicatingText; expected: the hydrated saved message replaces the live preview; a late indexed replay adds no duplicate text.
- `LocalServerHydrationStreaming--InitialHydrationPublishesUnindexedDeltasBeforeHistoryAndAppliesThemOnce--history.json`: HTTP GET /v1/sessions/conv_a/items -> 200 (delayed 400ms); used by LocalServerHydrationStreamingTests.swift::testInitialHydrationPublishesUnindexedDeltasBeforeHistoryAndAppliesThemOnce; expected: unindexed deltas that arrive during initial hydration publish immediately, then history merges them exactly once.
- `LocalServerHydrationStreaming--RehydrationKeepsGrowingTextAndChunkIndicesWithoutReplayingDeltas--history.json`: HTTP GET /v1/sessions/conv_a/items -> 200 (delayed 400ms); used by LocalServerHydrationStreamingTests.swift::testRehydrationKeepsGrowingTextAndChunkIndicesWithoutReplayingDeltas; expected: rehydration keeps growing native text across indexed chunks and ignores replayed indices.
- `LocalServerHydrationStreaming--ShorterPersistedPrefixCannotReplaceTextThatGrewDuringHydration--history.json`: HTTP GET /v1/sessions/conv_a/items -> 200 (delayed 400ms); used by LocalServerHydrationStreamingTests.swift::testShorterPersistedPrefixCannotReplaceTextThatGrewDuringHydration; expected: a shorter persisted assistant prefix cannot replace text that grew during hydration; the message stays streaming.
- `LocalServerHydrationStreaming--StoppedGenerationCannotPublishLateHydrationOrEvents--history.json`: HTTP GET /v1/sessions/conv_a/items -> 200 (delayed 400ms); used by LocalServerHydrationStreamingTests.swift::testStoppedGenerationCannotPublishLateHydrationOrEvents; expected: after stopWatching, a late hydration result and late deltas publish nothing (reducer stays nil).
- `LocalServerSessionClient--ConversationPageLoadsMetadataAndLatestHistoryWithIncreasingRevisions--items.json`: HTTP GET /v1/sessions/conv_a/items -> 200; used by LocalServerSessionClientTests.swift::testConversationPageLoadsMetadataAndLatestHistoryWithIncreasingRevisions; expected: conversation page combines session metadata (include_items=false) with latest items; revisions increase; waiting maps to needsResponse and read-only.
- `LocalServerSessionClient--EmptyHistoryAndToolOutputs--empty.json`: HTTP GET /v1/sessions/conv_a/items -> 200; used by LocalServerSessionClientTests.swift::testEmptyHistoryAndToolOutputs; expected: empty history yields no messages; function_call_output becomes a tool message with its text.
- `LocalServerSessionClient--EmptyHistoryAndToolOutputs--tool-output.json`: HTTP GET /v1/sessions/conv_a/items -> 200; used by LocalServerSessionClientTests.swift::testEmptyHistoryAndToolOutputs; expected: empty history yields no messages; function_call_output becomes a tool message with its text.
- `LocalServerSessionClient--HiddenMetaMessagesDoNotLeakAndAnAllMetaPageKeepsItsCursor--meta-page.json`: HTTP GET /v1/sessions/conv_a/items -> 200; used by LocalServerSessionClientTests.swift::testHiddenMetaMessagesDoNotLeakAndAnAllMetaPageKeepsItsCursor; expected: is_meta messages are hidden, and a page of only hidden items keeps its cursor so the next page loads.
- `LocalServerSessionClient--HiddenMetaMessagesDoNotLeakAndAnAllMetaPageKeepsItsCursor--visible-page.json`: HTTP GET /v1/sessions/conv_a/items -> 200; used by LocalServerSessionClientTests.swift::testHiddenMetaMessagesDoNotLeakAndAnAllMetaPageKeepsItsCursor; expected: is_meta messages are hidden, and a page of only hidden items keeps its cursor so the next page loads.
- `LocalServerSessionClient--HistoryPagesUseStoredOrderAndPreserveTypedContent.json`: HTTP GET /v1/sessions/conv_a/items -> 200; used by LocalServerSessionClientTests.swift::testHistoryPagesUseStoredOrderAndPreserveTypedContent; expected: history keeps stored order, joins output_text, maps input_image and function_call/reasoning items, and passes the cursor verbatim.
- `LocalServerSessionClient--InventoryFollowsLaterPageAndWatchesPendingSessionOutsideVisiblePage--conv-later-items.json`: HTTP GET /v1/sessions/conv_later/items -> 200; used by LocalServerSessionClientTests.swift::testInventoryFollowsLaterPageAndWatchesPendingSessionOutsideVisiblePage; expected: inventory follows has_more pages (limit 500, kind any, archived included) and finds a pending archived session off the visible page; the WS watch list includes it.
- `LocalServerSessionClient--MalformedPersistedErrorsDoNotHideMissingCauseBehindUnsupportedPreview.jsonl`: 4 HTTP exchange(s) in order: GET /v1/sessions/conv_a/items; GET /v1/sessions/conv_a/items; GET /v1/sessions/conv_a/items ...; used by LocalServerSessionClientTests.swift::testMalformedPersistedErrorsDoNotHideMissingCauseBehindUnsupportedPreview; expected: error items without a usable code or message (missing, blank, whitespace) are malformedResponse, not a fallback preview.
- `LocalServerSessionClient--MalformedResponsesAndHistoryAreNotReportedAsEmptySuccess--items.jsonl`: 4 HTTP exchange(s) in order: GET /v1/sessions/conv_a/items; GET /v1/sessions/conv_a/items; GET /v1/sessions/conv_a/items ...; used by LocalServerSessionClientTests.swift::testMalformedResponsesAndHistoryAreNotReportedAsEmptySuccess; expected: non-JSON, empty-object and wrong-type info responses, plus malformed history items (missing role, bad content, empty id), are malformedResponse.
- `LocalServerSessionClient--PersistedRunnerFailureRemainsReadableAfterReopeningWithoutLastTaskError--history.json`: HTTP GET /v1/sessions/conv_a/items -> 200; used by LocalServerSessionClientTests.swift::testPersistedRunnerFailureRemainsReadableAfterReopeningWithoutLastTaskError; expected: a persisted runner error item becomes a readable tool row with its code; the session failure message survives reopening.
- `SessionConfiguration--SlowHistoryCannotRollbackNewerMetadata--items.json`: HTTP GET /v1/sessions/conv_a/items -> 200 (delayed 200ms); used by SessionConfigurationTests.swift::testSlowHistoryCannotRollbackNewerMetadata; expected: a slow history read cannot roll back a newer model delivered by a list change that arrived meanwhile.
- `SessionConfiguration--SparseListChangeLoadsExternalModelWithoutRunnerEchoOrPolling--items.json`: HTTP GET /v1/sessions/conv_a/items -> 200; used by SessionConfigurationTests.swift::testSparseListChangeLoadsExternalModelWithoutRunnerEchoOrPolling (+1 more); expected: a sparse WS changed frame triggers one hydrating GET that loads the external model, with no mutations or polling.
