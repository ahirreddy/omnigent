---
service: omnigent-ios
created: 2026-10-16
---

# Connect the native app to a local server

## Intent

Make NativeLab useful against a real local Omnigent API: connect explicitly,
browse sessions and read paginated history. Fix the known phone composer
defects in parallel while retaining the offline demo for writing workflows.

## Context

NativeLab currently uses DemoSessionClient. An isolated API-only server runs at
http://127.0.0.1:6767 using this checkout and .native-lab-server state. REST
contracts were audited in designs/ios-native/server-contracts.md. No project
spec exists. User explicitly requested a parallel implementation team.

## Requirements

- R1: Provide an explicit local-server connection and a distinct demo mode.
- R2: Discover the server and verify local single-user identity before reading data; report invalid URL, auth, transport and decoding failures honestly.
- R3: Load session pages and history pages lazily with stable IDs, deterministic order and duplicate prevention.
- R4: Live mode is read-only throughout the UI and transport; never send, create, edit, stop or resolve live decisions.
- R5: Keep demo persistence separate from live state; cancel or ignore stale work when switching connections.
- R6: Provide refresh and foreground recovery without implying SSE or background delivery.
- R7: Fix expanded-editor background bleed and preserve usable editing space on small phones at large Dynamic Type with keyboard and rotation.
- R8: Verify the new journey in an iPhone simulator against the isolated real API and retain automated regression coverage.

## Clarifications

- Q1: Which server and auth mode are in this implementation?
  A1: Local loopback single-user development server only. Do not borrow hosted credentials or expose it to the LAN.
- Q2: Are live sends included?
  A2: No. The agreed first live milestone is sessions and conversation reading; demo send/stop/decisions remain available.
- Q3: Can tests create isolated data?
  A3: Yes, deterministic fixture sessions/history only in the dedicated local test database, without launching models or changing hosted sessions.

## Acceptance Criteria

- AC1: GIVEN the local server WHEN connecting from NativeLab THEN discovery and identity succeed and the app visibly enters live read-only mode.
- AC2: GIVEN multiple pages WHEN loading more sessions or older messages THEN entries are not duplicated or silently inaccessible and transcript ordering stays chronological.
- AC3: GIVEN live mode WHEN attempting any mutation THEN no mutating HTTP request is issued and UI controls are unavailable.
- AC4: GIVEN connection failure or unsupported auth WHEN connecting or refreshing THEN an actionable error appears without substituting demo data as live data.
- AC5: GIVEN a saved demo draft WHEN entering live mode and returning THEN the draft is unchanged and stale live responses do not enter the demo store.
- AC6: GIVEN a changed server conversation WHEN explicitly refreshing or foregrounding THEN the current snapshot/history are refreshed without claiming streaming.
- AC7: GIVEN SE and standard iPhone layouts WHEN opening the editor at large text sizes with keyboard and rotation THEN the editor has an opaque readable background and controls remain reachable.
- AC8: GIVEN this checkout WHEN following documented commands THEN core tests, native build and live simulator validation can be reproduced.

## Constraints

Preserve the dirty worktree, original Downloads prototype and production web
shell. Use supported REST contracts. Permit insecure HTTP only for literal
loopback development addresses. Do not transfer credentials, write to hosted
sessions, or launch model calls. Do not silently follow redirects to other
servers. Keep live state in memory for this slice; the demo store is unchanged.

## Out of Scope

Hosted login/Keychain credentials, arbitrary LAN connections, physical-device
networking, SSE/reconnect reconciliation, live mutations, push, TestFlight,
attachments, and terminal UI.

## Plan

### Approach

Parallel owners: Foundation REST adapter/tests; connection UI/AppModel;
editor layout. Primary agent owns integration, UI tests, local fixture setup,
Xcode configuration and verification. Shared paging contracts are agreed before
implementation. All live mutations reject locally.

### Affected Components

- NativeLabCore: local API adapter and wire models/tests.
- AppModel, NativeLabApp, WorkspaceView: mode switching, connection and pages.
- MobileComponents, ConversationView: readable editor and live reading controls.
- UITests, bin, README: real-server fixtures and reproduction.

### Data Model Changes

Connection discovery and explicit cursor-bearing page values. No migration of
the demo store and no persistent live transcript cache.

### API Changes

No server changes. Implement REST GET discovery, identity, sessions, snapshot
and items. Reuse SessionClient where possible with explicit paged extensions.

### Risks

Wire shapes differ between snapshots and items; pagination can race refresh;
mode switches must guard late results. Simulator HTTP policy needs actual
validation. UI geometry assertions alone do not establish visual correctness.

## Tasks

### Phase 1 — Parallel implementation

- [x] T1: Implement read-only API adapter, paging and failure tests.
- [x] T2: Implement connection/mode UI, lazy session loading and isolation.
- [x] T3: Repair phone composer background and large-text layout.

### Phase 2 — Integration

- [x] T4: Integrate conversation history paging and refresh UI.
- [x] T5: Add safe local fixture setup and live UI journeys.
- [x] T6: Update run instructions and scope boundaries.

### Validation

- [x] T-val: Run acceptance criteria verification and record actual results and remaining gaps.

Results and screenshots: [local-server-validation.md](../../designs/ios-native/local-server-validation.md).
AC6 changed-server/foreground behavior and delayed mode-switch races remain
unverified; implementation completion is not a claim that those checks passed.
