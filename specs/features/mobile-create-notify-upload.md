---
service: omnigent-native-lab
created: 2026-10-19
---

# Create sessions, receive notifications and attach files

## Intent

Complete the native creation, background attention and attachment journeys requested together by the user.

## Context

Existing-session messaging and streaming work. New live sessions, background push delivery and file/photo upload controls are missing. Three parallel implementation agents own the feature modules; the primary agent integrates shared app state and navigation.

## Requirements

- R1: Select an existing ready host, workspace, agent and supported harness/model when creating a live session.
- R2: Distinguish confirmed creation from uncertain delivery and preserve the initial prompt if sending cannot finish.
- R3: Support explicit notification permission, server delivery for attention/completion and navigation to the correct session.
- R4: State unavailable push configuration honestly; background delivery must not depend on a suspended app maintaining SSE.
- R5: Select photos/files, upload with visible state and cancellation, and send exact server references with optional text.
- R6: Preserve session/account draft isolation and prevent silent replay of uncertain writes.
- R7: Verify deterministic contracts and native integration while preserving existing workflows.

## Clarifications

- Q1: Does this include provisioning new hosts or hosted authentication?
  A1: No. Use existing hosts and the existing connection boundary.
- Q2: May background delivery require signing and server credentials?
  A2: Yes. Implement the configuration path and document any external activation requirements; do not claim a push was delivered without evidence.

## Acceptance Criteria

- AC1: GIVEN valid creation choices WHEN Start is tapped THEN one real creation request is made and the resulting session opens.
- AC2: GIVEN failed or uncertain creation/sending WHEN the UI returns THEN drafts and actionable status are retained without automatic retries.
- AC3: GIVEN a configured push service WHEN a subscribed session needs attention or finishes THEN a deduplicated scoped notification is dispatched independently of the foreground app.
- AC4: GIVEN a notification tap WHEN connected to the matching server and identity THEN the intended conversation opens; mismatched scopes cannot route silently.
- AC5: GIVEN files or photos WHEN selected THEN upload progress/errors are visible and successful references can be sent with or without text.
- AC6: GIVEN failure, cancellation or a connection switch WHEN uploads or sends complete THEN another conversation's draft cannot be changed.
- AC7: GIVEN final code WHEN verified THEN focused core/server tests, iOS builds and representative simulator journeys are recorded with activation limits.

## Constraints

Preserve dirty work and normal app data. Do not submit real provider prompts, send actual pushes, expose the no-login server or deploy services during validation. No commits or pushes.

## Out of Scope

Phone networking/authentication, persistent live draft storage, host provisioning, and production distribution.

## Plan

### Approach

Parallel feature modules with shared app state, project registration, composer and navigation integration owned by the primary agent. Use existing server contracts for creation/uploads and configuration-gated push infrastructure where absent.

### Affected Components

NativeLabCore, native creation/composer/settings views, app lifecycle/navigation, notification server routes/delivery and tests.

### Data Model Changes

Typed creation selection, scoped attachment drafts and notification registration/routing state.

### API Changes

Consume existing creation/upload endpoints; add scoped notification registration and delivery support if required by the server audit.

### Risks

Uncertain POST acknowledgements, repeated attachment sends, stale host catalogs, iOS suspension, missing push credentials, and cross-session completion races.

## Tasks

- [x] T1: Implement live creation contracts, selection UI and tests.
- [x] T2: Implement background notification delivery, permission/routing and tests.
- [x] T3: Implement attachment upload contracts, selection UI and tests.
- [x] T4: Integrate shared state, navigation, composers and build configuration.
- [x] T-val: Run validation and document concrete activation requirements.

## Validation outcome

Implementation and deterministic checks are complete. See [validation](../../designs/ios-native/create-notify-upload-validation.md). APNs delivery still requires signing/provider activation, and physical-phone networking remains outside this change.
