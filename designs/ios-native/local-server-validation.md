# Native local-server validation

Validated 2026-10-16 through 2026-10-17 on branch `feature/mobile-native-core`.
All changes remain local and uncommitted. The production WKWebView target and
the original Downloads prototype are unchanged.

## Delivered scope

NativeLab now connects explicitly to a loopback-only, single-user Omnigent
server. It verifies discovery and local identity, pages sessions, lazily loads
conversation history, and refreshes on request or foregrounding. Live mode is
read-only in both the UI and transport. Demo drafts remain separate and survive
switching into live mode and back.

The expanded demo composer is an opaque full-screen native editor. A compact
glass footer preserves writing space in portrait; landscape moves actions into
the toolbar. Long status and error text lives in a scrollable details sheet.

The API at `http://127.0.0.1:6767` is a separate local instance with isolated state
under `.native-lab-server/`. It is not the hosted server powering this conversation.
Its three conversations and 60-message pagination history are stored fixtures,
not generated replies. Seeding does not launch agents or models.

## Verification

Environment: Xcode 27.1 (27A9275), Swift 6.4, macOS 26.7.1, Apple Silicon.
Both regular iPhone simulators use iOS 26.0 (23A343).

| Check | Result | Evidence |
| --- | --- | --- |
| Foundation core, real-server test enabled | 41 passed, zero failures/skips | `OMNI_LOCAL_API_TESTS=1 swift test --scratch-path /private/tmp/omni-local-api-core-build` |
| iPhone 17 Pro focused rerun | 4 passed, zero failures/skips | `/private/tmp/omni-live-team-17-recheck.xcresult` |
| iPhone SE initial full suite | 10 passed, one failed, zero skips | `/private/tmp/omni-live-team-se-full.xcresult` |
| iPhone SE intermediate live rerun | 2 passed, one failed, zero skips | `/private/tmp/omni-live-team-se-switch-recheck.xcresult` |
| iPhone SE final live rerun | 3 passed, zero failures/skips | `/private/tmp/omni-live-team-se-live-final.xcresult` |
| Generic physical-iPhone compile | Passed, signing disabled | `/private/tmp/omni-live-team-device-derived` |
| Swift strict formatting, whitespace, shell syntax, fixture Python compilation and Ruff | Passed | Local checks on current sources |

The 17 Pro run covers all three connection/live journeys plus the largest-text
portrait/landscape editor journey; it is not a full eleven-test run on that phone.
The core suite includes 19 API-adapter tests and the existing 22 offline tests.
One API test uses the default URLSession transport against the isolated real
server, checks both session pages and all 60 chronological messages, and confirms
stable unique IDs. Without `OMNI_LOCAL_API_TESTS=1`, that test explicitly skips.
Two UI journeys also skip if the local fixtures are unavailable.

All eleven SE journeys are covered by passing results across the initial full
run and final focused rerun. There is no single clean eleven-test SE result
bundle for this iteration; the original full run remains failed. App code was
unchanged between those SE runs. Both regular-phone apps were subsequently
relaunched without UI-test/reset arguments; the development server remains
running on loopback for interactive testing.

The physical-device build is not a signed install or a physical-phone test.
Xcode reports the existing iPad all-orientations warning. Toolchain warnings
about `invalidDigitCount(94232)` also appeared in successful simulator runs.

### Initial failures and repairs

The initial integrated 17 Pro run had two passing journeys and one failure:
`/private/tmp/omni-live-team-initial.xcresult`. Editing the URL brought up the
keyboard, and the fixed demo footer overlapped the Connect button. The welcome
screen now hides that footer while the field is focused, supports keyboard Go,
and dismisses focus on Connect. The unavailable-server journey passes after
the repair.

Visual inspection also caught an initially blank transcript even though message
existence assertions passed. The conversation now scrolls to the latest message
after layout; the live test additionally requires that message to be hittable.
The original failed result and its attachments are retained, not reclassified.

The SE full suite passed all eight offline/editor journeys and two live journeys.
The mode-switch journey failed when the test helper's large, one-way swipes
skipped the Settings connection button and kept scrolling to the bottom. The
failure's activity trace and accessibility hierarchy record that sequence. The
helper uses smaller bounded drags in both directions for collection views,
checks existence before accessing a recycled element, and still requires an
enabled, hittable button before tapping. Only the test harness changed for this
repair.

An intermediate rerun confirmed the round-trip repair but exposed a helper
regression in the unavailable-server journey: normalized drags over the welcome
ScrollView landed behind its software keyboard. ScrollViews now retain the
original native swipe gestures; small drags are limited to collection views.
The intermediate failure is preserved in the table above. An independent team
review confirmed the evidence and container-specific correction.

