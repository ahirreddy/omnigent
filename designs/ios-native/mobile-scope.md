# Mobile journeys and proposed scope

Recommend a native app centered on connecting to an existing server, finding
sessions that need attention, reading and continuing conversations, answering
agent questions and approvals, and starting a session on an already configured
host. Keep basic attachments and read-only artifacts as separately sized
extensions. Defer terminals, editors, scheduling, and administration for the
first release. This is a recommendation for scope selection, not a commitment
to reproduce every feature inventoried below.

The user confirmed the mostly native direction, selective mobile functionality,
and this discovery process. The specific first-release inclusions and omissions
in this report are agent recommendations awaiting scope selection.

SwiftUI/UIKit should own navigation, connection state, session lists, transcript,
composer, and decision forms. Nothing in these proposed core journeys requires
the full web application to remain embedded. A terminal or rich HTML renderer
could become a bounded web-content exception if its mobile value justifies the
cost; neither is required by this recommendation.

Baseline: `76281b94`, source inspected on 2026-10-16. `S` below means
**source-only**: a path and related tests were inspected, but its behavior has
not been observed on an iPhone. `U` means runtime/deployment behavior is
**unknown**. No rows claim observed device behavior. Test names identify existing
coverage, not a passing test result from this audit. The coordinator's executed
checks and environment limits are in [validation-baseline.md](validation-baseline.md).
The CUJ documents informed the search; the code cited here determines current
behavior. See [native-shell.md](native-shell.md) for Swift lifecycle/bridge detail
and [server-contracts.md](server-contracts.md) for wire contracts.

## Routes and current mobile navigation

`web/src/App.tsx:81` is the route authority. A mounted deployment can prepend a
basename, so an API base and a web navigation base cannot be inferred from the
origin alone (`web/src/lib/host.ts:27`). Swift currently connects to this web
application; most mobile screens below are responsive React screens.

| Entry | Current behavior and prerequisite | Proposed native destination | Evidence |
| --- | --- | --- | --- |
| Native Connect / server switcher | Normalize a URL, expand a workspace URL, load it, remember successful connections. Swift owns this (`web/ios/Omnigent/ConnectView.swift:176`, `AppRootView.swift:20`). | Keep native setup and server switching; establish identity/capabilities before showing server data. | S; `web/ios/OmnigentTests/` and `OmnigentUITests/` coverage inventoried in native-shell report. |
| `/` | New-session landing screen; `ChatPage.tsx:1144` returns `NewChatLandingScreen`. | Simplified native creation form, reached from a primary Sessions list. | S; `NewChatDialog.flow.test.tsx`, `NewChatDialog.projectPrefill.test.tsx`. |
| `/c/:conversationId` | Chat plus workspace surfaces; the same `ChatPage` component follows the route into a module-scoped store (`App.tsx:47`). | Native session detail; preserve direct links to sessions outside the loaded list and to children. | S; `AppShell.subagent-nav.test.tsx`, `chatStore.test.ts`. |
| `/inbox` | Approvals plus unseen file comments across sessions (`InboxPage.tsx:1`). | Simplify to an Attention view for pending decisions; defer comments. | S; `InboxPage.test.tsx`, `lib/inbox.test.ts`. |
| `/approve/:sessionId/:elicitationId` | Standalone approval page outside AppShell (`App.tsx:118`). Fetches one elicitation and submits accept/decline. | Native decision intent, loading the full pending card from the session when needed. Current custom-scheme parser does not support this route. | S; `ApprovePage.test.tsx`; `web/ios/Omnigent/DeepLink.swift:100`. |
| `/tasks` | Scheduled tasks, filters, create/edit/pause/resume/delete (`TasksPage.tsx:41`). | Defer; explicit browser handoff. | S; `TasksPage.test.tsx`, `scheduledTasksApi.test.ts`. |
| `/settings` and `/settings/:section` | Account/appearance/git/shortcuts/archived plus gated admin or desktop sections (`SettingsPage.tsx:194`, `settingsNav.tsx:80`). | Native app/account settings and an Archived filter; browser handoff for server configuration. | S; `SettingsPage.test.tsx`, `settingsNav.test.tsx`. |
| `/members`, `/policies` | Redirect to the respective settings section (`App.tsx:138`). | Defer native administration; keep the original destination for handoff. | S; route source and `MembersPage.test.tsx`, `PoliciesPage.test.tsx`. |
| `/login`, `/register` | Registered only when accounts auth is enabled. OIDC uses a server login URL instead (`App.tsx:112`, `identity.ts:64`). | Keep login for supported deployments; defer registration UI to browser. Do not infer auth mode merely from an absent accounts flag. | S; `LoginPage.test.tsx`, `RegisterPage.test.tsx`, `identity.test.ts`; native credential transfer is U. |
| Any route while `needs_setup` | Accounts-enabled, zero-admin servers replace all routes with the setup form (`App.tsx:99`). | Explain that server setup is required and offer browser setup, then retry connection. | S; `SetupPage.test.tsx`. |
| Unmatched route | `NotFoundPage` via wildcard (`App.tsx:146`). | Explicit unsupported/invalid destination with back navigation; offer browser only for a valid known-server web URL. | S; route source; native equivalent U. |

