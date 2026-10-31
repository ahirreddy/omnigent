# Mobile harness and model journey audit

Audit date: 2026-10-17. Scope: the existing-session configuration journeys in
`specs/features/mobile-session-configuration.md`. This is an independent source
and contract audit, not a claim that every journey has passed on a device.
No hosted session, credential, provider prompt, or network exposure was changed
by this audit.

Final source re-review: the implementation now includes the fixes described
below, with deterministic regression tests in `SessionConfigurationTests`.
The validation boundaries in the matrix describe this independent audit only;
they do not assert that the implementation team's later test runs were skipped
or failed. Use its validation report for executed counts and screenshots.

## Journey map

| Journey | Required outcome | Implementation inspected | Validation boundary |
| --- | --- | --- | --- |
| Identify before opening | Session row shows that session's harness/model | `WorkspaceView` / `SessionSummary.configuration` | Source inspected; native tests required |
| Identify while writing | Inline and expanded editors expose the same picker | `MobileComponents` / `ConfigurationButton` | Source inspected; keyboard and SE layout require native tests/screenshots |
| Inspect details | Exact IDs, agent, host and workspace remain readable without write permission | `SessionConfigurationView.details` | Source inspected; server does not separately report provider identity |
| Search/select model | Runner choices, current identifier and a single selection; no guessed catalog | `ModelChoicesView` / `ConfigurationEdit` | Source inspected; default-selection regression identified below |
| Select reasoning | Choices match selected model; no override differs from an asserted effort | `SessionConfiguration.efforts` / effort page | Source inspected; missing-versus-null and unsupported-level tests required |
| Cancel editing | Confirmed settings and message draft are unchanged | Per-sheet `ConfigurationEdit`; draft in `AppModel` | Source inspected; native cancel/draft test added by implementation team |
| Apply model/effort | Serialize acknowledged writes; preserve draft; do not silently resend | `LocalServerConfiguration` / `AppModel.applyConfiguration` | Partial/uncertain completion and acknowledgement tests required |
| Switch harness | Explicit confirmation; same session/history/workspace; explain resets | Catalog filter, `switchHarness`, confirmation dialog | Backend history allowlist compared; real provider execution not tested by this audit |
| Decline switch | Keep current harness and draft | Cancel confirmation / Keep current harness | Source inspected; native journey test required |
| Inspect busy session | Details remain reachable; no interrupt or queued switch | `configurationUnavailableReason` plus client preflight | Source inspected; busy/read-only/archived native test added by team |
| Inspect read-only/archived | Explain reason, disable mutations, retain details | Same UI and client gates | Source inspected; no permission bypass inferred from disabled buttons |
| Offline/host unavailable | Read cached identity, explain action block | Stream readiness and host/runner checks | Source inspected; failed/offline transport tests required |
| External setting change | Update confirmed identity; dirty edits must be reviewed | SSE reducer / sheet baseline conflict | Snapshot/SSE ordering and malformed-event regressions identified below |
| Catalog changes while editing | Revalidate selected model/harness before writing | Fresh mutation preflight and catalog reload | Source inspected; stale-choice tests required |
| Change session/server during request | Do not apply old result to another account/server | Connection generation and scoped operation key | Source fix re-inspected; direct lifecycle race regression remains important |
| Lost confirmation | No automatic retry; explicitly reconcile before sending | Uncertain-operation set and Review current settings | Source inspected; deterministic transport tests required |
| Foreground/reconnect | Rehydrate identity without overwriting later streamed metadata | Existing stream-before-hydration plus configuration merge | Source inspected; concurrent-read regression identified below |
| Large text/small phone | Scroll content, 44-point choices, reachable apply/cancel | Form/List navigation, safe-area action, multiline labels | Runtime visual validation required; source alone is insufficient |

## Findings and source-resolution status

1. **Connection scope:** the initial sheet captured a session ID but not its
   connection generation. An old sheet could target a matching ID after a server
   change. The sheet now pins its opening generation in `@State`, dismisses on
   change, and guards catalog/review/apply actions. Source fix re-inspected; not independently
   executed as a lifecycle test by this audit.
2. **Late accepted mutation:** the initial AppModel dropped accepted results
   after a connection change without retaining uncertainty for the original
   scope. It now marks that scope for explicit review. Source fix re-inspected;
   no independent transport/lifecycle test result claimed here.
3. **Partial writes:** model can succeed before effort fails. Such an operation
   cannot be reported as a wholly rejected write. Successful HTTP responses also
   need requested-field acknowledgement checks, not merely matching session ID.
   **Fixed in source:** operations are serialized per session; failures after a
   saved model are treated as uncertain, requested fields are checked, and the
   UI requires review rather than automatically retrying.
4. **Default selection:** `ModelChoice.matches(nil)` initially matched every
   catalog option whose optional `model` was absent. This could mark Harness
   default and multiple explicit models as selected. **Fixed in source:** nil
   never matches an explicit model; default checkmarks require reported state.
5. **Missing event value:** absent/malformed `model` or `reasoning_effort` in an
   SSE event initially cleared the setting just like explicit JSON null. The
   existing web parser rejects a missing field. **Fixed in source:** only a
   string or explicit JSON null can update the setting.
6. **Read/stream ordering:** a configuration GET or mutation response could
   overwrite newer streamed configuration while its request was in flight.
   **Fixed paths re-inspected:** configuration reads validate epochs; slow
   history/list/inventory reads preserve newer cached metadata; an in-progress
   hydration queues a follow-up; accepted metadata carries monotonic revisions.
   AppModel preserves newer metadata across its independent snapshot, activity,
   list, inventory and direct-result paths. Tests cover slow reads and
   out-of-order metadata callbacks. The final producer gap was also corrected:
   all accepted read/update summaries use `cacheSummary` to synchronize active
   reducer metadata before a later transcript delta republishes it. Source
   re-inspection confirmed the helper is used by list, inventory, history,
   editable-session, mutation and configuration paths.
