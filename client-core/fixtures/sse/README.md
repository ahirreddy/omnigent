# SSE stream fixtures

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

- `recorded-turn-text-tool-completion.jsonl`: Full turn 1 on `GET /v1/sessions/{id}/stream`, which was opened before the POST (19 frames). The frames are, in order: `session.heartbeat` (ready), `session.changed_files.invalidated`, `session.presence`, `session.input.consumed`, `session.status` running, `response.in_progress`, `response.output_item.done` (function_call in progress, then completed), `response.output_item.done` (function_call_output with stdout `fixture-hello\n`), 4x `response.output_text.delta`, `response.output_item.done` (assistant message), `session.model`, `session.usage`, `response.completed`, `session.status` idle. There are no `id:` lines and no `[DONE]`: the stream stays open after idle.
- `recorded-reconnect-last-event-id-turn2.jsonl`: Reconnect sending `Last-Event-ID: 0`, then turn 2 (17 frames). It shows that the server does **not** replay turn 1: the live tail starts with the ready heartbeat. The frames include 6x `response.output_text.delta` and end with `session.status` idle.

## Extracted from client-side NativeLab tests

- `HostedServerAuthentication--SSEUnauthorizedStopsAndPublishesSignInAgainWithoutRetry.json`: HTTP GET /api/2.0/omnigent/v1/sessions/a/stream -> 401; used by HostedServerAuthenticationTests.swift::testSSEUnauthorizedStopsAndPublishesSignInAgainWithoutRetry; expected: a 401 from the SSE stream publishes a failed sign-in state and does not reconnect.
- `LocalServerHydrationStreaming--ConsumedInputIsPublishedImmediatelyAndItsEffectIsNotRepeatedOnHydration--live.jsonl`: 1 SSE-style frame(s) in order (data parsed); used by LocalServerHydrationStreamingTests.swift::testConsumedInputIsPublishedImmediatelyAndItsEffectIsNotRepeatedOnHydration; expected: session.input.consumed publishes the next user message at once; hydration does not repeat its effect.
- `LocalServerHydrationStreaming--HydratedCommitReplacesLivePreviewWithoutDuplicatingText--after.jsonl`: 1 SSE-style frame(s) in order (data parsed); used by LocalServerHydrationStreamingTests.swift::testHydratedCommitReplacesLivePreviewWithoutDuplicatingText; expected: the hydrated saved message replaces the live preview; a late indexed replay adds no duplicate text.
- `LocalServerHydrationStreaming--HydratedCommitReplacesLivePreviewWithoutDuplicatingText--before.jsonl`: 2 SSE-style frame(s) in order (data parsed); used by LocalServerHydrationStreamingTests.swift::testHydratedCommitReplacesLivePreviewWithoutDuplicatingText; expected: the hydrated saved message replaces the live preview; a late indexed replay adds no duplicate text.
- `LocalServerHydrationStreaming--InitialHydrationPublishesUnindexedDeltasBeforeHistoryAndAppliesThemOnce--live.jsonl`: 2 SSE-style frame(s) in order (data parsed); used by LocalServerHydrationStreamingTests.swift::testInitialHydrationPublishesUnindexedDeltasBeforeHistoryAndAppliesThemOnce; expected: unindexed deltas that arrive during initial hydration publish immediately, then history merges them exactly once.
- `LocalServerHydrationStreaming--RehydrationKeepsGrowingTextAndChunkIndicesWithoutReplayingDeltas--after.jsonl`: 2 SSE-style frame(s) in order (data parsed); used by LocalServerHydrationStreamingTests.swift::testRehydrationKeepsGrowingTextAndChunkIndicesWithoutReplayingDeltas; expected: rehydration keeps growing native text across indexed chunks and ignores replayed indices.
- `LocalServerHydrationStreaming--RehydrationKeepsGrowingTextAndChunkIndicesWithoutReplayingDeltas--before.jsonl`: 1 SSE-style frame(s) in order (data parsed); used by LocalServerHydrationStreamingTests.swift::testRehydrationKeepsGrowingTextAndChunkIndicesWithoutReplayingDeltas; expected: rehydration keeps growing native text across indexed chunks and ignores replayed indices.
- `LocalServerHydrationStreaming--RehydrationKeepsGrowingTextAndChunkIndicesWithoutReplayingDeltas--during.jsonl`: 1 SSE-style frame(s) in order (data parsed); used by LocalServerHydrationStreamingTests.swift::testRehydrationKeepsGrowingTextAndChunkIndicesWithoutReplayingDeltas; expected: rehydration keeps growing native text across indexed chunks and ignores replayed indices.
- `LocalServerHydrationStreaming--ShorterPersistedPrefixCannotReplaceTextThatGrewDuringHydration--after.jsonl`: 1 SSE-style frame(s) in order (data parsed); used by LocalServerHydrationStreamingTests.swift::testShorterPersistedPrefixCannotReplaceTextThatGrewDuringHydration; expected: a shorter persisted assistant prefix cannot replace text that grew during hydration; the message stays streaming.
- `LocalServerHydrationStreaming--ShorterPersistedPrefixCannotReplaceTextThatGrewDuringHydration--before.jsonl`: 1 SSE-style frame(s) in order (data parsed); used by LocalServerHydrationStreamingTests.swift::testShorterPersistedPrefixCannotReplaceTextThatGrewDuringHydration; expected: a shorter persisted assistant prefix cannot replace text that grew during hydration; the message stays streaming.
- `LocalServerHydrationStreaming--ShorterPersistedPrefixCannotReplaceTextThatGrewDuringHydration--during.jsonl`: 1 SSE-style frame(s) in order (data parsed); used by LocalServerHydrationStreamingTests.swift::testShorterPersistedPrefixCannotReplaceTextThatGrewDuringHydration; expected: a shorter persisted assistant prefix cannot replace text that grew during hydration; the message stays streaming.
- `LocalServerHydrationStreaming--StoppedGenerationCannotPublishLateHydrationOrEvents--late-delta.jsonl`: 1 SSE-style frame(s) in order (data parsed); used by LocalServerHydrationStreamingTests.swift::testStoppedGenerationCannotPublishLateHydrationOrEvents; expected: after stopWatching, a late hydration result and late deltas publish nothing (reducer stays nil).
- `SessionConfiguration--ChangedEventDuringMutationUsesFreshAcknowledgementNotStaleResponse--event.jsonl`: 1 SSE-style frame(s) in order (data parsed); used by SessionConfigurationTests.swift::testChangedEventDuringMutationUsesFreshAcknowledgementNotStaleResponse; expected: an external model event during the PATCH makes the outcome deliveryUncertain and keeps the fresh external model.
- `SessionConfiguration--StableConfigurationReadSupersedesBufferedSettingsButKeepsText--buffered.jsonl`: 2 SSE-style frame(s) in order (data parsed); used by SessionConfigurationTests.swift::testStableConfigurationReadSupersedesBufferedSettingsButKeepsText; expected: a stable configuration read supersedes buffered older settings events but keeps buffered text deltas.
- `SessionConfiguration--StreamEventCrossingSnapshotReadRejectsStaleConfiguration--event.jsonl`: 1 SSE-style frame(s) in order (data parsed); used by SessionConfigurationTests.swift::testStreamEventCrossingSnapshotReadRejectsStaleConfiguration; expected: a session.model event crossing a configuration snapshot read rejects it as changedElsewhere and caches nothing.