At phone widths, the web sidebar is an overlay and the workspace rail becomes
full-screen drawers opened from the session menu. Rail surfaces are Files,
Agents, Shells, Todos, and a desktop-only Browser (`AppShell.tsx:96`, `:499`;
`railTabs.ts:8`). These are current entry points, not a proposed native tab bar.

## Feature inventory and disposition

Every recommendation is provisional. **Keep** preserves the user journey;
**simplify** retains a deliberately smaller interaction; **defer** leaves it out
of the first release while allowing later native work; **omit** identifies a
desktop-specific surface with no proposed mobile counterpart. Costs are relative
implementation risks, not estimates. `W` = web client, `N` = existing native
shell, `Svr` = server. Source and test paths in this table are under `web/src/`
unless a full path is shown. Unqualified Swift filenames refer to
`web/ios/Omnigent/`; shortened filenames after a qualified reference retain that
reference's directory.

| User action | Prerequisite → current result / owner | Source | Existing related tests | Status; proposal, rationale and cost |
| --- | --- | --- | --- | --- |
| Connect, revisit, or switch server | Reachable URL → saved connection and new web surface. N + W auth + Svr. | `web/ios/Omnigent/AppRootView.swift:20`; `ConnectView.swift:176`; `lib/identity.ts:64` | Native URL/settings/deep-link tests; `lib/identity.test.ts` | S; **keep**. Foundational; high risk for mount paths, login migration and isolation of per-server data. |
| Sign in/out; see current account | Server advertises auth → password form or OIDC redirect; identity from `/v1/me`. W + Svr. | `lib/identity.ts:64`; `pages/LoginPage.tsx:54`; `pages/SettingsPage.tsx:1621` | `pages/LoginPage.test.tsx`, `lib/identity.test.ts` | S/U native flow; **keep** for chosen deployment matrix. Account creation, invitations and password management can hand off to browser. |
| Find and monitor sessions | Authenticated visible sessions → cursor list, server search, status/host data, live updates with HTTP reconciliation. W + Svr. | `hooks/useConversations.ts:214`, `:266`; `hooks/SessionUpdatesProvider.tsx` | `hooks/useConversations.test.ts`, `hooks/SessionUpdatesProvider.test.tsx`; `tests/e2e_ui/sessions/test_sidebar_search.py` | S; **keep** native list/search/status. High risk: pagination, status convergence, server isolation and foreground refresh. |
| Organize sessions | Visible sessions/projects → pinned groups, project folders, archive/settings view, row and bulk actions. W + Svr. | `shell/sidebarNav.ts:175`; `shell/Sidebar.tsx:3402`, `:3740`; `hooks/useConversations.ts:311` | `shell/Sidebar.archive.test.tsx`, `Sidebar.rowActions.test.tsx`, `sidebarNav.test.ts` | S; **simplify** to reading project/pin labels and Archived filtering initially. Defer drag/drop, bulk actions, project creation and destructive cleanup; low mobile value for their extra state. |
| Open a long conversation | Read access → recent history plus older pages, streaming text, tools, reasoning, errors and attachments. W + Svr. | `store/chatStore.ts:2286`; `lib/sessionsApi.ts:243`; `components/blocks/BlockRenderer.tsx:496` | `store/chatStore.test.ts`, `pages/ChatPage.historyLoad.test.tsx`, `components/blocks/BlockRenderer.test.tsx` | S; **keep**, with native text/Markdown/code and expandable tool details. High risk: ordering, stale updates, memory and scroll anchoring. |
| Continue conversation; stop work | Editable, interactive session → optimistic send, consumption status, streaming response; stop posts interrupt. W + Svr. | `pages/ChatPage.tsx:1002`; `store/chatStore.ts:1157`, `:1493` | `store/chatStore.test.ts`; `tests/e2e_ui/mobile/test_mobile_workflow.py:289` | S; **keep**. Distinguish draft, sending, accepted and failed; never confuse disconnect with stopped execution. |
| Compose while a turn runs | Active session → local per-session FIFO, cancel/steer/reorder; page activity drains the queue. W + Svr only after POST. | `store/chatStore.ts:940`, `:1017`, `:1043`; `pages/QueuedMessagesStrip.tsx` | `pages/QueuedMessagesStrip.test.tsx`, `store/chatStore.test.ts` | S; **simplify** to a visibly device-held queue and cancel; defer reorder/advanced steering. High risk if advertised as background delivery: current queue is in memory and unposted messages are not server-owned. |
| Preserve composer text | Navigate away → module-scoped per-session drafts restored within the page lifetime. W. | `pages/ChatPage.tsx:3932` | `pages/ChatPage.composer.test.tsx` | S; **keep** per-server/session drafts. Native restart persistence is a proposed improvement, not existing behavior; do not silently auto-send a restored draft. |
| Approve a tool or reject a plan | Edit access, pending prompt → binary decision, command details, plan Markdown and optional rejection feedback. W + Svr. | `components/blocks/ApprovalCard.tsx:161`, `:218`; `store/chatStore.ts:1653` | `components/blocks/ApprovalCard.test.tsx`, `pages/ApprovePage.test.tsx` | S; **keep** native structured cards. High risk: actual target session, stale decisions, rollback and schema fidelity. |
| Answer agent questions | Structured pending payload → single/multiple choice, custom text, option previews, all-question validation. W + Svr. | `components/blocks/AskUserQuestionForm.tsx:62`, `:178`; `ApprovalCard.tsx:189` | `components/blocks/ApprovalCard.test.tsx:435`; `tests/e2e_ui/approvals/test_ask_user_question.py` | S; **keep** native form; question IDs and array/string answer shapes are contract requirements. |
| Approve and change future permissions | Prompt advertises a specific extension → remember a rule, allow edits, auto-mode, or Codex exec-policy amendment. W + Svr. | `components/blocks/ApprovalCard.tsx:197`, `:287`, `:317` | `components/blocks/ApprovalCard.test.tsx:75`, `:111`, `:211`, `:1013` | S; **defer** these additional choices initially. Plain accept/decline remains; show existing grants accurately without changing them. |
| Find pending decisions across sessions | Session list rows advertise prompts → drain pages and fetch relevant snapshots; mirrored prompts deduplicated. W + Svr. | `pages/InboxPage.tsx:67`; `lib/inbox.ts:46` | `pages/InboxPage.test.tsx`, `lib/inbox.test.ts`; `tests/e2e_ui/approvals/test_inbox_approval.py` | S; **simplify** to Attention, without file comments. High mobile value; scale/correctness cost because there is no single aggregate call in this web implementation. |
| Start a basic session | Existing ready agent/harness, connected host and absolute workspace, nonblank prompt → session created then first message sent. W + Svr. | `shell/NewChatDialog.tsx:2785`, `:2912`, `:3079`; `pages/ChatPage.tsx:5170` | `shell/NewChatDialog.flow.test.tsx`, `NewChatDialog.test.tsx`; `tests/e2e_ui/start_session/test_start_session.py` | S; **simplify** native form with recent host/workspace and configured agents. Medium/high cost: two-phase create/send and startup failures. |
| Configure a new execution environment | Capability/credentials → managed sandbox/repo branch, worktree, custom agent bundle, harness install and launch overrides. W + Svr + host. | `shell/NewChatDialog.tsx:2934`, `:2969`, `:3001`; `lib/capabilities.ts:107` | `shell/NewChatDialog.projectPrefill.test.tsx`; `tests/e2e_ui/start_session/test_harness_install.py`, `test_create_custom_agent.py` | S; **defer** creation/configuration UI. Existing managed sessions remain readable/wakeable under core chat; selection of a supported ready host is separate from provisioning one. |
| Inspect/change model or execution knobs | Harness-specific labels/catalog → model/effort, plan/goal/cost controls. W + Svr/vendor. | `pages/ChatPage.tsx:1075`, `:5311`, `:5855`; `shell/NewChatDialog.tsx:1350` | `pages/modelPicker.test.ts`, `effortLevels.test.ts`, `ChatPage.capabilities.test.ts`, `ChatPage.composer.test.tsx` | S; **simplify** to current agent/model/status display and defaults for create. Defer most mutations; do not apply inherited web sticky preferences on native session open. |
| Use skills, slash commands, workspace mentions, dictation | Harness/browser/server capabilities → structured skill event or vendor plaintext, workspace path markers, speech capture. W + Svr/vendor. | `pages/ChatPage.tsx:3965`, `:4420`; `lib/capabilities.ts:121` | `pages/ChatPage.composer.test.tsx`, `ChatPage.mention.test.tsx` | S; **defer** custom menus and server dictation. Native keyboard dictation works as text input. Preserve special command semantics or explain unsupported commands; never unknowingly inject a terminal-only interactive command. |
| Attach a screenshot or document | Upload store + supported image/PDF/text → multipart upload then file reference in message. W + Svr. | `lib/filesApi.ts:10`; `lib/attachments.ts:13`; `store/chatStore.ts:704` | `lib/attachments.test.ts`, `store/chatStore.test.ts:2814`; `tests/e2e_ui/chat/test_composer_attachments.py` | S; **simplify**, proposed separately sized retained extension: Photos/document picker and removable chips. Medium cost; two-phase retry and MIME handling. No filesystem editor dependency. |
| Read/download an attachment or linked file | File read access; workspace files additionally require a serveable host/runner → text/base64 content and viewer. W + Svr/host. | `hooks/useFileContent.ts:28`, `:116`; `shell/FileViewer.tsx:371`, `:496` | `hooks/useFileContent.test.tsx`, `shell/FileViewer.test.tsx`, `CodeViewer.test.tsx`; mobile file test `test_mobile_workflow.py:241` | S; **simplify**, proposed retained extension: linked-file text/Markdown/image/PDF preview and share/download. Medium cost; show truncation, unavailable host and unsupported type clearly. |
| Browse every workspace file; inspect diffs | Environment available → Changed/All, file tree/search/sort and diff viewer. W + Svr/host. | `shell/FilesPanel.tsx:19`; `shell/FileViewer.tsx:622`, `:707`; `shell/AppShell.tsx:491` | `shell/FilesPanel.test.tsx`, `FolderTree.test.tsx`, `MonacoDiffViewer.test.tsx` | S; **defer** full browser/diffs. A linked artifact preview should not grow into a workspace IDE. |
| Edit code/Markdown or view executable HTML/notebooks | File writable/readable → Monaco, TipTap, rich previews and autosave. W + Svr/host. | `shell/FileViewer.tsx:692`, `:802`, `:862`; `shell/MonacoCodeEditor.tsx`; `shell/MarkdownRichTextViewer.tsx` | `shell/MonacoCodeEditor.autosave.test.tsx`, `MarkdownRichTextViewer.integration.test.tsx`, `HtmlCommentViewer.test.tsx`, `NotebookPreview.test.tsx` | S; **defer** editor and rich HTML/notebook preview. HTML can be downloaded or handed off; optional isolated renderer is a later decision. High cost. |
| Open agent terminal / create shells | Live terminal and appropriate permissions → xterm + binary WebSocket, resize/input/reconnect; Shells can create a shell before one exists. W + Svr/host; N selector. | `shell/TerminalFirstContext.tsx:15`; `shell/MainTerminalView.tsx:50`; `components/blocks/TerminalSession.ts:300`; `shell/AppShell.tsx:430` | `components/blocks/TerminalSession.test.ts`, `shell/MainTerminalView.test.tsx`, `NewTerminalButton.test.tsx`; mobile shell test `test_mobile_workflow.py:185` | S; **defer** terminal and shell creation. High touch/keyboard/transport cost; evaluate terminal exception independently. Terminal-first presentation does not automatically make chat unusable. |
| Inspect child agents and progress | Session tree exists → nested list/graph, back-to-parent, child chat; some children read-only. W + Svr. | `shell/SubagentsPanel.tsx:110`; `shell/AppShell.tsx:437`; `pages/ChatPage.tsx:5280` | `shell/SubagentsPanel.test.tsx`, `AppShell.subagent-nav.test.tsx`; mobile agents test `test_mobile_workflow.py:212` | S; **simplify** to child status list and ordinary detail navigation. Required to understand mirrored decisions; defer graph, add/switch-agent/fork orchestration. Medium cost. |
| Read agent Todos versus scheduled Tasks | Supported Claude/Codex state → read-only progress list; separate Tasks route manages recurring execution. W + Svr. | `shell/AppShell.tsx:347`, `:522`; `shell/TodoPanel.tsx`; `pages/TasksPage.tsx:41` | `shell/TodoPanel.test.tsx`, `pages/TasksPage.test.tsx`, `components/scheduled/CreateScheduledTaskDialog.test.tsx` | S; **simplify** inline progress summary; **defer** schedule CRUD and RRULE/timezone UI. Do not merge these distinct concepts. |
| Read or contribute to an already shared session | Server grants → author attribution, read/edit differences, live multi-user updates. W + Svr. | `lib/permissionsApi.ts:34`; `pages/ChatPage.tsx:1064`, `:3892`; `shell/AppShell.tsx:376` | `hooks/usePermissions.test.tsx`, `lib/permissionsApi.test.ts`; `tests/e2e_ui/collaboration/test_permissions_modal.py` | S; **keep** permission-aware reading/conversation/decisions; **simplify** collaboration chrome. Grants still apply when share-management UI is deferred. |
| Grant sharing, fork, comment and send file feedback | Ownership/grants and server sharing caps → permissions, clone/resume flow, anchored comments and comment inbox. W + Svr/host. | `shell/AppShell.tsx:376`, `:402`; `pages/InboxPage.tsx:25`; `shell/FileViewer.tsx:389`; `shell/ForkSessionDialog.tsx` | `pages/SharingPage.test.tsx`, `shell/ForkSessionDialog.test.tsx`, `CommentsPanel.test.tsx` | S; **defer** management/fork/comments UI. Keep received session links and existing access; copy/share of an existing URL must not imply granting access. |
| Inspect usage, policy/tool info and debug logs | Session/agent metadata → cost/model summary, agent tools/policies, execution logs. W + Svr. | `pages/ChatPage.tsx:1139`, `:5855`; `shell/AppShell.tsx:407`; `shell/ExecutionLogsPanel.tsx` | `pages/ChatPage.statusLine.test.tsx`, `shell/ExecutionLogsPanel.test.tsx` | S; **simplify** to compact execution/usage information and meaningful errors; **defer** configuration/debug panels. Retain tool names/outputs needed to understand decisions. |
| Change app appearance and local preferences | Local web preferences → theme, font, code font, terminal theme, workspace defaults. W/local storage. | `pages/SettingsPage.tsx:813`; `shell/settingsNav.tsx:86` | `pages/SettingsPage.test.tsx`, `shell/settingsNav.test.tsx` | S; **simplify** to system/light/dark, Dynamic Type and native notification settings. Omit web font/rail/terminal customization if the related surface is absent. |
| Administer members/policies/git credentials | Admin/server capability → settings subpages; accounts/OIDC differ. W + Svr. | `shell/settingsNav.tsx:109`; `pages/SettingsPage.tsx:208`, `:861` | `pages/MembersPage.test.tsx`, `PoliciesPage.test.tsx`, `SharingPage.test.tsx` | S; **defer** native administration; browser links preserve section and deployment. |
| Use desktop browser/local CLI/updater/command palette | Electron or desktop keyboard → desktop integration and shortcuts. W + desktop shell. | `shell/AppShell.tsx:503`; `shell/settingsNav.tsx:97`; `pages/SettingsPage.tsx:229`; `shell/CommandPalette.tsx` | `shell/CommandPalette.test.tsx`, `shell/settingsNav.test.tsx` | S; **omit** desktop integrations on iOS. Browser tab is already capability-hidden; native search supplies the useful navigation subset. |
| Receive notifications and open links | Active live web page → native local notification/badge and routing bridge. N + W. | `web/ios/Omnigent/AppRootView.swift:147`; full path map in `native-shell.md` | Native deep-link tests; `lib/nativeBridge.test.ts`; `tests/e2e_ui/sessions/test_idle_notifications.py` | S/U device delivery; **keep** foreground behavior/deep links, **defer** a claim of background push until server/APNs scope is decided. High reliability risk. |

