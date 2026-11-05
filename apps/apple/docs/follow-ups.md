# Native apps: follow-up list

The running list of deferred and follow-up work for the native Apple apps and the Rust core.
Keep it current:
- add items when work is deferred;
- move finished items to "Done", with the date and the change that closed them;
- link the design doc that has the details instead of repeating them here.

## Browser: Apple passkeys and http/https

Details: [browser-engine-decision.md](browser-engine-decision.md), sections "Entitlements and the
Apple process" and "Recommendation and plan" (phase 1b).

- [ ] **Register `OmnigentMac` as a web browser.** Add `CFBundleURLTypes` for `http` and `https`
  to the Info.plist. Apple's passkey criteria expect it, and it also makes Omnigent selectable as
  the default browser in macOS. Deferred by the user on 2026-11-01; decide before the entitlement
  request.
- [ ] **Apply for the passkey entitlement.** Request `com.apple.developer.web-browser.public-key-credential`
  through "macOS Browsers Passkeys"
  (https://developer.apple.com/contact/request/macos-browsers-passkeys/). The Account Holder
  submits it for `ai.omnigent.mac.webhost`, probably `ai.omnigent.mac` too, and
  `ai.omnigent.mac.appstore` if the WKWebView edition needs passkeys for arbitrary sites. Until
  then, iCloud Keychain passkeys and Touch ID don't work in the Chromium browser. Security keys,
  Okta FastPass and 2FA codes work without it.
- [ ] **After approval:** enable the capability on the App ID and create a Developer ID
  provisioning profile for the host bundle. Add the Release-only host entitlements
  (`web-browser.public-key-credential`, `keychain-access-groups`
  `$(AppIdentifierPrefix)org.chromium.Chromium.webauthn`). The exact diff is in the doc.
- [ ] **Run the manual hardware checklist:** YubiKey with a PIN, iCloud Keychain passkeys,
  phone-as-passkey over Bluetooth, and Okta (see the doc's "Manual test checklist").

## Browser: CEF

- [ ] **Okta SSO extension:** it returned `NotSupported` for the Chromium host in the spike. Retest
  with a Developer ID-signed build, and compare with Google Chrome's
  `chrome://histograms/Enterprise.ExtensibleEnterpriseSSO`. If Okta flows need it, add a per-site
  WebKit fallback (`BrowserEngineKind`); the trade-off is that the tab uses WebKit cookies.
- [ ] **Managed allowlist** for local-network access, so organisations can pre-approve Okta
  FastPass's loopback probe.
- [ ] **WebKit WebAuthn:** the spike was inconclusive ("document is not focused"). Retest in a
  focused window.
- [ ] **Bug:** the Chromium tab's "No app opens …" message for external links is overwritten by
  the next state sync.
- [ ] **Prebuilt engine pipeline (phase 2):**
  - Stand up 2+ self-hosted Apple Silicon builders (64 GB RAM, 1 TB+ SSD, label
    `chromium-engine`).
  - Move `scripts/engine/chromium-engine.yml` to `.github/workflows/`.
  - Publish a first unpatched `omnigent.1` build to prove the pipeline, then pin
    `scripts/engine/omnigent-cef.lock`.
- [ ] **CEF patches (phase 2b):**
  - native back/forward history restore (today we rebuild history with placeholders)
  - tab freeze and discard hooks, with memory-pressure handling
  - renaming the WebAuthn keychain group to `ai.omnigent.mac.webhost.webauthn`
  - proprietary codecs (H.264, AAC), after a license review
  - Widevine, which needs a separate agreement with Google
- [ ] **Custom Chromium host (phase 3),** only if Chrome Web Store extensions or Chrome's own
  TabManager become requirements.
- [ ] **Known CEF limits, not yet scheduled:**
  - DevTools opens in a separate window
  - audio detection covers `<audio>`/`<video>` only
  - clearing site data is coarse
  - Chrome Enterprise device-trust checks can never pass outside Google Chrome

## Remote browser

Details: [remote-browser-design.md](remote-browser-design.md).

- [ ] Diff the core's macOS keycode and USB-HID to DOM `code` tables line by line against
  Chromium's (`ui/events/keycodes/dom/dom_code_data.inc`); HID 0x32 maps to `Backslash` per the
  W3C spec, Chromium may use `IntlHash`.
- [ ] Host: x264 sometimes ignores a qpfile IDR request ("switching to encoder restarts"); the
  restart fallback works, but find out why the in-stream IDR path is skipped.
- [ ] Confirm hardware H.264 decode on a physical iPhone/iPad (simulators have no hardware decoder;
  the renderer logs the VideoToolbox probe at launch).
- [ ] Add a reconnect-after-unexpected-close case (with backoff) to the headless e2e gate.
- [ ] Remote browser UI tests should close the remote tabs they open, so runs don't pile up tabs
  on the shared host.
- [ ] M2 to M5 from the design doc: agent CDP and tab mapping, handoff and takeover, profiles,
  settings and hardware encoders.
- [ ] **Share the CEF core between the OWL host and `browser-host/`.** M1 copied and adapted the
  portable parts of `WebHost/Sources` (popups, JS dialogs, IME, cursor mapping) instead of
  extracting them, to leave the Mac host untouched. Extract them into `browser-host/core` with
  both hosts building it.
- [ ] **Agent-created tabs over CDP (M2).** Playwright `newPage()` fails and raw
  `Target.createTarget` makes a non-windowless browser that never paints
  ([remote-browser-m0.md](remote-browser-m0.md)). Add `browser_tabs open`, or a CDP proxy that
  turns `Target.createTarget` into a host tab.
- [ ] **macOS host: `CefShutdown` stalls** while Chromium releases a Keychain handle (seen when
  launched from an agent shell). The host bounds it to 5 s and kills its helpers; find the cause.
- [ ] **Re-run the M0 render and live bench on a 2-4 vCPU cloud VM** before fixing the CPU
  budget and the Linux display default (headless Ozone vs Xvfb).
- [ ] **Package the host** (G1): link libjpeg-turbo statically, CI builds for linux x86_64 and
  arm64 and macOS arm64, `omnigent browser install`.
- [ ] **Gate remote browser tabs on the server.** The apps offer them only behind the
  `OmnigentRemoteBrowser` user default (or `OmnigentRemoteBrowserFixture` for the fixture host)
  because nothing advertises them yet; gate on a `/v1/info` or runner field once one exists.
- [ ] **iOS remote tab input (E3):** on-screen keyboard driven by `text_input`, marked text, and
  pinch to zoom the video. M1 has taps, long press, pan or trackpad scroll and hardware keys.
- [ ] **macOS IME caret:** place the candidate window at the host's `text_input.caret` instead of
  the page's bottom-left.
- [ ] **Video off the main thread:** frames hop to the main actor before
  `AVSampleBufferDisplayLayer` enqueue; move enqueue to a dedicated queue if main-thread stalls
  show up in frame age.

## Server (upstream omnigent)

- [ ] **Edit approvals:** send the full tool input, or a structured list of file changes, for edit
  tools. Previews are capped at 1024 characters, so large edits show no line counts.
- [ ] **Codex `item/fileChange/requestApproval`:** attach the `changes` from the matching
  `fileChange` item; today the approval lists no files.
- [ ] **Capabilities:** advertise feedback and steering support, so clients show only the controls
  a harness supports.
- [ ] **Pending-input queue:** stop treating the runner's interrupt marker as consuming a queued
  message.
- [ ] **Runner restart:** after a server restart the newly bound runner resumes a stopped turn with
  no new user message (one extra model call), and the stopped reply's partial text is never
  saved to item history.
- [ ] **CLI:** remove the pidfile on SIGTERM.
- [ ] **Session delete:** the server's `DELETE /v1/sessions/{sid}` ignores the runner's response
  status (only transport errors are caught, then it deletes server-side anyway), so a runner
  `resource_cleanup_failed` 500 (for example a browser host that failed to close tabs) is not
  surfaced (`omnigent/server/routes/sessions/routes_events.py`, around line 3835).

- [ ] **APNs push for phone supervision.** Device registration, the outbox and delivery for
  input requests and turn ends, with the identifier-only payload and the security model in
  [phone-supervision.md](phone-supervision.md) ("Server half"). Start from the NativeLab
  prototype (`mobile_notifications.py`, `mobile_apns.py`); move its outbox to the server
  database before running more than one process. Then register from the apps
  (`omnigent_core::notifications::push`) and add a Notification Service Extension for titles.
- [ ] **Device-link pairing tokens:** short-lived, single-use tokens in the pairing code for
  accounts and OIDC servers (phone-supervision.md, "Pairing tokens (v2)").

## Apps

- [ ] **Read state:** persist this device's read marks across relaunches; today they are kept in
  memory only.
- [ ] **Phone supervision on a physical iPhone:** approve from the Lock Screen end to end (Face
  ID, background launch, the saved sign-in), and check that `BGAppRefreshTask` runs. The
  Simulator can't verify either; see [phone-supervision.md](phone-supervision.md).
- [ ] **Sub-agents:** a child session can appear both in the parent's mirrored count and in its own
  list row, which may double-count "needs you".
- [ ] **Sub-agents:** a running child's elapsed time uses the wall clock.
- [ ] **iPhone reading posture:** the focus guard ignores a deliberate tap on the composer within
  1 s of opening a session.
- [ ] **iPhone:** transcript content shows briefly under the dock and composer while the layout
  settles.
- [ ] **Onboarding (Mac):** offer the remote (Arca) runner in "Where do you work today?" where
  Electron does (Databricks-managed servers only).
- [ ] **Invite links:** `https://…/register?invite=` links open in the browser; only
  `omnigent://host/register?invite=` links and pasted links reach the app. Opening the https form
  needs associated domains on the server.
- [ ] **Harnesses:** Settings does not probe harness accounts on open
  (`POST /v1/hosts/{id}/harnesses/accounts/refresh`), lacks the Isaac/personal credential cards
  of the web's Authenticate step, and has no MCP servers / skills / plugins tabs on the details.
- [ ] **Tabs:** drag-to-reorder on iPad.
- [ ] **Split view:** in iPad portrait the right pane's tab-strip section is narrow and clips titles.
- [ ] **Split view on the unfolded Duo:** the hinge layout applies only when both sides of the
  crease are at least 320 pt in the detail column; with the sidebar shown it probably falls back
  to the fraction layout. Verify on hardware.
- [ ] **Test data:** remove the two "Tabs fixture" sessions from the integration server's
  database.
- [ ] **Share:** the session Share control isn't wired in the real app yet; there's no share store
  or core API.
- [ ] **Tabs:** the overview menu's "Recently Closed" entries are inert labels.
- [ ] **Right panel, Pull Requests:** the PR detail (checks, reviewers, labels, stacked diff,
  merge, comments, link/unlink) is ported. Not yet: inline review threads in the diff (read,
  reply, start), editing the title and description (with attachment uploads), the provider
  account and base-remote pickers, a resizable file tree beside the diff (a jump-to-file menu
  stands in), split layout for the stacked diff, the offline fallback to the server's stored PR
  with its "Host offline" hint, and periodic polling while checks run (it refreshes on open,
  Refresh and turn end).
- [ ] **Right panel, Agents:** a sub-agent's chat shows only its own children, not the root's
  tree (the web reads `GET /v1/sessions/{id}/child_sessions` from the root); no graph view or
  Add agent.
- [ ] **Right panel, Pull Requests:** lists the server's stored PRs only. The web's PR view (the
  runner's `/resources/github`: checks, reviewers, labels, the stacked diff, merge, comments,
  linking and unlinking a PR) is not ported.
- [ ] **Right panel, Agents:** no Add agent (the web renders its button hidden, so it is not
  offered); the agent rows show role icons, not each native harness's logo.
- [ ] **Transcript selection popup:** SwiftUI selects within one text block, so Reply and Ask in
  side chat quote at most one paragraph or code block (the web can select across messages).
- [ ] **Right panel, Open new:** no Side chat item; starting a new side chat has no route yet.
- [ ] **Tabs:** the titlebar tab row reserves a fixed estimated width for the trailing controls. An
  account chip or four viewers may leave a gap or push items into overflow; measure it instead.
- [ ] **Lint:** `SupportingScreens`, `AdapterTests` and `NativeAppE2EUITests` have pre-existing
  swift-format/lint findings.

- [ ] **Decision forms:** wire `validateForm(fields:values:)` into `ConversationContainer` so the real
  app shows field-keyed form errors (the playground already does).
- [ ] **Mac sidebar:** with the window inactive, the Running and Needs you rows don't dim like the
  other rows (`QuickFilterRow` forces the primary color).
- [ ] **iOS sidebar:** the swipe actions still use system orange (Pin) and indigo (Archive).
- [ ] **Mac sidebar:** composer drafts live only in the core's memory, so the draft marker covers
  sessions opened since launch (the web keeps drafts in local storage).
- [ ] **Mac sidebar:** the row tooltip has no PR line; the core's `SessionSummary` doesn't carry
  the session's `pull_request` yet (web `SessionTooltipDetails`).
- [ ] **Mac sidebar:** the Inbox badge counts sessions that need you (matching the Dock and menu
  bar); the web counts pending requests plus unseen comments.
- [ ] **Project settings:** the working directory is a typed path; the web also offers its folder
  browser, and its agent picker shows harness readiness.
- [ ] **Mac sidebar:** "This Mac" in the Environment detail is a guess (the only online machine of a
  loopback server) until the app knows the host it runs; pass that id to `host_environments`.

- [ ] **Palette:** add "Go to Automations" once the Mac app has an Automations page.
- [ ] **CLI style:** the CLI composer has no host chip, and its status-line model menu duplicates
  `ConfigurationMenu`'s pickers (no agent switch).
- [ ] **CLI style:** fold the non-message hover host (`cliActions`) into the shared
  `messageActionsHost` once it takes arbitrary actions.
- [ ] **Markdown: message attachments** whose bytes were inline (`data:` image blocks) stay
  "Embedded, not kept" chips: the core drops embedded bytes from rows (the web shows them).
- [ ] **Markdown: file links** to paths outside the workspace are not linked: the web opens them
  in its viewer through `?base=host` reads, which the core's workspace paths refuse by design
  (`workspace/path.rs`). Needs host-absolute list and read in the core and the file viewer.
- [ ] **CLI style on iOS:** the request review sheet opened from the dock keeps the system sheet
  background instead of the terminal canvas.
- [ ] **CLI style on iOS:** the unfolded iPhone Duo is untested; the Xcode 27.2 simulator has no
  unfold control (the inner display stays off).
- [ ] **iOS navigation bar:** scrolled to the top, a conversation's large title is not drawn (chat
  and CLI on iPhone), which leaves an empty band under the bar buttons. Suspect
  `TitlebarBackdrop`, which fills the top safe area.
- [ ] **Gallery device frames:** conversation pages put the touch composer over the home
  indicator, but on the simulators it sits above the bottom safe area (iPhone 17 Pro, folded
  Duo). The gallery's bottom inset does not reach the page's own `safeAreaInset`.

- [ ] **Gallery:** page and flow toolbars leak into the gallery window's toolbar; captures draw
  modals and the tab strip in place (Open in Window shows the real chrome).
- [ ] **Gallery:** add `initial…` parameters so it can preset server settings panes, Inbox
  selection and the palette query (they live in private view state).
- [ ] **Gallery:** export takes about 1 s per image (blur and shadow rasterization); render at 1x
  or in parallel. Tests' `RenderSupport` could reuse `CatalogExporter.render`.
- [ ] **UI review from the gallery:** sign-in screens use system blue instead of the Omnigent theme;
  "Tell the agent instead" with a shared draft opens in both the inline card and the dock.

- [ ] **Tabs: primary chats accumulate.** Tabs span sessions per window and a session's primary
  chat cannot be closed, so every session opened from the sidebar stays in the strip until it is
  archived or deleted. Decide between per-session tab scoping, a preview tab, or a "Close
  Session in This Window" command.
- [ ] **Split view:** the other pane's Inbox, New Session and browser views still publish their
  toolbar items and focused values (only conversations and terminals defer to the focused pane);
  notification suppression covers only the focused pane's chat.

- [ ] **iPhone Duo unfolded:** the Xcode 27.2 simulator can't unfold, so the unfolded posture
  (safe areas, size classes, the `.division` region, camera position, `ArrangementView`'s axis)
  is unverified; check on hardware or a later Xcode. Folded was measured: 466x678 pt, an 84 pt
  trailing status column, and `ArrangementView` stacking vertically 50/50.
- [ ] **Gallery:** status-bar SF Symbols (Wi-Fi, battery) don't render in exports.

- [ ] **Fork:** the Mac fork sheet has extra empty space below its content; take iPhone/iPad fork
  screenshots once the iOS re-render loop is fixed.

- [ ] **Flaky test:** `OmnigentTerminalUITests.ConfigAndInputTests.configParses` intermittently
  segfaults in `ghostty_config_new` (null dereference), likely a race in libghostty's global
  initialization when Swift Testing runs suites in parallel; serialize the suite or initialize once.

- [ ] **Error copy:** runner failures still surface raw text ("the session's runner is unavailable
  (HTTP 503)…"); map them to plain-language banners with a retry.
- [ ] **Tabs (Mac):** no hover card for tabs (only the close button and a title tooltip).
- [ ] **Sandboxes, not yet native:** the sandbox model preview (`inference_models`,
  `configuration_revision`), the Databricks git-credentials hint, the arclet dbcert preflight,
  remembering the last sandbox repositories, and re-checking a chosen profile's revision before
  launch (the server rejects a stale one). Verified against fake servers only: the local
  server has `sandbox_profiles` off.
- [ ] **New-session composer:** no `/` commands, `@` mentions or skill pills before the session
  exists (the web reads the agent's bundled skills and the host's catalog; the core reads skills
  only per session).
- [ ] **Share sheet:** people search (the web's comes from an embedder-provided directory, not a
  server API), the public access level picker and a QR code are not native yet.
- [ ] **Archive Undo and worktrees:** after the server's grace the worktree is gone and Undo
  only warns; recreating it needs a runner launch with `existing_branch` for the unarchived
  session.
- [ ] **Tests (Mac):** run the two remaining Mac UI tests (launch smoke, titlebar drags) in a
  macOS VM so they never take the developer's mouse and keyboard: Tart
  (`ghcr.io/cirruslabs/macos-tahoe-xcode:27.2`, 70.8 GB compressed) with the tests built on the
  host and run there with `test-without-building`. Deferred; Tart 2.41.1 is installed locally.
- [ ] **Tests (Mac):** with the Mac UI tests trimmed to what needs real input, two things have no
  automated check: message actions (Copy, Fork) appearing only on hover, and the pane-focus
  shortcuts (Option-Command-Arrow). Cover them with a render test that forces the hover state and
  a test of the command table.
- [ ] **Gallery:** the iPad split page renders poorly in the gallery canvas.

- [ ] **Contrast:** under dark Increase Contrast the needs-you text goes nearly white in Dracula,
  Gruvbox and Nord; a lighter capsule fill would keep the hue. Selected-row text under dark
  Increase Contrast is 6.8-6.9:1 in Catppuccin and Nord (AA, not the 7:1 target).
- [ ] **System blue left:** the iPad keyboard-focus ring on the selected row, the inspector Agents
  list glyphs, and `BrowserSignInViews` alternative sign-in links.
- [ ] **Type:** move row metadata ("2y", server status) to `Theme.mutedText`; put the CLI's
  `CLIMetrics` gaps on the 4 pt grid.

- [ ] **iOS large titles** don't draw anywhere (the conversation band was replaced with inline titles;
  the sidebar's "Omnigent" band is still empty); possibly AppShell's nested NavigationStack.
- [ ] **Folded Duo UI tests:** XCUITest can't navigate (the outer display is captured rotated and the
  back button isn't found); Duo is verified by screenshots only.
- [ ] **Read-only sessions:** consider a "Fork to continue" action on the read-only composer row.
- [ ] **Split view under the titlebar:** a split pane's transcript stops at the toolbar, so the Mac
  draws its flat toolbar background over the panes instead of the soft scroll edge. Extending the
  panes under the bar (`ignoresSafeArea` with `safeAreaPadding`, or an open-top clip) moved the
  browser tab's chrome under the tab row, whose AppKit view ignores SwiftUI safe areas.
- [ ] **Glass in render tests:** `cacheDisplay` draws neither Liquid Glass nor its content, so
  offscreen renders flatten ``GlassSurface`` to a material (`flattensGlass`). System glass
  (toolbar items, `.glass` buttons) still draws nothing there; the gallery's
  `--gallery-capture window` shows the real thing.
- [ ] **Settings › Servers, not yet native:** connecting GitHub, Databricks and OAuth MCP services
  opens the server's web settings, because `/v1/connections/*/connect` needs the browser's
  cookie session; changing a member's role (the server has no role API: roles come from its
  admin list). Add Policy lists registry parameters by name (the core's JSON is unordered) and
  takes a models list as text (the web fills `x-enum-source: models` from its Claude models).
- [ ] **Device preferences without a consumer yet** (keys as on the web): Always steer
  (`omnigent:always-steer`, composer), Always use a worktree and Default base branch
  (`GitPreferences`, new-session form), Delete worktrees on archive (archive action), and "Show
  only the final answer" (`omnigent:fold-assistant-narration`): `TurnLayout` always folds a settled
  turn's progress messages, and the toggle needs a `TranscriptMemo` input plus a Codex
  final-answer marker the rows lack. Interface typography (size and family) has no native
  setting: the Mac app follows the system's text sizes, and Chat text size is under Transcript.
- [ ] **Preferences, partly native:** in-app links open a new browser tab rather than reusing one
  showing the same URL; the right panel has no pinned-tabs setting (its tabs are fixed).
- [ ] **Composer:** `/mcp` lists the agent's MCP servers as text; the web's panel also shows the
  host's own MCP servers for the harness and signs in to registry services. Queued messages still
  can't carry attachments (the core stages attachments per session draft, not per message).
- [ ] **Composer:** Up and Down recall history only from an empty field or while browsing it
  (SwiftUI's editor does not expose the caret, so the web's "caret on the first line" rule is out).
- [ ] **Drafts:** a draft typed in the last half second before quitting can be lost; flush
  `ComposerDraftArchive.shared` on termination.
- [ ] **File comments:** the Comments panel (Open/Sent, Edit, Resolve, Reopen, Delete, Address
  All) is ported; per-comment "Copy link" and the web's inline thread popover on a marked line
  are not (a marker opens the panel at that comment). Seen comments are kept per device, as on
  the web.
- [ ] **File editor:** highlighting while editing and the web's Markdown toolbar (Normal,
  headings, quote, bold, italic, strikethrough, code, link, lists) are ported; the editor has no
  line numbers, and the toolbar has no table insert, undo/redo or copy buttons (the system's
  Undo and Copy work). Unsaved edits are asked about on window close and quit (Mac) and saved
  on tab close and when the scene goes to the background (iOS). In 2 of about 12 simulator runs
  of `FileCommentsUITests` the app trapped on a libdispatch main-queue assertion just after the
  Comments switch was turned on; no report was written, so the cause is not yet known.
- [ ] **List paging, left:** a list reload asks for every loaded row in one request, so past the
  server's 1,000-row page cap the rows beyond it fall out until Load more reads them again; a
  folder's pages are dropped on a reload (the folder reads its first page again); search and the
  quick filters still match loaded sessions only (the web's tabs query the server).
- [ ] **Canvas:** cards show no pull request (summaries carry no `pull_request`), every card is
  drawn (the web draws only visible ones, which matters past a few hundred sessions), the board
  pans with scrolling but not by dragging the background, and there is no "+" to create a project
  from the board tabs.
- [ ] **Toasts:** fork's "Session created [Open]" should use `TransientBanner` (fork flow).
- [ ] **Host import review (Mac):** the web's `ImportReviewGate` (behind the `import_review`
  feature) opens the import modal for a newly connected host's MCPs, skills and plugins; the Mac
  app has no harness-inventory read or modal yet.
- [ ] **Settings › Archived (Mac):** retention uses a session's last change, not the server's
  `omnigent.archived_at` label (the core's session summary does not carry it), and the project
  filter covers loaded pages only (the web pages through every archived session).
- [ ] **Session view parity left:** shared sessions' author badges (`ConversationViewState`
  `isShared`/`viewerName` need the signed-in user's identity, which no store exposes); Download in
  the Files panel; the error card's Continue in another directory, Fork session
  and sign-in link / Copy code; the approval card naming its sub-agent; per-session right-panel
  state; hiding the Pull Requests tab without git.
- [ ] **Automations editor, still short of the web:** the folder is a typed path (no host folder
  browser), a project can only be picked (the web also creates one from a typed name), there is no
  timezone picker (the saved or device zone is kept), and a run's unread dot ignores this device's
  read marks. The run history reloads every 30 s rather than waiting on a started run's row.
- [ ] **Mac performance, next levers** (numbers and tools in [performance.md](performance.md)):
  opening a long session costs about 3 s of main-thread CPU in Debug and switching back to its
  tab about 1.5 s, because a tab's content is rebuilt (keep recent tabs alive, or fewer views per
  markdown block); streaming into a long session uses 30-40% of the main thread (the transcript
  body re-renders per delta); a changed session-list row still sends every session through the
  core twice (an incremental filter in the core would avoid it).

## Product decisions

- [ ] Mac app name, given the existing Electron `Omnigent.app`.
- [ ] Sparkle EdDSA signing key.
- [ ] Ankit's co-author credit on the NativeLab import.
- [ ] Reusing the iOS bundle ID requires a version above 0.3.2.

## Done

- [x] Turn rail: one tick per user turn at the transcript's leading edge (Mac and iPad, both
  transcript styles; left out at compact widths as the web leaves it out on phones), with the
  hover preview, click to scroll, the active turn and paging from its top. List paging: the
  core keeps a list window (`load_more_sessions`, `SessionListPagingChanged`; reloads keep the
  loaded pages), the sidebar's and the Inbox's Load more, and project folders read their own
  pages (`project_sessions`, `?project=`) five rows per Show more. 2026-11-05.
- [x] Right panel, Agents: the whole spawn tree from the top-level session (core
  `agent_tree`, `GET /v1/sessions/{id}/child_sessions` three levels deep), a list with folding and
  a graph view; the composer's background-task list, a Plan mode badge, the hover-revealed jump to
  top and the Reply / Ask in side chat selection popup. 2026-11-04.
- [x] Harnesses: Settings opens a harness's details (account, Switch Account / Sign In Again /
  Reconfigure, Update, the startup command, environment and arguments), with Codex's device
  sign-in and Check Again after a login command. 2026-11-04.
