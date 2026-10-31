---
service: omnigent-ios
created: 2026-10-16
---

# Scaffold a native iOS test app

## Intent

Provide a runnable SwiftUI test app for exploring the proposed mobile experience.
Use deterministic offline data so navigation, conversation input, simulated
streaming and decisions can be evaluated without server or provider setup.

## Context

The discovery reports in `designs/ios-native/` recommend native sessions,
conversations, decisions and basic creation. The current app is a WebKit shell.
This workspace is Linux without Xcode; native build and device validation must
be completed on a Mac.

## Requirements

- R1: Ship a separate Xcode project/scheme and bundle identity for the test app.
- R2: Use SwiftUI for setup, sessions/search, Attention, conversation and creation.
- R3: Make sample data explicit and provide useful offline interactions: send,
  stream a deterministic response, interrupt, approve/decline, answer a question,
  create a session and navigate between conversations.
- R4: Separate Foundation-only models/client/state from SwiftUI through an
  injectable client protocol. Treat this as a domain interface, not a completed
  implementation of the server's wire protocol.
- R5: Preserve session identity, reject stale state, prevent duplicate decisions,
  and enforce read-only/pending-decision constraints in the demo client.
- R6: Include meaningful core tests, a native UI happy-path test, and exact Mac
  build/run/test instructions. Report unexecuted native checks honestly.

## Clarifications

- Q1: Does the scaffold need deployed authentication?
  A1: Use offline sample data for this first test app. Deployment-specific login
  remains a later adapter/integration task from discovery.
- Q2: Must development happen on a Mac?
  A2: Source scaffolding can happen here. Compiling SwiftUI and iterating on iOS
  layout, input, accessibility and authentication need Xcode on a Mac.

## Acceptance Criteria

- AC1: GIVEN the project in Xcode WHEN the demo scheme runs on an iOS 18+
  simulator THEN the user can open an explicitly labeled sample workspace.
- AC2: GIVEN seeded sessions WHEN searching or opening Attention THEN native
  lists show matching sessions and pending decisions with working navigation.
- AC3: GIVEN an editable conversation WHEN sending text THEN a user message and
  simulated streaming reply appear in that same conversation; interruption stops
  the reply without changing another session.
- AC4: GIVEN a pending decision WHEN submitting a valid response THEN it resolves
  once and Attention updates; invalid or duplicate responses are rejected.
- AC5: GIVEN a read-only session or one awaiting a decision WHEN sending text
  THEN the client rejects the action and the UI communicates its unavailable state.
- AC6: GIVEN newer conversation state WHEN an older snapshot arrives THEN it
  cannot overwrite the current state or another session.
- AC7: GIVEN a new-session prompt WHEN creation succeeds THEN the app opens that
  session and sends the prompt; a subsequent send error retains the created ID.
- AC8: GIVEN this Linux environment WHEN verification finishes THEN structural
  checks and any runnable core checks are recorded separately from outstanding
  Xcode/UI checks, with reproducible Mac commands.

## Constraints

- Existing shipped iOS target, server, and web application behavior stay intact.
- No external Swift dependencies, real credentials, or network access in demo mode.
- Use system components, semantic typography, accessibility labels and identifiers.
- Test app data is in-memory and resets on relaunch; there is no background
  delivery, persisted outbox, or deployed streaming/reconnect guarantee.

## Out of Scope

- Production authentication, live server transport and wire-event reconciliation.
- Terminal, web renderers, file editing, uploads, scheduling, APNs and release upload.
- Full desktop parity or a completed production migration.

## Plan

### Approach

Create `web/ios/NativeLab/` with a Foundation-only Swift package, an offline actor
client, native SwiftUI application sources, a standalone Xcode project and UI
tests. Run core checks where a Swift toolchain is available, validate project
structure here, and provide a Mac validation script.

### Affected Components

- `web/ios/NativeLab/` — new test app, package, fixtures, tests and documentation.
- `web/ios/README.md` — entry point to the native prototype.

### Data Model Changes

In-memory sessions, messages, decisions and revisioned conversation snapshots.
No database or existing app persistence changes.

### API Changes

None. `SessionClient` describes the scaffold's domain operations; a future live
adapter must translate the independently documented server contracts.

### Risks

- SwiftUI/Xcode compilation cannot be established by Linux structural checks.
- Demo revisions and full snapshots do not establish a server replay contract.
- Native UI test coverage needs Xcode and is independent of browser test coverage.