## Core journey traces and acceptance criteria

### 1. Connect, authenticate, and choose a server

Current path: `ConnectView.connect` normalizes and expands the URL, then
`AppRootView` loads the server page and remembers successful connections. Web
probes `/v1/info` for mode/capabilities and `/v1/me` for identity. Accounts login
uses the form; OIDC uses the server's login URL. In embedded deployments,
`hostFetch` delegates to an injected host transport and does not perform the
standalone 401 redirect (`identity.ts:168`, `host.ts:136`). This injected
JavaScript behavior is a dependency to replace, not native authentication.

Proposed native behavior: native saved-server screen, connection progress,
account identity and retry; an OS authentication session or explicitly bounded
login surface when required by the selected deployment. Browser authentication
does not by itself establish credentials in a native URLSession. The server
contract report must settle that transfer and any device-grant eligibility.

Acceptance criteria:

1. Each selected supported deployment resolves the correct web/API/stream
   bases, including workspace mounts if selected for release. Unsupported
   deployment/auth combinations give an actionable explanation; failed discovery is distinguishable from a
   confirmed capability-off response.
2. Server A's identity, conversations, drafts, queue and callbacks never appear
   under server B. Canceling login leaves the original server usable.
3. Expired authentication preserves the intended session/approval destination
   and unsent draft, then resumes after successful login. A 403 is presented as
   lack of access, not a login loop.
