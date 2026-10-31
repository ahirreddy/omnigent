---
service: omnigent-native-lab
created: 2026-10-19
---

# Prioritize conversation content over lifecycle bookkeeping

## Intent

Keep conversations focused on messages, meaningful results and decisions.
Routine lifecycle receipts remain inspectable in Session activity.

## Context

The event-parity pass rendered resource creation/deletion as full transcript
cards. The user approved moving routine lifecycle events into Session activity,
using small stopped markers and compact expandable failures.

## Requirements

- R1: Move routine resource and cancelled client-task receipts out of the transcript without discarding their data.
- R2: Keep failures, useful output, attachments and interactive requests visible.
- R3: Present interruptions as small Stopped markers and failures as compact expandable warnings.
- R4: Preserve streaming, history pagination, draft state and existing event decoding.

## Clarifications

- Q1: Should successful response completion produce a new chat card?
  A1: No. It already updates state without a separate transcript item.
- Q2: Should actual terminal command/output be hidden?
  A2: No. Only routine resource lifecycle bookkeeping moves to Session activity.

## Acceptance Criteria

- AC1: GIVEN routine lifecycle receipts WHEN viewing the conversation THEN they appear only in Session activity with their original details.
- AC2: GIVEN failures, terminal output, attachments or questions WHEN rendering THEN they remain available in the conversation.
- AC3: GIVEN a stopped reply or failure WHEN rendering THEN the reply has a small stopped marker or compact expandable warning respectively.
- AC4: GIVEN stored history and streamed commits WHEN projected into the UI THEN event content and ordering are preserved without server writes.
- AC5: GIVEN the final UI WHEN validated THEN core tests and representative simulator journeys pass and known limits are documented.

## Constraints

Preserve the dirty worktree, normal app data and existing decoding. No provider
prompts, hosted mutations, automatic retries or changes to server-side execution.

## Out of Scope

Changing server event types, redesigning tool results, physical-phone validation,
and unrelated form-layout warnings.

## Plan

### Approach

Use one shared presentation policy for history and live messages. Filter only
the transcript projection, retain receipts in the snapshot and expose a collapsed
lifecycle-history section in Session activity. Compact failures without removing
their details; preserve existing recovery guidance without automatically retrying.

### Affected Components

NativeLabCore conversation presentation and lifecycle reducer; conversation and
Session activity views; deterministic and read-only UI fixtures.

### Data Model Changes

Computed presentation properties; existing optional interruption marker.

### API Changes

None.

### Risks

Accidentally hiding failed resources or attachments, empty-looking conversations,
duplicate failure presentation and history pagination anchors on hidden receipts.

## Tasks

- [x] T1: Add shared lifecycle prominence policy and regression tests.
- [x] T2: Update transcript, activity history and compact warnings/stopped markers.
- [x] T3: Add deterministic UI fixtures and update live read-only verification.
- [x] T-val: Run core, build and simulator checks; record evidence and limits.

Validation on 2026-10-19:

- Core suite: 202 tests executed, two opt-in server tests skipped, zero failures;
  all five new EventHierarchyTests passed, including an additional focused rerun.
- iPhone SE3 / iOS 26.0: 2/2 UI tests passed (quiet lifecycle/recovery flow and
  retained tool/terminal details), zero skips or runtime warnings.
- iPhone 17 Pro / iOS 26.0: 2/2 UI tests passed (largest-text Session activity and
  real-server resource history), zero skips or runtime warnings. Server history
  remained unchanged.
- Result bundles: `/private/tmp/omni-hierarchy-se-results.xcresult` and
  `/private/tmp/omni-hierarchy-live-results.xcresult`.
- Unsigned iOS device build, strict Swift lint, project syntax and diff checks
  passed. Device build retains the existing orientation/full-screen warning.
- Visually reviewed [quiet SE transcript](../../designs/ios-native/screenshots/hierarchy-se-quiet-conversation.png)
  and [retained lifecycle details](../../designs/ios-native/screenshots/hierarchy-se-lifecycle-details.png).
- Physical phones, VoiceOver and the unrelated typed-form runtime warning were
  not validated or addressed in this presentation-only follow-up.
