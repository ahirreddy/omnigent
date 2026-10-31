# Native session configuration validation

Date: 2026-10-17. Scope: `web/ios/NativeLab`, existing-session harness, model
and reasoning journeys. Production WKWebView target and hosted sessions are
unchanged. See the [journey audit](configuration-journey-audit.md) and
[feature specification](../../specs/features/mobile-session-configuration.md).

## Verified core behavior

```sh
cd web/ios/NativeLab
OMNI_LOCAL_API_TESTS=1 swift test --scratch-path /private/tmp/omni-picker-core
```

**118 passed, 0 failed, 0 skipped.** Includes 36 configuration tests, two
configuration reducer tests, and the existing core/transport/stream tests.
The enabled live checks use the isolated loopback API read-only; no provider
prompt or configuration write is performed by the core suite.

Covered behavior includes absent versus explicit-null values, unknown raw
model IDs, advertised choices/default reasoning, unsupported/read-only/busy
states, clear sentinels, model-before-effort PATCH ordering, acknowledgement
validation, partial/lost-confirmation handling, host-preview revalidation,
harness compatibility/history gates, sparse WS updates, configuration epochs,
slow history/list reads, queued hydration and out-of-order metadata delivery.
Demo configuration migration and backward-compatible decoding are covered.
Sparse WebSocket change/reconnect frames trigger a detailed snapshot for the
open session even without a runner model-event echo. Four regressions cover
that delivery path, reconnect, newer metadata arriving during a slow read, and
preventing a stopped SSE connection from being revived by a list update.

## Native validation

iPhone 17 Pro and SE simulators use iOS 26.0. No physical-device pass is implied.

- **iPhone 17 Pro live picker: 3 passed, 0 failed, 0 skipped**, final source:
  `/private/tmp/omni-picker-form-final-results.xcresult`. Covers read-only identity,
  model catalog and details; model/reasoning apply plus expanded-editor harness
  switch and inline switch back; and external-change review/default restoration.
  Drafts and every previous history item remain unchanged. Final server inspection
  confirmed idle Codex, null model/reasoning overrides, and only the inert marker
  message plus two resource lifecycle events. No prompt or generated reply.
- **SE full demo run: 9 passed, 4 failed, 0 skipped**:
  `/private/tmp/omni-picker-se-final-full-results.xcresult`. Busy-session details
  exposed the bottom inset bug described below. Harness switching reached the
  retained history/details checks but timed out on Done readiness. Expanded
  configuration and Inbox failed after a simulator SpringBoard/accessibility
  crash. This bundle is not reported as a passing full suite.
- **SE corrected-inset rerun: 5 passed, 0 failed, 0 skipped**:
  `/private/tmp/omni-picker-se-inset-results.xcresult`. After restarting only the
  dedicated simulator (app data preserved), busy/read-only/archive inspection,
  largest-text configuration, harness confirmation/history retention, expanded
  model/effort/default selection with Send enabled, and Inbox all passed.
  These results predate the subsequent logo/color presentation change.
- Final unsigned `generic/platform=iOS` build passed with the corrected Form
  inset (`/private/tmp/omni-picker-device-final-form`). All NativeLab Swift files
  passed strict `swift-format` lint; the fixture helper passed Ruff lint/format
  checks. Only the existing orientation/full-screen warning remains. This is
  compilation, not device installation.
- The final app was launched normally on Omni iPhone 17 Pro without test/reset
  arguments, and its Welcome screen was inspected. The local API remains running
  on loopback.

### Corrections verified during the native work

- Demo configuration migration now advances the snapshot revision instead of
  having its new metadata discarded as unchanged.
- Every picker destination exposes Done/Cancel. Expanded configuration uses a
  stable outer sheet owner, and harness switching uses a native alert. Competing
  error-sheet presentation is suppressed while configuration is open; a confirmed
  in-flight switch cannot be cleared by Keep current harness.
- Apply is outside the Form's row content but its safe-area inset is attached to
  the Form itself. Recorded SE interactions showed the old outer NavigationStack
  inset leaving Session details underneath Apply even at maximum scroll.
- At accessibility text sizes, the full unavailable-state explanation scrolls
  with the transcript so it does not consume the entire conversation viewport.
- UI scrolling uses the visible viewport rather than the full accessibility
  frame, which can extend behind fixed controls. Modal-action lookup does not
  scroll the underlying sheet. A reasoning readiness timeout in a superseded
  live run was inspected on video; final live tests passed with explicit
  readiness waiting and full diagnostics on failure.