4. Existing saved connection settings migrate or produce an explicit reconnect
   flow; saved web cookies are not assumed available to the new native client.
5. Server setup/registration links open their exact browser destination and
   returning to the app allows a fresh capabilities/identity check.

### 2. Find a session and identify what needs attention

Current path: `useConversations` requests `GET /v1/sessions` with `limit=30`,
`sort_by=updated_at`, descending order, optional search/archive/project filters,
and `after` cursors (`useConversations.ts:214`). The nearby prose says 20, but the
executed request sets 30. `SessionUpdatesProvider` patches loaded rows; connected
list reconciliation and disconnected polling find missed/new sessions
(`useConversations.ts:272`). Do not replace the server search with a filter of
the first page.

Attention is more than filtering a currently loaded list. `InboxPage.tsx:77`
drains remaining pages, filters nonarchived rows with pending counts, fetches
each relevant session, and suppresses a false empty state while assembling or
failing. `inbox.ts:46` deduplicates mirrored prompts and retains the actual
resolve-session ID. The initial native Attention view should reuse those
semantics or obtain an aggregate server contract; the current request fan-out
may be costly for large accounts.

Acceptance criteria:

1. With at least 65 sessions, paging and server search find a session outside
   the initial page. An approval in that session appears in Attention.
2. Loading, no sessions, no search results, partial Attention failure, stale
   offline content, and no pending decisions remain distinct states.
