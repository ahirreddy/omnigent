---
service: omnigent-ios
created: 2026-10-16
---

# Build the native mobile core

## Intent

Make mobile Omni a focused, native place to find work, continue conversations, and answer decisions. Use Codex-like navigation and a responsive native text modal with Liquid Glass, while retaining Omnigent's identity and explicit preview boundaries.

## Context

The local clone of Arca main is at `76281b9438578e472810879e18fc60acc64d3d6c`. The shipping `web/ios/Omnigent` target embeds the web UI. The imported `NativeLab` target is a tested SwiftUI demo with session navigation, decisions, simulated replies and a basic inline composer. The original Downloads copy remains untouched. No project spec exists.

## Requirements

- R1: Provide searchable, recent-first native sessions with pinned/recent sections, status, project context, filters, rename, pin, archive and restore.
- R2: Provide a growing inline composer and an expandable native text sheet sharing one per-session draft. Dismissal, switching and relaunch must preserve unsent text.
- R3: Use system Liquid Glass on iOS 26+, a material fallback on iOS 18, semantic colors, Dynamic Type, keyboard-safe layout and accessible controls.
- R4: Preserve send/stop, read-only restrictions, approvals, questions, Attention routing and create-then-send semantics. Archiving a conversation does not hide an outstanding decision from Attention.
- R5: Persist offline conversations, organization and drafts, safely recovering interrupted demo replies after relaunch. Never imply that sample data is connected to Arca.
- R6: Document the source-grounded mobile feature comparison and deferred live integration; retain the shipping web-shell target unchanged.

## Clarifications

- Q1: Is this a native Mac app or the mobile app developed on this Mac?
  A1: Continue the existing native iOS prototype on this Mac; support iPhone and iPad layouts.
- Q2: Does this slice connect to production?
  A2: No. Keep the offline preview explicit. Native auth, deployment-aware API routing, real streaming/reconnect and server-backed mutations require a separate live integration slice. Do not borrow browser credentials or guess API URLs.
- Q3: What does copying Codex mean?
  A3: Follow the requested interaction patterns: quiet session rows, prominent compose action, native long-form editing and system glass. Do not claim pixel parity with an uninspected proprietary UI.

## Acceptance Criteria

- AC1: GIVEN sessions WHEN searching and filtering THEN matches include title, preview and workspace, pinned sessions are grouped, and recents are ordered by activity.
- AC2: GIVEN an editable session WHEN renaming, pinning, archiving and restoring THEN the changes survive relaunch; read-only sessions reject edits.
- AC3: GIVEN a draft WHEN expanding, editing, dismissing, switching sessions or relaunching THEN the exact text remains attached to its session and is sent only by an explicit Send action.
- AC4: GIVEN a narrow or large-text layout WHEN editing in the sheet THEN text scrolls, controls remain reachable, and native selection, paste and keyboard dismissal work.
- AC5: GIVEN pending decisions or read-only access WHEN opening either composer THEN sending stays unavailable; answering a decision updates Attention and Stop interrupts only the current reply.
- AC6: GIVEN saved sample state WHEN restarting during a reply THEN partial content remains, streaming ends visibly and new IDs do not collide.
- AC7: GIVEN iOS 26+ WHEN rendering the composer THEN native glass is used; earlier supported versions and Reduce Transparency have a usable fallback.
- AC8: GIVEN the finished change WHEN following README instructions THEN core tests and native UI journeys run, and preview versus live behavior is clear.

## Constraints

Preserve existing work and the production shell. No dependencies or secrets required. No implicit send on modal dismissal, no destructive delete action, no background-delivery claims. Local persistence is versioned and atomically written; write failures must be visible.

## Out of Scope

Live server/auth integration, SSE replay/reconnect, push, terminal, code editor, admin, schedules, attachments, arbitrary HTML artifacts, desktop parity and App Store distribution.

## Plan

### Approach

Extend the Foundation core with session organization, a pure query model and a versioned local workspace store. Keep simulator tests isolated from normal preview data. Compose SwiftUI session rows and shared draft bindings with an expandable TextEditor sheet. Apply native glass to interactive chrome, not the transcript. Preserve the existing simulator journeys and add organization, draft/relaunch and layout tests.

### Affected Components

- `web/ios/NativeLab/Sources/NativeLabCore`: models, query, persistence and demo client.
- `web/ios/NativeLab/App`: session browser, composer, app lifecycle and settings.
- `web/ios/NativeLab/Tests`, `UITests`: behavioral and native UI checks.
- `designs/ios-native/mobile-core-comparison.md`: mobile feature decisions and source references.

### Data Model Changes

Codable snapshots, updated time, project/agent context, pin/archive flags, draft and local read state. Persist one versioned demo workspace; server identities are not invented.

### API Changes

Demo-only session edit operation; no server API changes.

### Risks

Keyboard/sheet geometry and Dynamic Type need simulator inspection. Liquid Glass availability is guarded. Persisted in-flight demo replies cannot resume execution and must be marked interrupted. A live adapter must replace demo-only persistence and implement real wire semantics.

## Tasks

### Phase 1 — Foundations

- [x] T1: Clone current Omnigent locally and import the tested prototype without changing the original.
- [x] T2: Add session query/organization and durable local state with recovery tests.

### Phase 2 — Native experience

- [x] T3: Build the session browser, organization actions and clear preview settings.
- [x] T4: Build shared inline/expanded native composition and system glass treatment.

### Validation

- [x] T5: Record the source comparison, run instructions and remaining live-integration boundary.
- [x] T-val: Run acceptance criteria verification, including core tests, UI journeys and simulator visual inspection. Passed 22 core tests, eight UI journeys and the post-fix large-text check; remaining manual/device coverage is explicitly recorded in `designs/ios-native/mobile-core-validation.md`.
