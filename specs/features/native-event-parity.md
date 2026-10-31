---
service: omnigent-native-lab
created: 2026-10-19
---

# Render main-app events natively

## Intent

Provide meaningful native handling for every event and stored item supported by
the main web app, preserving streaming behavior and readable mobile conversations.

## Context

NativeLab currently renders text, basic tool calls/results and errors. Other
stored items become unsupported-preview strings, and several streamed event
families are ignored. The main app's event parser, block conversion and renderers
are the reference contract.

## Requirements

- R1: Inventory all main-app event and persisted item types with native handling and test evidence.
- R2: Decode supported content into typed native presentation without placeholder-only known events.
- R3: Stream activity updates and reconcile commits/history without duplication or lost content.
- R4: Present compact expandable activity, tools, resource lifecycle, summaries and failures on phones.
- R5: Handle lifecycle/configuration/usage events as session state where appropriate, not fake messages.
- R6: Preserve interactive requests, drafts, messaging, existing navigation and harness branding.
- R7: Preserve useful unknown-event details with safe display; never execute payloads or fetch arbitrary URLs automatically.
- R8: Validate the inventory through deterministic tests and native small-phone journeys; document genuine limits.

## Clarifications

- Q1: Does support require a transcript row for every protocol frame?
  A1: No; transport and state frames update their corresponding native state.
- Q2: Does this authorize production-server or hosted-session changes?
  A2: No; implementation stays in NativeLab and local deterministic fixtures.

## Acceptance Criteria

- AC1: GIVEN the main-app event contract WHEN audited THEN each event/item has an explicit native mapping and validation status.
- AC2: GIVEN any known persisted item WHEN loaded THEN meaningful native content appears instead of an unsupported-preview placeholder.
- AC3: GIVEN streamed activity WHEN deltas, completion, reconnect or replay arrive THEN content updates without duplicate rows or stale streaming state.
- AC4: GIVEN session state events WHEN received THEN native status, configuration or details reflect them without irrelevant transcript rows.
- AC5: GIVEN a pending user request WHEN supported by the server contract THEN native controls submit the matching response without inventing approvals.
- AC6: GIVEN large or unknown payloads WHEN displayed THEN useful bounded details remain inspectable without automatic execution or network access.
- AC7: GIVEN a small phone or large text WHEN viewing activity THEN disclosure, scrolling and composer controls remain usable.
- AC8: GIVEN final implementation WHEN reviewed THEN core/UI results and remaining limits are recorded alongside reproducible test steps.

## Constraints

Preserve the dirty worktree and all existing conversations/drafts. Keep the local
no-login API loopback-only. Do not submit real prompts or alter hosted sessions.
Do not reveal hidden/encrypted reasoning; use only provider-exposed summaries.

## Out of Scope

Production web changes, new server endpoints, hosted authentication, background
push delivery, and automatic execution/download of event payloads.

## Plan

### Approach

Audit the web event/parser/item/rendering contracts. Share typed activity models
between stored history and streaming reducers, then render reusable native cards
and state/details views. Use exhaustive fixtures plus representative UI journeys.

### Affected Components

- NativeLabCore item decoding, conversation models and live reducer.
- NativeLab conversation/activity views and request controls.
- Core/UI fixtures and event coverage/validation documentation.

### Data Model Changes

Backward-compatible optional typed activity and session-event state.

### API Changes

Consume existing contracts only.

### Risks

Duplicate stream/history representations, large tool output, sparse metadata,
unknown future events, unsupported interactive schemas and misleading lifecycle labels.

## Tasks

### Phase 1 — Inventory and core

- [x] T1: Inventory every main-app event and item type.
- [x] T2: Decode all persisted item families with typed native content and tests.
- [x] T3: Implement streamed event/state parity and reconciliation tests.

### Phase 2 — Native presentation

- [x] T4: Add native activity/details and interactive request support.
- [x] T5: Add representative demo/UI journeys without changing normal saved data.

### Validation

- [x] T-val: Verify AC1–AC8 and record per-event coverage, native tests and limitations.

Evidence: [event coverage and validation ledger](../../designs/ios-native/event-coverage.md).
197 core tests passed with local read-only checks enabled; all eight gallery
journeys and one real-server history journey passed across iOS 26.0 simulators.
Unsigned iOS build, strict Swift formatting and project syntax checks passed.
Physical phones, VoiceOver and iOS 18 remain unverified. One unlocalized runtime
layout warning remains in the passing SE typed-form journey; see the ledger.