3. A session created or changed on another client converges into the native
   list. Resume from background refreshes authoritative state before declaring
   no work pending. Background network execution is not assumed.
4. Opening a direct session or child URL works without a matching loaded row.
   Deleted/inaccessible IDs provide a recoverable detail state.
5. Status differentiates working, needs input, idle/background activity,
   connecting and unreachable. `waiting` is not universally equivalent to
   actively running or awaiting approval (`chatStore.ts:1017`).
6. Archive filtering and project/pin labels preserve visibility of existing
   organization without requiring the web sidebar layout or its edit tools.

### 3. Read, send, interrupt, and recover a conversation

Current path: route change calls `chatStore.switchTo`; it aborts the previous
stream and stashes this client's unsettled optimistic messages
(`chatStore.ts:1540`). Bind starts the stream request, concurrently fetches fresh
session metadata plus the recent history window, then merges by item identity
(`:2286`). It must not wait indefinitely for SSE response headers before showing
history or a pending decision. Older history pages use their own generation
guards (`:1825`); reconnect reconciles committed history, pending prompts and
status (`:2954`). `itemsToBlocks` / `blockStream` / `BlockRenderer` are behavior
references, not a requirement to copy React rendering internals.

Sending pins work to its original session, creates an optimistic message,
uploads optional attachments, then posts a message event. Native-wrapper
messages can remain pending until consumed. A new local draft, a device-held
queue entry, an HTTP request awaiting a response, and a server-accepted pending
input are four distinct states. The existing queue lives in the store
(`chatStore.ts:899`, `:940`); switching chats is not the same as iOS suspending
the app.

