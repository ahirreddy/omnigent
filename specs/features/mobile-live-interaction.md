---
service: omnigent-ios
created: 2026-10-17
---

# Restore live session interaction and streaming

## Intent

Let people write to real sessions, see replies as they stream, and respond to
requests from a persistent Inbox. Preserve native editing and existing demo
features rather than substituting a read-only experience for live connections.

## Context

The previous local-server milestone implemented read-only REST browsing and
hid interaction controls in live mode. The user explicitly rejected that scope.
This feature supersedes its read-only and refresh-first constraints. The local
server already has message/interrupt/elicitation REST endpoints, conversation
SSE, and session-list WebSocket updates. No project spec exists.

## Requirements

- R1: Live conversations expose the native composer and send/interrupt actions when the server grants edit permission.
- R2: Conversation updates arrive through SSE, including partial assistant text, final messages, status and pending decisions, without user refresh.
- R3: Reconnect and foreground recovery reconcile history and pending state without duplicate messages or stale streaming indicators.
- R4: Keep Sessions, Inbox and Settings as adjacent navigation tabs in demo and live modes; Inbox shows pending requests beyond the first list page.
- R5: Session list and Inbox update automatically from server notifications; failure and reconnect state are visible without presenting manual refresh as normal operation.
- R6: Preserve exact unsent drafts on failed or ambiguous submission; never automatically retry a possibly accepted POST or report an accepted message as a completed response.
- R7: Respect permissions and originating session IDs for decisions; do not automatically approve actions.
- R8: Retain demo flows and native editor layout; keep live and demo data separate and prevent switched-away responses from entering the current mode.
- R9: Verify real transport behavior and native UI on regular iPhone simulators, with accurate reporting of any untested provider-backed execution.

## Clarifications

- Q1: What does “inbox should be a menu next to sessions and settings” mean here?
  A1: A persistent peer tab labeled Inbox in the existing navigation bar.
- Q2: Does this change permit writes to local sessions?
  A2: Yes; sending, interrupting and explicitly resolving requests are required. Testing uses dedicated local sessions, not the hosted conversation.
- Q3: Is refresh allowed internally?
  A3: Snapshot/history reconciliation on initial connection, notification, reconnect or foreground is necessary, but normal updates must use SSE/WS, not periodic polling or a required Refresh button.

## Acceptance Criteria

- AC1: GIVEN an editable live session WHEN a user sends a draft THEN one message is submitted and subsequent streamed response updates appear without refresh.
- AC2: GIVEN repeated or overlapping history/live events WHEN they arrive or a connection recovers THEN committed messages appear once in chronological order and completed replies stop streaming.
- AC3: GIVEN a transport interruption WHEN connectivity returns THEN subscriptions reconnect and reconcile current state automatically.
- AC4: GIVEN pending requests beyond the first list page WHEN opening Inbox THEN they are discoverable and their resolution updates the Inbox automatically.
- AC5: GIVEN demo or live mode WHEN viewing workspace navigation THEN Sessions, Inbox and Settings are all available.
- AC6: GIVEN read-only permission or a rejected/ambiguous send WHEN submitting THEN unauthorized writes are prevented or surfaced honestly and the draft is retained without automatic resubmission.
- AC7: GIVEN a pending request WHEN the user chooses an answer THEN the correct originating session receives that explicit response and the UI follows the server's state.
- AC8: GIVEN existing demo drafts and editor layouts WHEN switching modes and editing on standard/SE phones THEN draft isolation and native editing remain functional.
- AC9: GIVEN the checkout and documented setup WHEN running tests THEN stream, mutation, Inbox and UI coverage is reproducible and live-model execution is distinguished from fixture transport testing.

## Constraints

Preserve unrelated local work, the production WKWebView target and original
prototype. Keep this connection loopback-only until authenticated device
networking is implemented. Do not borrow hosted credentials or expose the
no-login server to the LAN. No destructive session stop: interrupt means stop
the current turn. Explicit local test prompts must not modify unrelated files.

## Out of Scope

Hosted-account integration, physical-phone networking, push notifications,
background delivery guarantees, attachments, terminal rendering and TestFlight.
Session creation requires configured host/agent context and must not invent it.

## Plan

### Approach

Three parallel owners: transport/reducer and core tests; AppModel/live composer
integration; Inbox/navigation UI. Coordinator owns integration, local server and
fixture validation, UI tests, project wiring, documentation and final checks.
Stream before/concurrently with hydration, reconcile on reconnect, and keep
POST acknowledgements separate from generated output.

### Affected Components

- NativeLabCore: mutations, permissions/decisions, SSE parser/reducer and WS notifications.
- AppModel, ConversationView, MobileComponents: subscriptions, live drafts and interaction.
- WorkspaceView, NativeLabApp: persistent Inbox and foreground lifecycle.
- Tests, UITests, bin and README: transport fixtures and reproducible verification.

### Data Model Changes

Explicit stream state, send acknowledgements/uncertainty and pending decisions.
Live state remains isolated from demo persistence.

### API Changes

Consume existing Omnigent REST/SSE/WebSocket endpoints. Avoid production-server
changes unless an actual missing contract is identified.

### Risks

No durable SSE replay cursor or POST idempotency key. History can overlap live
text; permission/status changes race requests. Local fixtures have no running
model until a real runner is configured, which must not be mistaken for a
successful generated reply.

## Tasks

### Phase 1 — Parallel implementation

- [x] T1: Implement live transport, mutations, reducer and core regression tests.
- [x] T2: Restore permission-aware live messaging and subscription lifecycle.
- [x] T3: Add persistent Inbox and automatic session-list UI behavior.

### Phase 2 — Integration

- [x] T4: Add deterministic streaming/send/Inbox integration coverage and test setup.
- [x] T5: Update documentation and application copy for the actual live experience.

### Validation

- [x] T-val: Run core/native tests and record actual results, limitations and run instructions. See `designs/ios-native/live-interaction-validation.md`: 80 core tests pass; native send/stream/foreground recovery pass on SE and 17 Pro. Genuine provider replies remain unverified because the configured login requires renewal; the opt-in model UI test is skipped.
