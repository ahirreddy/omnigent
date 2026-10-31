---
service: omnigent-native-lab
created: 2026-10-17
---

# Show and configure mobile session identity

## Intent

Make the active harness, model and reasoning settings visible while composing.
Provide native, session-scoped controls that preserve drafts and conversation
history, with honest capability, permission and connection states.

## Context

NativeLab already supports local REST/SSE/WebSocket conversations and an
expanded native editor. Its session decoder drops configuration fields that
the server exposes. The web app implements harness-aware model mutations and
idle-only agent switching; a generic metadata PATCH is not sufficient for
every live harness. No production WKWebView changes are intended.

## Requirements

- R1: Show server-derived harness/model identity in both composers and session rows.
- R2: Open a native configuration sheet with model search, supported reasoning choices and session details.
- R3: Keep draft configuration separate from confirmed settings; apply explicitly and preserve message drafts.
- R4: Offer only supported model mutations and history-preserving, host-configured harness targets.
- R5: Confirm harness changes, explain runtime restart and cross-family setting resets, and retain the session.
- R6: Explain busy, read-only, archived, offline, unknown and unavailable states without inventing defaults.
- R7: Reconcile configuration events and reconnect snapshots; detect another client's changes while editing.
- R8: Keep controls accessible on SE-sized phones, large text and the expanded editor; retain all navigation.
- R9: Audit and test every related journey, including failed and uncertain mutations, and record limitations.

## Clarifications

- Q1: Does this include new-session creation, remote authentication or physical-device networking?
  A1: No; this implements the approved configuration journeys for existing sessions.
- Q2: May changing settings stop an active response or automatically retry an ambiguous write?
  A2: No. Inspection remains available, applying is disabled while busy, and uncertain writes require reconciliation.

## Acceptance Criteria

- AC1: GIVEN a session snapshot WHEN it is listed/opened THEN both composers and the list show its own harness/model, retaining unknown raw identifiers.
- AC2: GIVEN advertised models WHEN selecting/searching THEN the current model remains visible and reasoning choices match the selected model.
- AC3: GIVEN edited configuration WHEN cancelling or applying THEN message drafts survive and only acknowledged settings become current.
- AC4: GIVEN a configured compatible target WHEN confirming a harness switch THEN the same session is retained and reset behavior is explained.
- AC5: GIVEN busy/read-only/archived/disconnected state WHEN opening the picker THEN details remain readable and unsafe actions explain why they are disabled.
- AC6: GIVEN an external configuration event WHEN the picker is open THEN confirmed identity updates and stale edits cannot silently overwrite the change.
- AC7: GIVEN a failed/uncertain mutation WHEN it finishes THEN the sheet reports the result, reconciles server state and does not retry automatically.
- AC8: GIVEN a small phone or large text WHEN using either composer/picker THEN primary controls remain reachable and drafts/navigation are preserved.
- AC9: GIVEN the completed implementation WHEN reviewing validation THEN commands and pass/skip/unverified boundaries exist for every journey.

## Constraints

Keep the local no-login server bound to loopback. Do not modify hosted sessions,
global provider configuration or credentials. No automatic model prompts in
deterministic tests. Preserve existing user changes. No hard-coded model catalog
or silent model alias guessing. Provider/host details only come from reported data.

## Out of Scope

New-session provisioning, authentication/LAN exposure, provider installation,
global defaults, attachments, push, and unsupported history-losing harness switches.

## Plan

### Approach

Decode configuration into a separate typed value on each session. Keep a
per-sheet edit baseline and reconcile streamed metadata; never infer a model
from another conversation. Load the agent and host catalog on demand. Use
native sheet navigation for model search, effort, eligible harnesses and
details, with confirmation before a harness transition.

### Affected Components

- NativeLabCore models/client/reducer: configuration, catalogs, mutation routing and events.
- AppModel: generation-scoped operations, mutation/send exclusion, reconciliation.
- Both composers and session rows: visible identity and shared configuration sheet.
- Core/UI tests and validation documentation: audited journeys and failure boundaries.

### Data Model Changes

Optional Codable configuration on summaries for backward-compatible demo storage;
typed model options, host/agent choices, edit baseline and mutation errors.

### API Changes

Consume existing snapshot/catalog/model/effort/switch-agent contracts. No
production-server API expansion is planned.

### Risks

Provider-facing IDs can differ from advertised aliases. Native mutation may
partially succeed before metadata confirmation. Host configuration does not
prove provider authentication. Live configuration/catalog changes can race edits.

## Tasks

### Phase 1 — State and transport

- [x] T1: Decode identity/capabilities and reconcile configuration events.
- [x] T2: Implement validated mutation/catalog paths and pure editing policy.

### Phase 2 — Native interaction

- [x] T3: Add both composer controls, session subtitles and configuration sheet.
- [x] T4: Add confirmations, details, conflict/failure states and demo support.

### Validation

- [x] T-val: Verify AC1–AC9 with core/native tests, local API checks and small-phone screenshots; record actual results in the [validation report](../../designs/ios-native/configuration-validation.md), including source-only and physical-device limits.