- [x] Onboarding (Mac): Install runs uv's installer when needed, then the published
  `install_oss.sh --non-interactive`, as Electron's `cli_install.js` does. 2026-11-04.
- [x] Hosting: the CLI signs in to a remote server (`GET /v1/me`, then `omnigent login`) before
  `omnigent host` starts, as Electron's `ensureServerAuth` does. 2026-11-04.
- [x] Mac sidebar: "This Mac" is the host id in the CLI's `config.yaml`, passed to
  `host_environments`. 2026-11-04.
- [x] Invite links: `omnigent://host/register?invite=` deep links and pasted invite links open
  Create Account with the invite. 2026-11-04.

- [x] Composer commands and sends (2026-11-04): `/side`, `/clear` (when `/v1/info` lists the
  `clear` control), `/context`, `/mcp` and `/permissions`; a failed `@` search shows its note
  with no rows; message sends and Inbox replies send `x-omnigent-hold-when-host-offline`, a 503
  `host_offline` is `SessionError::HostOffline` (a definite refusal) and the composer holds the
  message until the host is back; drafts persist per account and session
  (`ComposerDraftArchive`, which also seeds the sidebar's draft marker); Settings › General ›
  Sessions "Automatically name new sessions" sends `X-Omnigent-Background-Session-Titles: off`.
  Keyboard: Up/Down through completions and prompt history (Up first pulls back the last queued
  message), ⌘Return sends with the whole queue, ⌃⇧M/⌃⌥M/⌃⌥E choose and cycle model and effort;
  `@` paths become chips sent as `[Attached: path]` lines; queued messages reorder by drag.
- [x] **Markdown: uploaded images, CLI code colors, folder and `~/` links.** Images uploaded with a
  message show inline above its text (click to enlarge) through the core's
  `attachment_preview` (session files only, preview MIME and size limits); the CLI Styled
  rendering colors fenced code with the terminal palette; an explicit link to a folder shows it
  in the Files tree, and `~/` paths expand with the environment's `home`. 2026-11-04.

- [x] **Markdown: Mermaid and math.** ```` ```mermaid ```` blocks draw as diagrams and TeX is
  typeset by KaTeX, both in one offscreen WebKit view (`RichBlockRenderer`, non-persistent data
  store, no navigation) whose snapshots show as native images; KaTeX and Mermaid are package
  resources from `scripts/vendor-rich-render.sh` (Mermaid LZMA-compressed under the 1 MB file
  limit). Streaming blocks stay code or Unicode until they close. 2026-11-04.
- [x] **File comments and editor:** comments edit, delete, resolve, reopen and Address All (one
  agent message, reopened if it fails) through the server's comments API, open ones following
  their moved anchor; the editor highlights as you type (one line per keystroke, large pastes
  off the main actor) with the web's Markdown toolbar; CRLF selections comment with `\r`-aware
  offsets; Save / Don't Save / Cancel on Mac window close and quit, save on iOS background and
  tab close. 2026-11-05.
- [x] Automations editor: host or sandbox pin with a folder, project, model, effort and
  permission mode (Claude Code), end conditions (date, and run counts on `automations_v2`),
  Jira/Slack/GitHub trigger templates (prompt rendered by the core, and the intro's "Watch for
  new work" step), and the `automations_v2` run-history page. 2026-11-04.
- [x] Settings: Invite Member (accounts servers), Add Policy from the policy registry, Links and
  Sub-agents (in-app links, sub-agents beside the chat), Appearance › Chat defaults (hide
  unconfigured harnesses), Workspace (panel and first tab) and Code typography. 2026-11-04.
- [x] Host: after Back, the remote tab kept showing the old page (or a blank one) when many other
  tabs showed the same site. Windowless Chromium restored the page from the back/forward cache
  without painting it. The host now disables `BackForwardCache`; `browser-host/tools/back_test.py`
  covers it (25 leftover tabs: 3/5 stale before, 10/10 correct after). 2026-11-02.