## Tasks

### Phase 1 — Domain foundation

- [x] T1: Define models/client protocol and implement demo fixtures/client/state.
- [x] T2: Test stale snapshots, permissions, decisions, send and interruption.

### Phase 2 — Native test app

- [x] T3: Implement native setup, sessions/Attention, conversation and creation.
- [x] T4: Add standalone Xcode app/UI-test targets and shared scheme.

### Validation

- [x] T5: Add UI journey coverage and Mac run/test instructions.
- [x] T-val: Run available acceptance checks and record platform limitations.

## Verification

Source scaffolding is complete. After the initial Linux checks below, the
Mac validation pass on 2026-10-16 built the app and passed all four UI journeys
on iPhone Duo with iOS 27.1 using Xcode 27.1. All 12 core tests also passed locally.
The following table records the original Linux handoff; the local results below
supersede its pending simulator checks.

| Criteria | Evidence | Remaining verification |
| --- | --- | --- |
| AC1 | Xcode OpenStep project parses; references, package wiring, source membership and shared scheme checked | Xcode build, install and welcome flow |
| AC2 | Native list/search/Attention implementation reviewed; Attention UI journey added | Simulator search and navigation |
| AC3 | Core tests pass for scoped streaming, monotonic revisions and interruption | Composer, keyboard, Stop and scrolling in simulator |
| AC4 | Core tests pass for valid, invalid, duplicate and incorrectly targeted decisions | Approval/question UI journeys |
| AC5 | Core tests pass for read-only, busy and pending-decision send constraints | Disabled controls and explanation in simulator |
| AC6 | Three state tests pass for stale/equal revisions and foreign-session snapshots | No additional core check pending |
| AC7 | Core creation/publication tested; app's create-then-send error handling reviewed; creation UI journey added | Native creation flow and injected first-send failure |
| AC8 | Linux results and Mac commands recorded in the scaffold README | Run `bin/check.sh` on a Mac |

Checks completed on 2026-10-16:

- All 12 core XCTest cases passed in the official `swift:6.0.3-jammy` Docker
  image with networking disabled and source mounted read-only. The container
  used `swift test --scratch-path /tmp/native-lab-build`.
- All app and UI-test Swift files passed syntax parsing. This does not typecheck
  SwiftUI or XCUITest APIs.
- Swift format lint passed with the repository configuration apart from two
  rules unsupported by the 6.0.3 formatter (`AvoidRetroactiveConformances` and
  `NoEmptyLinesOpeningClosingBraces`), omitted only in a temporary validation
  configuration. The checked-in formatting configuration is unchanged.
- Foundation parsed all 41 project objects and their references resolved;
  all six app/UI source files exist in their intended build phases. The shared
  scheme also passed XML/reference validation.
- Shell syntax, help output and the Mac prerequisite gate passed. Markdown
  formatting and whitespace checks passed.
- Repository-wide web lint found 10 errors and 125 warnings in existing web code.
  Each error's source file matches HEAD; the scaffold changes no JavaScript or
  TypeScript. Error locations: `TerminalSession.test.ts:318`,
  `ScheduleFields.tsx:89`, `useRecentWorkspaces.ts:73`, `lastAssistantText.ts:107`,
  `CommentsPanel.tsx:105,111`, and `agentBundle.test.ts:52,61,68,72`.

### Local Mac validation, 2026-10-16

- Xcode 27.1 (27A9275), Swift 6.4, Apple Silicon, macOS 26.7.1.
- Core tests: 12 passed, zero failures.
- App and XCUITest targets: compiled against the iOS 27.1 simulator SDK.
- UI tests: four passed, zero failures or skips on iPhone Duo with iOS 27.1.
  These cover approval followed by sending and a completed reply, Attention
  question resolution, creation with an initial prompt, and read-only controls.
- Result bundle and recordings:
  `/private/tmp/omnigent-native-ios-accessibility-fix.xcresult`.
- Fixed a conversation-level identifier overriding the composer's child
  identifiers, and made test navigation compatible with side-mounted controls.
- Changed Swift files passed the Xcode 27.1 formatter after adding its required
  `orderedImports.shouldGroupImports` configuration key.

Still pending: physical devices, older supported iOS versions, dedicated Stop,
search and draft-isolation UI checks, an injected first-send failure, manual
keyboard/scrolling review, large Dynamic Type and VoiceOver.