The composer blocks while a prompt addressed to this session is pending, since
text could otherwise reach the vendor permission UI; a mirrored child prompt
does not necessarily block its parent (`ChatPage.tsx:3897`). Read permissions
and structural read-only states also matter: closed children and Claude native
subagents cannot receive ordinary input (`:5280`). Existing stopped/offline
sessions may be wakeable: `useSessionLiveness.ts:113` distinguishes sleeping
runner, resumable managed host, offline host and unbound local session.

Acceptance criteria:

1. Open an empty, long, completed and mid-stream conversation. Render text,
   code/Markdown, tool status and errors natively; unknown content remains
   inspectable or gets an explicit unsupported-content fallback. Decisions
   must never disappear into that fallback.
2. Paging older items preserves the visible reading position. Live updates do
   not force-scroll a user reading earlier content; returning to the latest
   response is a native action.
3. A→B→A switching during send/history/stream work never delivers A's text or
   callbacks to B, loses an unsettled send, or duplicates a committed message.
   Retrying after an ambiguous request result first reconciles server state;
   the current event contract does not promise an idempotency key.
4. Disconnect during a turn, let the server finish, then reconnect. History,
   final status, pending inputs and decisions converge without duplicates or
   a permanently working indicator. Repeat with a decision resolved elsewhere.
5. Sending to a sleeping runner or resumable host shows startup progress;
   nonresumable offline/unbound sessions show recovery guidance with browser
   handoff if required. Drafts survive these failures.
6. Queue entries are clearly marked as held on this device and cancelable;
   no background delivery promise is made. Reopening restores drafts/any
   intentionally persisted queue and reconciles status before a send decision.
   Advanced queue reorder and multi-session scheduling are deferred.
7. Stop sends the actual interrupt, keeps the stream able to observe server
   state, and distinguishes a request from confirmation. A failed interrupt
   must not falsely tell the user execution stopped. Existing `stop()` sets
   idle optimistically and swallows its network error (`chatStore.ts:1493`);
   this is a source-derived limitation, not a demonstrated device failure.
8. Native input supports paste, selection, multiline/IME entry, Dynamic Type
   and VoiceOver. The keyboard appears on explicit focus; changing sessions
   does not force it open (`ChatPage.tsx:3992`).

### 4. Answer a pending approval or question

Current path: live or snapshot elicitation → `ApprovalCard` → native-equivalent
binary/plan/question/command form → `submitApproval` → resolve POST against
`targetSessionId` or the current session. Failure restores pending state
(`chatStore.ts:1653`). The card supports external URL requests separately
(`ApprovalCard.tsx:244`).

Structured answers are a **flat** `content` map keyed by question ID, falling
back to question text, with string or string-array values
(`AskUserQuestionForm.tsx:81`, `:178`; `ApprovalCard.tsx:189`). The introductory
comment describing `content.answers` is stale; do not implement it. Plan
rejection can carry `content.feedback`. Full structured prompt fields come from
session snapshots/SSE; the standalone individual-elicitation GET used by
`ApprovePage.tsx:26` only models status/message/phase/policy/preview.

Acceptance criteria:

1. Binary approval, Codex command details, plan accept/reject with optional
   feedback, enum choice, single-select, multi-select and custom-text questions
   each retain their meaning in native controls. Every required question is
   answered before submit; option previews remain available.
2. A prompt opened from Attention, a conversation, a child mirror or a deep link
   resolves the same actual target once. Standalone links load the full session
   prompt when the individual GET lacks its form schema.
3. A network failure leaves an actionable pending/error state; a prompt
   resolved, canceled or timed out elsewhere becomes non-actionable after
   reconciliation. Unknown schemas do not get a misleading binary approval.
4. The sender's effective edit permission gates decisions; shared read-only
   viewers may inspect the card. The native UI does not equate all approval
   actions with owner-only operations.
5. Deferred persistent-grant/auto-mode choices are simply absent. A normal
   approve action never silently changes future permission policy. Existing
   decision results still describe any policy changes made elsewhere.
6. External authorization URLs open as external authentication/content; merely
   returning to the app does not synthesize acceptance. Refresh pending state.

### 5. Start a basic session

Current path: landing screen discovers hosts and agent choices, restores
preferences, validates a nonblank message and valid host/workspace, then POSTs
`agent_id`, `host_id`, `workspace` and any required wrapper labels. Native CLI
wrapper identity is separate from terminal-first presentation. Advanced
launch/model/worktree fields are omitted when defaults apply
(`NewChatDialog.tsx:2785`, `:2964`). Custom bundles instead require a separate
runner-launch operation (`:2934`); exclude that from basic create.

Creation is not the first message. After a session ID exists, the web stores
the pending initial prompt, navigates, waits for hydration/binding/agent
identity, then dispatches it to that exact session
(`NewChatDialog.tsx:3079`; `ChatPage.tsx:5170`, `:5220`). Project filing is a
separate nonfatal operation (`NewChatDialog.tsx:3038`).

Acceptance criteria:

1. Pick a previously configured ready agent, reachable host and known valid
   workspace; see those choices before sending. With no host, explain how to
   configure one on a computer; the phone need not install a CLI or harness.