7. **Provider-family reset copy:** SDK `antigravity` and Qwen belong to the
   backend's OpenAI family. The initial mobile mapping treated antigravity as
   Gemini and omitted Qwen, incorrectly promising resets. Backend source of
   truth: `omnigent/onboarding/provider_config.py`. **Fixed in source:** SDK
   antigravity and Qwen map to OpenAI; native antigravity remains Gemini.
8. **Missing versus default:** absent configuration/fields initially displayed
   Harness default. Missing or unavailable metadata must read Not reported;
   only reported absence of an override establishes the default state.
   **Fixed in source:** model/effort presence flags distinguish absent fields
   from explicit null, including older saved state and partial list projections.
9. **Catalog recovery:** the initial catalog was loaded only at sheet creation.
   A host that came online while the sheet remained open could still appear
   offline in the cached harness choices. Reload on entering harness choices,
   host-readiness changes and explicit review was requested. **Fixed in source:**
   these events now load choices, generation guards reject another connection,
   and an event during a load queues another load instead of being dropped.
10. **Edit baseline and child navigation:** model selection now checks conflict
    and availability again before incorporating preview choices, so a stale
    rendered row cannot silently accept another client's changed settings.
    Every picker destination exposes Done/Cancel. These source fixes were
    re-inspected; accessibility reachability still requires native validation.
11. **Sparse list events without a runner echo:** a model change can be persisted
    without a `session.model` SSE echo, while the session-list WebSocket omits
    model identity. **Fixed in source:** sparse `changed` frames and reconnect
    `snapshot` frames invalidate the active session's detailed snapshot. This is
    event-driven, not a client polling timer; heartbeats and complete-identity
    frames do not schedule the read. Concurrent triggers coalesce through the
    existing hydration follow-up flag, and metadata epochs protect a delayed
    read against a later complete update. Source inspection found no direct
    read-to-WebSocket feedback loop: hydration reads/publishes local state, it
    does not mutate the session or resend the watch set.
12. **Stopped-stream readiness:** adding WebSocket-triggered hydration exposed a
    stale-heartbeat hazard after SSE completion or failure. **Fixed in source:**
    both the new hydration trigger and the transition to Connected require an
    active SSE data task. A retained heartbeat alone cannot revive a stopped
    stream. Deterministic tests cover sparse changes, reconnect snapshots,
    crossed reads and the stopped-transport case; this audit did not execute
    those tests or a provider-backed continuation.
13. **Competing expanded-editor presentations:** configuration now opens from
    the expanded editor's own sheet state; an arriving error does not also
    present Composer details while configuration is open. Keep current harness
    is disabled and guarded during confirmation or an in-flight apply. These
    source changes preserve the selected target through an operation; no native
    presentation or accessibility test result is inferred here.

No configuration operation inspected here writes or clears the message draft.
Applying, cancelling and switching settings therefore preserve the separate
draft store; native tests remain the check for the complete interaction.

## Contract checks and limits

- The native history-preserving targets were compared with
  `_FORK_HISTORY_NATIVE_HARNESSES` in
  `omnigent/server/routes/_sessions/common.py`. Cursor and OpenCode are correctly
  excluded: the backend documents their history preamble as fork-only, not
  in-place switch support.
- `SessionResponse` reports harness and model but no separate provider identity.
  Showing Provider: Not reported is truthful; deriving a provider from a model
  name would not be.
- The backend clears model/effort with the explicit `default` string. JSON null
  means no update for these PATCH fields. The native mutation uses the correct
  clear sentinel.
- The existing API has no compare-and-swap token for configuration writes.
  Rechecking before a write and guarding streamed changes prevent known stale
  edits; they cannot make simultaneous writes from two clients atomic.
- Host configured/online state does not prove provider authentication or that a
  switched runtime can generate a response. Deterministic configuration tests
  must not be described as a model-response or native-history replay test.
  The server resets the previous runtime asynchronously and materializes the
  target on subsequent access; a successful switch acknowledges the binding,
  not provider execution. Same-family model identifiers may still be
  unsupported by the target's own catalog and should be reviewed after switching.
- New-session provisioning, real-phone authenticated networking, attachments,
  global defaults and provider installation remain outside this audit's scope.

## Reproduce the native journeys

1. Open `web/ios/NativeLab/NativeLab.xcodeproj` and run the NativeLab scheme on an
   iPhone simulator. Use the offline sample workspace for non-provider tests.
2. Open an editable idle sample session, type a distinctive draft, and tap the
   harness/model control above the text field. Search/select a sample model,
   cancel, and verify both current identity and draft are unchanged.
3. Repeat and apply. Reopen the picker, change supported reasoning, and inspect
   Session details. Verify both composers and the session row agree.
4. Select another available sample harness, review the warning, cancel once,
   then confirm. Verify the session ID, transcript and draft remain intact.
5. Open busy/read-only/archived sample sessions and verify inspection still
   works with explained disabled actions.
6. Repeat steps 2–4 on an SE-sized simulator with accessibility text sizes.
   Open the expanded editor and keep the keyboard visible while checking the
   identity control and primary actions.
7. For the isolated local server, connect to loopback and inspect a real
   session's identity, advertised models and details. Do not claim provider
   switching or generation from this read-only check.

The implementation team's final validation report should record exact test
commands, pass/fail/skip counts and screenshot/result-bundle paths. This audit
does not substitute source inspection for those results.