Inspected passing-run screenshots: [reported details](screenshots/configuration-live-details.png),
[external conflict](screenshots/configuration-live-conflict.png), and
[restored harness with retained draft/history](screenshots/configuration-live-restored.png).

### Logo and send-color follow-up (2026-10-18)

Compact identity controls now show the actual harness glyph plus the model name,
with the full textual identity retained for accessibility and detailed inspection.
Both send buttons use the same confirmed harness palette as the logo. Claude Code
uses `#D97757`, Kiro uses `#9046FF`, and monochrome glyphs adapt between light/dark
system label colors. Arrow colors preserve contrast; disabled states remain muted.

Ten vectors are reused from Omnigent's existing web glyph sources and the pinned
`@lobehub/icons` 5.10.0 dependency. They render as native paths, without a WebView
or runtime network fetch. Unknown harnesses use a generic CPU icon. The MIT notice
is included in the built app resource bundle. Native geometry checks confirmed
all ten paths are finite, nonempty and contained in their 24-point view box within
source rounding tolerance; light and dark contact-sheet renders were inspected.

The updated unsigned iOS build passed at `/private/tmp/omni-branding-device-derived`,
including the bundled notice. Swift formatting and whitespace checks passed.

**SE branding follow-up: 4 passed, 0 failed, 0 skipped**, iOS 26.0:
`/private/tmp/omni-branding-se-results.xcresult`. Covers model search/apply/cancel,
confirmed harness switching, expanded configuration and largest-text controls.
Tests assert model-only visible labels, full accessible identity, logo/Send brand
identity, retained drafts/history, and enabled Send after configuration changes.
No live configuration writes or model prompts were needed for this follow-up.

Passing screenshots were inspected for matching glyph/button colors, readable
model names and keyboard clearance in both composers:
[Codex inline](screenshots/branding-codex-inline.png),
[Codex expanded](screenshots/branding-codex-expanded.png),
[Claude inline](screenshots/branding-claude-inline.png), and
[Claude expanded](screenshots/branding-claude-expanded.png).
The updated build was installed on the idle Omni iPhone 17 Pro simulator and
launched normally without test/reset arguments. Saved app data was preserved;
the Welcome screen was inspected. No physical-device pass is implied.

## Isolated live fixture

The normal **Native live chat** is used only for identity/catalog/details
inspection. Mutation tests use **Native configuration validation**, session
`7b829c941f034a758f9812102638e85c`, under the checkout's
`.native-lab-server/chat-workspace`. Its inert marker explicitly says no model
response was generated. Tests guard title, workspace, marker and starting state.

The tests select advertised models/reasoning, switch Codex to Claude SDK and
back, and simulate an external client's setting change while a local edit is
staged. They verify retained session/workspace/history/message drafts, prevent
stale Apply, and restore defaults on success. Harness teardown can append a
resource-deletion event; the test requires every previous item to remain exactly
unchanged and permits only new resource events, never new messages. No model
prompt is submitted.
A failed mutation is inspected before another run; there is no automatic retry.

Run commands and setup are in the
[NativeLab README](../../web/ios/NativeLab/README.md#isolated-picker-integration-tests).
Do not run mutable live fixture tests concurrently.

## Acceptance coverage

| Criteria | Verification |
| --- | --- |
| AC1–AC2: identity, models, reasoning | Core decoding/choice tests; native inspection/search/selection journeys |
| AC3: apply/cancel and draft retention | Native inline/expanded draft checks; acknowledgement/partial-write tests |
| AC4: retained harness switch | Catalog/history policy tests; guarded local switch round-trip |
| AC5: unavailable states | Core policy tests; demo busy/read-only/archived inspection |
| AC6: external changes | SSE/WS and metadata-order tests; guarded two-client native conflict journey |
| AC7: uncertain failure | Deterministic transport/partial-write tests; explicit review UI source audit |
| AC8: phone layouts | SE/native large-text journeys and screenshot inspection |
| AC9: reproducibility and limits | README commands, this report and independent source audit |

## Limits

- Physical-phone networking/signing, keyboard/dictation, VoiceOver and iOS 18
  fallback still need hands-on validation. The no-login server stays loopback-only.
- Saved harness binding is not provider authentication, execution or replay
  verification. No generated reply after a harness switch is claimed here.
- Host model choices are a labeled ambient preview until the runner advertises
  its own catalog. They are revalidated before any write.
- The existing server has no compare-and-swap token. Client preflight and stream
  ordering prevent observed stale edits but cannot make simultaneous external
  writes atomic. Lost acknowledgements are tested with deterministic transports,
  not by disrupting a real provider operation.
- Connection-generation races were source-audited; they are not presented as
  a separately executed native account-switch test.