2. A plain prompt creates one session and one first message in it. Do not
   require a terminal renderer merely because the session's presentation label
   says `omnigent.ui=terminal` (`TerminalFirstContext.tsx:15`).
3. Create failure preserves inputs. If create succeeds but the first send
   fails, recover inside the created session instead of automatically creating
   a second one. Switching views or backgrounding during startup cannot send
   the initial message to the wrong session.
4. Only the explicitly supported harness matrix is offered for creation.
   Existing other sessions remain readable when their items are understood,
   with unsupported interaction guidance. Verify terminal-only vendor prompts
   before promising full chat control for every native wrapper.
5. Default server/harness configuration remains authoritative. Opening an
   existing session does not mutate model, effort, routing, workspace or
   permissions from unrelated saved preferences.

## Retained extensions and narrow rendering options

Basic attachments and artifact inspection deserve separate sizing because they
are useful from a phone without introducing editing or terminal dependencies.

| Extension | Proposed acceptance boundary | Remaining evidence |
| --- | --- | --- |
| Photo/document import | Photos or document picker; removable filename/preview chips; current server categories image/PDF/text-code, limits 5/20/10 MiB. Preserve a successful uploaded file ID if message POST fails; handle unsupported/oversized/store-unavailable responses. | Source: `filesApi.ts:10`, `attachments.ts:13`, `chatStore.ts:704`. Actual photo MIME/HEIC compatibility and picker behavior require a device/deployment check; do not assume all `image/*` inputs are consumable by every harness. |
| Attachment download | Fetch authenticated bytes, preview through native image/PDF/text facilities, and use the share sheet for export. Server attachment download is distinct from a workspace read. | Contract agent confirms `/resources/files/{file_id}/content`; verify each selected auth transport and no credential loss on redirects. |
| Linked workspace artifact | Preserve session and path; fetch environment file content, decode text/base64, show a read-only preview and explicit truncated/unavailable state. Never label truncated bytes as a complete download. | `useFileContent.ts:18`, `:94`, `:123`; actual host fallback and large binary limits need deployment tests. |
| Child progress | Native related-session list with status and back-to-parent, native Todo summary if supplied. Read-only rules and target IDs survive navigation. No graph/editor/add-agent workflow required. | `SubagentsPanel.tsx:110`; `ChatPage.tsx:5280`; verify parent/child grants and status propagation. |
| Minimal preferences | System/light/dark, system text scaling, saved servers/account and notification preferences. Leave unrelated web preferences unchanged; migrate only selected mobile preferences. Theme and panel preferences currently use browser storage. | Native settings migration and accessibility require Mac/device validation. |

| Potential web-rendering exception | User value / native alternative | Recommendation and integration limit |
| --- | --- | --- |
| Existing agent terminal | Recover vendor-only interactions or inspect a running TUI. A native terminal emulator is the alternative, with its own input/rendering work. | **Defer** pending real-session evidence. If retained, one terminal renderer under native navigation; native session identity, connection/lifecycle, errors and permission state. Existing xterm protocol/input tests are useful but no ready isolated iOS terminal package was demonstrated. |
| HTML artifact | View an agent-produced interactive page. Native text/Markdown, image/PDF preview or browser handoff covers many outputs more cheaply. | **Defer** rich rendering. If approved later, a content-only isolated renderer with explicit link/download behavior, no whole-app navigation, and no reuse of the broad application bridge. Cost includes local asset resolution and scripts, not just drawing HTML. |
| Login page | Some deployments require a browser-mediated identity provider. OS browser authentication is the first native-platform option. | Treat as connection infrastructure, not a reason to embed the application. Credential transfer/callback contracts must be proven before choosing a login surface. |

## Links into deferred or omitted features

Native link routing should decode a destination without assuming every valid
web destination is a supported native screen. Preserve the original server,
mount prefix, path and query through login and handoff. Current native custom
links cover `/c/<id>`; the approval intent and capability-aware handling below
are proposed work, not existing behavior.

| Destination | Proposed behavior |
| --- | --- |
| `/c/:id` | Open native detail, regardless of loaded list membership; apply read-only and child rules. |
| `/approve/:sid/:eid` | Open native decision detail; obtain full pending form from the owning session or show resolved/unavailable. |
| `/c/:id?file=…` | Open the supported read-only artifact view when included in scope; otherwise explain “File view is available in the browser” and offer the original URL. |
| File link with `comment=…`, `diff=1` or unsupported rich view | Explain the specific missing comment/diff/rich view and offer browser; optionally let the user open the basic file separately. Do not silently drop those parameters and imply the requested view opened. |
| Terminal-related view/action | Explain that terminal access is available in browser/desktop and offer the current server's session URL. Do not display a disabled unexplained Chat/Terminal control throughout the app. |
| `/tasks`, admin settings, members/policies redirects, registration/setup | Small native handoff screen with context, browser action and back. Hide them from primary native navigation. |
| External URL inside a message or elicitation | OS external/authentication presentation; preserve the originating session when returning. An external authorization request is not resolved merely by opening its URL. |
| Unknown route/server | Unsupported destination or existing unknown-server trust flow; never silently switch to another saved server. Keep a way back. |