### Visual inspection

The passing 17 Pro captures were inspected for actual visible content, not only
accessibility-tree presence. The transcript displays the newest fixture message;
older pagination displays message 01. The full-screen editor has an opaque
background without the underlying transcript/title bleeding through. At the
largest tested text size, the keyboard, draft and editing controls remain visible
in portrait and landscape.

The SE screenshots also show opaque normal/large-text editors and the newest
live message. At maximum text size in SE landscape, the editor has room for
the active line; preceding text is partly scrolled under the toolbar. The
keyboard-dismiss and Done controls remain visible. Long drafts require scrolling
or dismissing the keyboard in that constrained layout.

- [17 Pro live conversation](screenshots/local-iphone-17-live-conversation.png)
- [17 Pro largest-text editor](screenshots/local-iphone-17-large-text-editor.png)
- [17 Pro landscape editor](screenshots/local-iphone-17-landscape-editor.png)
- [SE normal editor](screenshots/local-iphone-se-editor.png)
- [SE largest-text editor](screenshots/local-iphone-se-large-text-editor.png)
- [SE landscape editor](screenshots/local-iphone-se-landscape-editor.png)
- [SE live conversation](screenshots/local-iphone-se-live-conversation.png)

Original attachments are in `/private/tmp/omni-live-team-17-attachments/` and
`/private/tmp/omni-live-team-se-attachments/`.
Earlier defect captures remain in [regular-phone-validation.md](regular-phone-validation.md).

### Acceptance coverage

| Criterion | Evidence and remaining scope |
| --- | --- |
| AC1: explicit local connection | Real transport smoke test and live UI journey pass. |
| AC2: pagination and order | Core checks all 60 messages and unique IDs; UI loads further sessions and older history. |
| AC3: read-only enforcement | Core rejects every mutation without a request; live UI has no composer, send, stop or new-session controls. |
| AC4: honest failures | Adapter tests cover identity/auth/transport/decoding failures; UI unavailable-server journey requires an error and explicit demo choice. |
| AC5: mode isolation | Demo draft survives the live-mode round trip. Stale-response guards were code-reviewed; a delayed-response race was not separately UI-tested. |
| AC6: refresh/recovery | Manual refresh control exercised against unchanged fixtures. Changed-server data and foreground recovery are implemented but not separately exercised; this part remains unverified. |
| AC7: readable phone editor | 17 Pro and SE editor tests pass; screenshots inspected, including the limited SE landscape writing space described above. |
| AC8: reproduction | Core and native builds verified; commands below reproduce live and UI checks. |

## Reproduce

From the repository root, start the isolated API in one
terminal if it is not already running:

```sh
OMNIGENT_SKIP_WEB_UI=true uv sync --frozen --no-dev
bash web/ios/NativeLab/bin/local-server.sh
```

In a second terminal at the repository root:

```sh
.venv/bin/python web/ios/NativeLab/bin/seed-local-fixtures.py
OMNI_LOCAL_API_TESTS=1 swift test --package-path web/ios/NativeLab
OMNI_LOCAL_API_TESTS=1 bash web/ios/NativeLab/bin/check.sh 3FE85398-4342-4F05-BC55-C2DFBD5B6CB2
open web/ios/NativeLab/NativeLab.xcodeproj
```

Choose **NativeLab > Omni iPhone 17 Pro** or **Omni iPhone SE**, then **Cmd-R**.
Tap **Connect to local server**, retaining `http://127.0.0.1:6767`. Open
**Local API validation**; confirm the read-only footer and message 60. Scroll
to the top, tap **Load older messages**, and confirm message 01. Tap Refresh.

For editing, choose **Settings > Use offline sample workspace**, open
**Native mobile design**, expand the composer, and type a multiline draft.
Check portrait, landscape, large text and keyboard dismissal. Done and reopening
the editor should preserve the exact draft. The details button shows the pending
approval reason; writing does not approve it automatically.

## Limits and remaining checks

- Live sends, approvals, creation, session edits, SSE, hosted login and push are
  not implemented. Refresh reloads the first session page and newest history
  window; older pages remain accessible through Load more.
- Live state is in memory only; reconnect explicitly after relaunch. Search
  and filters operate on loaded session pages only.
- Physical-phone server access is unsupported in this slice: `127.0.0.1` on a
  phone is the phone itself. Do not expose this no-login server to the LAN.
  The offline demo can be installed after configuring personal signing in Xcode.
- Physical keyboard/dictation behavior, VoiceOver, Reduce Transparency, dark
  appearance, iPad and the iOS 18 material fallback still need hands-on checks.
- Changed-server foreground refresh and artificially delayed mode-switch races
  need additional targeted coverage before treating those behaviors as validated.