If browser handoff reopens the native app through link interception, supply a
browser-specific open path/presentation so it cannot loop. A local server may
be unreachable from another device, and browser credentials may differ from the
native client's credentials; preserve the URL and explain that state rather
than claiming handoff succeeded.

## Dependencies and decisions before implementation

| Dependency / question | Implication and next evidence |
| --- | --- |
| Deployment/auth matrix | Both standalone and workspace deployments are being assessed; their supported modes are not yet established. Contract and native owners must demonstrate native HTTP/SSE/socket login on each selected mode, including expiry and base paths. |
| Harness matrix without terminal | “Native wrapper” means a vendor CLI runner, not an iOS-native screen. Plain chat may work while a vendor-only command requires its terminal. Exercise start, send, interrupt and question flows for each chosen harness; unsupported ones need explicit handoff. |
| Device-held queue versus server acceptance | The current queue and drafts are browser-memory state. Decide persisted native draft/queue behavior and visible foreground limits. A reliable background queue or exactly-once retry may require server work; do not advertise it from the current contract. |
| Attention scale/completeness | Existing implementation pages the entire list and fetches relevant snapshots. Measure a large account; decide whether an aggregate endpoint is needed. Archived pending sessions are currently excluded; confirm whether mobile Attention should preserve that product rule. |
| Permission/capability authority | Keep edit/read behavior even if sharing management is deferred. Server remains authoritative; absent metadata and unsupported content must not produce misleading active controls. |
| App suspension and notifications | Existing notifications depend on a live page; no APNs guarantee. Measure foreground refresh and cold-link behavior first; push requires separate server/device work. |
| Stored state migration | Saved servers are Swift state; web auth cookies and local preferences live elsewhere. Migrate required connection identity/drafts deliberately; do not inherit the web's model/effort auto-application on bind (`chatStore.ts:2356`). |
| Artifact scope | Approve basic image/PDF/text input and linked read-only previews separately from full Files. HTML/notebook execution, editing, comments and diffs stay deferred unless a demonstrated mobile journey needs them. |
| Runtime baseline gaps | No iOS simulator/device evidence was gathered by this audit. Keyboard, accessibility, performance, suspension, SSO and screenshot baselines remain U; see the validation report for owners/checks. |

Source findings that should not be copied as requirements: `stop()` can show
idle after a failed interrupt; question documentation mentions a stale nested
answer shape; pagination prose disagrees with its actual limit; the mobile test
fixture comment says Agents requires a child while current `AppShell.tsx:509`
makes the tab unconditional. Treat these as evidence of why source and runtime
checks must accompany descriptions. None establishes a reproduced iOS bug.

## How to verify this audit and the retained journeys

Run the focused web suites from the repository root after the contributor
dependencies are installed. These verify behavior references, not native UI:

```sh
npm --prefix web test -- src/hooks/useConversations.test.ts \
  src/hooks/SessionUpdatesProvider.test.tsx src/store/chatStore.test.ts \
  src/pages/ChatPage.historyLoad.test.tsx src/pages/ChatPage.composer.test.tsx \
  src/components/blocks/ApprovalCard.test.tsx src/pages/ApprovePage.test.tsx \
  src/pages/InboxPage.test.tsx src/lib/inbox.test.ts \
  src/shell/NewChatDialog.flow.test.tsx src/lib/attachments.test.ts
```

The responsive mobile suite uses Chromium at 390×844, a local test server and
deterministic fixtures; its send test uses the mock LLM and permits two flaky
reruns (`tests/e2e_ui/mobile/test_mobile_workflow.py:1`, `:282`). It is not an
iPhone or WKWebView test. Its self-contained invocation, after installing the
e2e dependencies, is:

```sh
uv sync --extra all --extra dev --extra e2e-ui
uv run playwright install --with-deps chromium
uv run pytest tests/e2e_ui/mobile/test_mobile_workflow.py
```

For a device baseline, follow [validation-baseline.md](validation-baseline.md)
and the existing app's Mac build instructions. Record exact app/server revision,
device/OS, deployment/auth mode and selected harness. Use a controlled test
server with an existing host and these inputs:

1. At least 65 sessions, one archived session, one shared read-only session, a
   parent with a child, and one pending decision beyond the initial list page.
   Search, page, open Attention and follow a direct child URL.
2. An empty transcript, a multi-page transcript and a running response. Send
   “Reply with mobile-pong”, switch away/back before it settles, interrupt a
   later turn, disconnect/reconnect and background/foreground the app.
3. Pending binary, plan, single-choice, multi-choice/custom-answer and child
   prompts seeded through the existing approval test fixtures. Resolve one
   elsewhere before returning; fail one resolve request and verify recovery.
4. Create a session on a configured host/workspace with one plain initial
   message. Repeat with host offline and with send failure after create.
5. A small image, PDF and text attachment, an unsupported file, and one beyond
   each configured size limit. Open a linked text/image/PDF artifact, then a
   comment/diff/HTML link, recording the exact supported or handoff behavior.

Capture video/screenshots of the core journeys, plus keyboard, Dynamic Type and
VoiceOver behavior. Record failures separately from scope proposals. The
first implementation slice should prove connect/auth → paginated list → native
streaming detail → one structured decision before expanding the retained set.
