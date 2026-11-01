**Omnigent’s visual direction is working. The biggest improvement remains clearer hierarchy: what the agent is doing, what needs my decision, and what is ready to review.** The pink accent, purple-black canvas, restrained mascot, and plain assistant prose give it a recognizable identity.

The verified research changes the product priorities more than the visual critique. **Phone approvals, focused code review, remote steering, and useful notifications belong in the core experience.** Omnigent’s opportunity is to make these workflows consistent across agents and execution environments.

This revision uses the ten supplied screenshots, the [design spec](../web-ui-spec.md), the [existing polish review](../ui-polish-review.md), relevant shared components, and your supplied competitor research. Competitor facts are attributed to that research and its sources; I have not independently reopened the external pages in this pass. No code was changed or tests run.

**1. Competitor findings**

The behavior column below reports supported findings. The recommendations that follow are my judgment about their relevance to Omnigent.

| Product | Platform | Verified behavior relevant to Omnigent | Source |
|---|---|---|---|
| **Codex app: workspaces** | Mac | Threads are grouped by project. A composer Worktree toggle gives a chat an isolated worktree; Hand off moves between Local and Worktree. The documented retention policy keeps 15 recent worktrees and snapshots them before deletion. | [App introduction](https://openai.com/index/introducing-the-codex-app/), [Worktrees](https://learn.chatgpt.com/docs/environments/git-worktrees) |
| **Codex app: review** | Mac | Review scopes include Unstaged, Staged, Commit, Branch, and **Last turn**. Files and hunks can be staged or reverted. Inline “+” comments reach the agent only after a message is sent. | [Code review](https://learn.chatgpt.com/docs/code-review) |
| **Codex app: long-running work and attention** | Mac | A `/goal` row supports pause, resume, edit, and clear. Side chat can request a recap without interrupting. Activity exposes unread, running, and waiting chats; notification controls distinguish completion, permissions, and questions. The optional status companion prioritizes Needs input. | [Long-running work](https://learn.chatgpt.com/docs/long-running-work), [Notifications](https://learn.chatgpt.com/docs/notifications), [Status companion](https://learn.chatgpt.com/docs/pets) |
| **Codex app: approvals and terminal** | Mac | Sandbox scope and approval policy are separate. Auto-review has Reviewing, Approved, Denied, and Timed out states. Each chat has a terminal tied to its worktree; the agent can read its output, and saved commands become shortcuts. | [Approvals](https://learn.chatgpt.com/docs/agent-approvals-security), [Terminal](https://learn.chatgpt.com/docs/integrated-terminal) |
| **Codex Remote** | iPhone + Mac | Tasks / Approve / Review / New task navigation; host filters; command-bearing approval cards with approval, denial, and redirection choices; changed-file summaries leading into diffs. Mac pairing uses a QR code, and remote access depends on the Mac remaining awake. | [Mobile](https://learn.chatgpt.com/docs/mobile), [Remote connections](https://learn.chatgpt.com/docs/remote-connections) |
| **Codex Computer Use** | Mac | A visible virtual cursor exposes agent activity without stealing foreground focus. Permissions can be granted per app. | [Computer Use](https://learn.chatgpt.com/docs/computer-use), [MacStories evaluation](https://www.macstories.net/notes/openais-new-codex-app-has-the-best-computer-use-feature-ive-ever-tested/) |
| **ChatGPT** | Mac, iPhone | Mac has an ⌥Space Chat Bar and a Work with Apps banner identifying included apps and content. On iPhone, voice uses a Live Activity; long-pressing Send offers a model choice for one message. | [Chat Bar](https://help.openai.com/en/articles/9295241-accessing-the-launcher-chatgpt-macos-app), [Work with Apps](https://help.openai.com/en/articles/10119604-work-with-apps-on-macos), [Release notes](https://help.openai.com/en/articles/6825453-chatgpt-release-notes) |
| **Claude Code desktop** | Mac | Environment, folder, permission mode, and model are available before first send. Permission mode is remembered per folder. Diff comments are explicitly submitted together with ⌘↵. Changes, Browser, Terminal, Files, Plan, and Background tasks can occupy movable panes. | [Desktop](https://code.claude.com/docs/en/desktop) |
| **Claude Code: permissions and input** | Mac / CLI | Manual, Accept edits, Plan, Auto, and Bypass are distinct modes. Auto uses a classifier and can pause after repeated blocks. Enter while working queues; Esc interrupts while retaining completed work; Ctrl+Enter sends queued messages immediately. | [Permission modes](https://code.claude.com/docs/en/permission-modes), [Interactive mode](https://code.claude.com/docs/en/interactive-mode) |
| **Claude Code agent view** | CLI | Groups include Pinned, Ready for review, Needs input, Working, and Completed. A peek panel shows the exact question and waiting time. Permission prompts still require attaching to the session before answering. | [Agent view](https://code.claude.com/docs/en/agent-view) |
| **Claude remote control** | iPhone | Mobile controls a session running on a computer, with host indicators and separate push preferences. Forwarded dialogs expire after five minutes; biometric step-up applies after 18 hours. Bypass cannot be enabled from the phone. | [Remote control](https://code.claude.com/docs/en/remote-control), [Mobile](https://code.claude.com/docs/en/mobile) |
| **Claude browser and quick entry** | Mac / browser | Quick Entry opens a prompt and recent chats. Browser tabs are grouped per session; site permissions can last for a session. Login and CAPTCHA steps pause for the human. | [Quick Entry](https://support.claude.com/en/articles/12626668-use-quick-entry-with-claude-desktop-on-mac), [Chrome](https://code.claude.com/docs/en/chrome) |
| **Conductor** | Mac | Tasks have associated workspaces, terminals, diffs, and review. The diff viewer supports commit filtering, inline comments, and GitHub thread resolution. Suggested actions include creating a PR, fixing checks, and merging when ready. | [Diff viewer](https://conductor.build/docs/reference/diff-viewer), [Changelog](https://conductor.build/changelog) |
| **cmux** | Mac | A notification ring and lit tab identify attention. A shortcut jumps to the latest unread item. Sidebar metadata includes branch, PR status, working directory, ports, and the latest notification text. | [Repository](https://github.com/manaflow-ai/cmux) |
| **Cursor Agents Window** | Mac | Parallel agents run locally, in worktrees, in the cloud, and over SSH, with tabs or a grid. `/multitask` starts asynchronous subagents. The supplied chronology also records deprecations, including best-of-n; historical features should not be treated as stable current behavior. | [Cursor 3](https://cursor.com/changelog/3-0), [Later changes](https://cursor.com/changelog/04-24-26) |
| **Cursor mobile and web** | iPhone, iPad, web | Mobile supports Live Activities tracking up to eight agents, completion pushes, child transcripts, changed-file diffs, and PR actions. iPad offers full-width diffs and Pencil-assisted screenshot annotation. The web agent interface is installable. | [Mobile](https://cursor.com/docs/cloud-agent/mobile), [Agent web](https://cursor.com/blog/agent-web) |
| **Devin** | Web | Working / Ready / Blocked / Inactive groups, session preview cards, searchable activity with filters, shell-command history links, word-level diffs, and per-type phone notification preferences. | [Release notes](https://docs.devin.ai/release-notes/overview.md), [Session tools](https://docs.devin.ai/work-with-devin/devin-session-tools.md) |
| **Factory** | Desktop / web | Outputs sit beside the session, and inline diff comments go to the Droid. Missions begin with plan approval and expose features and milestones as checkpoints. | [App overview](https://docs.factory.com/docs/factory-app/overview), [Missions](https://docs.factory.com/docs/missions/overview) |
| **GitHub Copilot agents** | Web | Mission Control spans repositories and exposes logs plus pause, refine, and restart. Logs group similar tool calls. The documented review sequence moves through logs, changed files, and checks. | [Mission Control](https://github.blog/ai-and-ml/github-copilot/how-to-orchestrate-agents-using-mission-control/), [Agents tab](https://github.blog/changelog/2026-01-26-introducing-the-agents-tab-in-your-repository/) |
| **GitHub Mobile + connected Copilot** | iPhone and connected surfaces | State-based session navigation, native logs, stop, and PR creation/review. The October 28 update describes a shared session list across web, mobile, CLI, VS Code, and Slack, including steering local sessions and approving gated calls. | [Mobile update](https://github.blog/changelog/2026-04-01-github-mobile-stay-in-flow-with-a-refreshed-copilot-tab-and-native-session-logs/), [Connected experience](https://github.blog/changelog/2026-10-28-work-from-anywhere-with-a-new-connected-copilot-cloud-experience) |
| **Jules** | Web | Users can request a plan and approve it before code changes. Browser notifications announce completion or required input. | [Documentation](https://jules.google/docs/) |
| **Warp** | Mac | Agent-state tab icons, attention badges, bounded in-window toasts, and an All / Unread / Errors mailbox. Child-agent notifications roll up to the parent. | [Agent notifications](https://docs.warp.dev/agents/capabilities/agent-notifications/) |
| **Zed** | Mac | External agents run as ACP threads. A change-summary accordion leads to multibuffer review with per-hunk acceptance/rejection. Edit checkpoints can be restored, and follow-agent mode is available. | [Agent panel](https://zed.dev/docs/ai/agent-panel), [External agents](https://zed.dev/docs/ai/external-agents) |
| **Linear** | Mac, iPhone | Keyboard-driven inbox triage and command search. Delegating to an agent preserves the human as owner and records the agent as delegate. | [Inbox](https://linear.app/docs/inbox), [Agents](https://linear.app/developers/agents) |
| **Raycast** | Mac | Root Search, Quick AI, searchable chats with status, and automatic model tiers. Chat runs separately so the palette remains responsive. | [Changelog](https://www.raycast.com/changelog) |
| **Apple platform behavior** | Mac, iPhone, iPad | iOS 26 uses floating, adapting navigation surfaces. iPadOS 26 supports freely resizable windows and a menu bar. macOS Tahoe can display Live Activities from a nearby iPhone; selecting one opens the app through iPhone Mirroring. | [iOS 26](https://www.apple.com/newsroom/2025/06/apple-elevates-the-iphone-experience-with-ios-26/), [Liquid Glass adoption](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass), [iPadOS 26](https://www.apple.com/newsroom/2025/06/ipados-26-introduces-powerful-new-features-that-push-ipad-even-further/), [macOS Tahoe](https://www.apple.com/newsroom/2025/06/macos-tahoe-26-makes-the-mac-more-capable-productive-and-intelligent-than-ever/) |
| **Apple notifications and Live Activities** | Apple platforms | Notification actions, inline text replies, conversation grouping, and ActivityKit push updates provide building blocks for remote attention and response. | [Notification actions](https://developer.apple.com/documentation/usernotifications/unnotificationaction), [ActivityKit push updates](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications) |
| **Sculptor / Vibe Kanban** | Mac / web | Sculptor isolates agents in containers and offers a pairing workflow back to the local repository. Vibe Kanban uses Plan / Prompt / Review task cards and diff comments, but is being sunset. | [Sculptor](https://imbue.com/sculptor/), [Vibe Kanban](https://www.vibekanban.com/) |

**Boundaries on these findings:** Conductor’s iOS, remote-control, approval, queue, and command-palette changelog titles establish announcements, not their detailed interaction behavior. The supplied Comet finding remains **unverified**, so it does not support a recommendation here. Unverified HIG wording is also excluded. No native Devin mobile offering is established by this research.

**What this changes for Omnigent**

- **Mobile supervision is an established workflow.** Codex, Claude, Cursor, and GitHub support concrete forms of approving, reviewing, or steering existing work. This supports prioritizing those journeys; it does not prove that Omnigent users rarely create tasks on their phones.
- **Attention deserves a dedicated surface.** The evidence supports visible waiting states, filters, previews, and actionable queues. It does **not** establish that every competitor always sorts waiting sessions first.
- **Review needs an explicit feedback loop.** Claude’s submit-comments action and Factory’s agent-directed comments are useful references. Omnigent should make draft versus submitted feedback unmistakable. Conductor’s support for inline comments alone does not establish identical delivery semantics.
- **Permission automation needs explanation.** Sandbox boundaries, approval policies, and automated review are different concepts. “Auto” cannot be assumed to mean the same thing across harnesses.
- **Notifications and a focused Live Activity deserve near-term investment.** Cursor provides a strong agent-specific precedent; ChatGPT’s voice activity is a narrower precedent. Neither proves that eight concurrent activities are desirable for Omnigent. Tahoe mirroring also does not provide independent native Mac activity support automatically.

**The strongest combination for Omnigent:** a calm reading experience, explicit execution context, an actionable attention queue, and a review flow that closes the loop with the agent.

---

**2. Review of the current UI**

Severity definitions: **High** impairs a frequent workflow or understanding of an action; **Medium** adds substantial friction or weakens hierarchy; **Low** is polish. Static screenshots cannot establish functional failures.

Playground scenario/theme controls are excluded from the product-toolbar critique. Screenshot 7 is pre-polish; screenshot 3 is a Mac compact preview, not an iPhone capture. No iPad capture was supplied.

**Mac**

| Severity | Surface / evidence | Finding and recommendation |
|---|---|---|
| **High** | Approvals — screenshots 1–2 | The main decision is visible, but the broader permission choices require substantial reading and look nearly disabled. Prefer **Approve once**, **Reject**, a redirection action, and **More approval options…**. Match “once” to the actual request semantics. Preserve the existing confirmation before widening permissions. |
| **High** | Approval payload and policy | The edit request names a directory and file count, but the capture does not expose the proposed changes. Offer inspectable affected files/diffs when supplied. Command rendering already exists in shared components; reuse it. Show what is being authorized separately from any change to future approval behavior. |
| **High** | Session state — screenshots 5–6 | A previous response error, an interrupted answer, “Working…,” and “Responding” coexist. Add one authoritative current-state summary and identify historical failures by attempt. Automated approval review, when supported, should have an explicit state rather than resembling an unanswered human request. |
| **High** | Approval dock — screenshots 1–2 | The dock, context tray, and unavailable composer occupy substantial lower-screen space. Retain inline and pinned access, as already decided, but give the dock a compact summary and explicit expansion path. External authorization should retain its **Open approval page** flow and destination domain. |
| **Medium** | Composer context — screenshots 1, 5–6 | The context ring resembles a running indicator. Code confirms that it represents context usage. Expose a label such as `Context used: 68%` through click/tap and accessibility, without relying on hover. |
| **Medium** | Header — screenshots 1, 5, 10 | Share has more emphasis than most task controls. Make it a standard toolbar action and prioritize title, current state, and workspace access. Preserve presence, Info, and the existing navigation destinations through adaptive presentation. |
| **Medium** | Transcript — screenshots 5–6, 9 | The playground is calmer than the real-app capture, where short prompts occupy wide bubbles and synthetic output forms dense blocks. Verify mounted-component/build parity before introducing another spacing system. Compare realistic prose and code as well as streaming stress content. |
| **Medium** | Inspector/terminal — screenshot 10 | Six symbols require memorization, and terminal access appears in two places. Name the distinction **Agent terminal** versus **Workspace terminals**. Use a labeled selector when tabs cannot fit, and expose the active terminal’s owner, directory, and connection state. |
| **Medium** | New session — screenshot 4 | Otto and the greeting work well. The setup summary should make agent, host, repository, and worktree understandable before first send. Distinguish the selected server from the machine executing the task. |
| **Medium, partly addressed** | Inbox — screenshot 7 | The pre-polish capture has excessively wide rows; current code already caps Inbox width at 880pt and supports expanding rows. Validate the mounted implementation. The next improvement is fast resolution, including the exact request, waiting age, and a route to the next item. |
| **High-priority validation gap** | Changes and review | These captures do not demonstrate a complete review journey. Verify review scope, diff navigation, comment submission, and the transition back to agent work. A visible Changes tab alone does not establish that workflow. |

**iPhone**

| Severity | Surface / evidence | Finding and recommendation |
|---|---|---|
| **High** | Monitoring versus composing — screenshot 8 | Keyboard and composer dominate the running-session capture. That is appropriate during editing, but opening an existing run should normally offer a keyboard-hidden reading state. The screenshot does not prove that autofocus occurs. |
| **High** | Running composer — screenshot 8 | “Send a message…” leaves queue-versus-steer behavior unclear. Label the actual operation. The local spec supports steering behavior, so Claude’s Enter-to-queue convention should not be imported blindly. |
| **High, validation risk** | Pending approvals | No real-device approval capture was supplied. The compact dock’s card-scroll region can reach 240pt, with its header and surrounding controls adding more height. Validate seven requests, long paths, and forms with the keyboard open. |
| **High-priority gap in evidence** | Diffs and feedback | Mobile diffs are now a concrete competitive reference. Validate file-by-file review, readable long lines, persistent drafts, and a visible **Send feedback to agent** action. The compact transcript preview provides no evidence of these capabilities. |
| **Medium** | Navigation bar — screenshot 8 | Text behind the translucent bar makes the scroll edge noisy. Use sufficient system backing and verify that content can scroll fully clear of the bar before diagnosing an inset defect. |
| **Medium** | Execution context — screenshot 8 | “Default” does not identify the agent or execution location. A remote decision needs quick access to agent, host, repository, and current connection state. |
| **High-priority gap in evidence** | Remote availability | No capture demonstrates a sleeping/offline host, expired request, or reconnect. Distinguish **Agent working**, **Host unavailable**, and **Status last updated…**. A stale spinner must not imply continued progress. |
| **Medium, unassessed** | Session switching and Inbox | Test answering three sessions in succession. The user should retain enough context to decide without repeatedly reconstructing the transcript or returning through several screens. |
| **High-priority gap in evidence** | Notifications and Live Activities | Their presence or absence cannot be determined from these captures. Validate delivery, deep links, stale-request handling, and a selected-session Live Activity as part of the phone workflow. |

**iPad**

These are **design risks to validate**, not observed defects.

| Severity | Surface | Recommendation |
|---|---|---|
| **High** | Resizable windows | Adapt to available width. Collapse the inspector before sidebar, conversation, and inspector squeeze the primary task. Preserve selection, drafts, and scroll position through resizing. |
| **High** | Code review | Let a diff become the primary detail view. Use side-by-side comparison only when both columns remain readable; retain unified review at narrower widths. |
| **Medium** | Inspector navigation | Six icon-only destinations are weak for touch. Use labeled navigation or a section menu, with useful counts on Changes and Agents. |
| **Medium** | Keyboard and pointer | Expose commands through native menus and discoverable shortcuts. Scope Escape, send, and approval commands to the focused surface; terminal input must not trigger conversation actions. |
| **Medium** | Sheets and multitasking | Use popovers for small choices, sheets for bounded decisions, and full detail navigation for substantial review. Avoid nested scrolling regions that compete with the keyboard. |

**Cross-platform accessibility finding**

White on the specified `#DF3C85` is approximately **4.10:1**, below the 4.5:1 benchmark for normal-size text. This token calculation does not establish that every rendered pink control fails: actual foreground, size, material, and compositing matter.

The code already has an adaptive `onAccent` helper. Apply that consistently and inspect actual controls in both appearances. Existing send-label checks do not establish approval-button or Share-button contrast. Status, selection, and automated-review outcomes also need text or symbols beyond color.

---

**3. Top 15 recommendations, ranked by impact ÷ effort**

**S=1, M=2, L=3.** Estimates assume reuse of existing components and available server data. Missing host-health signals, review APIs, or notification infrastructure increase effort. Equal ratios are ordered by consequence and frequency.

This ranks implementation opportunities; approval correctness and accessibility remain release requirements regardless of their ratio.

1. **Establish one authoritative current-state summary.**  
   **Where:** Session header and transcript activity presentation. Show `Running · Testing auth changes`, `Waiting for you · 2 requests`, or `Finished · 3 files changed` only when supported by reported state. Separate historical errors, connection health, context usage, and automated approval review. Avoid introducing another collection of competing badges.  
   **Inspiration:** Codex Activity, Claude agent view, Devin. **Platforms:** Mac/iPhone/iPad. **Impact L / effort S = 3.0** for presenting existing state.  
   **Omnigent fit:** Gives heterogeneous agent events a consistent human vocabulary.

2. **Make execution context and readiness readable.**  
   **Where:** Composer tray, approval details, and `NewSessionPage`. Use a compact summary such as `Codex · Mac Studio · omnigent / auth-refresh`, with full details on demand. Keep server and execution host distinct. Preserve Otto and add a setup sentence on the landing page; surface unavailable execution destinations before first send.  
   **Inspiration:** Claude’s pre-send environment row, Codex host filters, Conductor workspaces. **Platforms:** All. **M/S = 2.0** for existing context.  
   **Omnigent fit:** Makes its local/remote and multi-server capabilities understandable.

3. **Reserve visual emphasis for the current task.**  
   **Where:** Toolbar, approval cards, sidebar, and composer. Make Share a normal toolbar action. Use pink for the primary action and restrained selection; retain labeled semantic error/warning treatments. Keep reading-column and short-bubble behavior consistent between playground and app.  
   **Inspiration:** Native toolbar hierarchy and Linear’s triage model. **Platforms:** All. **M/S = 2.0.**  
   **Omnigent fit:** Preserves the identity while improving attention.

4. **Make configuration agent-first and defaults explainable.**  
   **Where:** `ConfigurationMenu`. Present **Agent → Model → Effort**, constrained to valid choices. Explain what Default resolves to when known and when a selection takes effect. Keep approval policy separately identifiable; a model selection must not imply a permission change.  
   **Inspiration:** Claude’s explicit setup controls; ChatGPT’s distinction between persistent and per-message model choices. **Platforms:** All. **M/S = 2.0.**  
   **Omnigent fit:** Makes the chosen harness a first-class concept without exposing a flat settings catalog.

5. **Make approvals specific, inspectable, and redirectable.**  
   **Where:** `DecisionCardView`, `PermissionChoice`, and approval-mode menus. Expose the actual command, proposed files, or plan when provided. Prefer **Approve once**, **Reject**, **Tell the agent what to do instead**, and **More approval options…**. Preserve scope-widening confirmation and show scope/duration precisely. Keep sandbox scope separate from approval automation.  
   **Inspiration:** Codex mobile payloads and redirection; Codex policy separation; Claude plan review. **Platforms:** All. **L/M = 1.5.**  
   **Omnigent fit:** Supports different harnesses without pretending their permission models are interchangeable.

6. **Make Inbox the fastest route to a decision.**  
   **Where:** `InboxView` and session navigation. Show the exact pending question or approval summary, relevant execution context, and waiting age. Resolve in place when supported, preserve selection, and offer the next actionable item. Keep unread and unresolved states separate; retain pinned items and predictable keyboard navigation.  
   **Inspiration:** Claude peek panels, Linear triage, Codex Activity, GitHub Mobile. **Platforms:** All. **L/M = 1.5.**  
   **Omnigent fit:** Builds on existing Inbox and Needs Response access.

7. **Separate queueing, steering, and stopping visibly.**  
   **Where:** Composer and `QueueStrip`. Describe the actual send behavior: `Queued · after this turn` or `Send now · steer current work`, as supported. Provide labeled Edit, Send now, and Remove actions. Keep Stop available while drafting. Retain Omnigent’s intended defaults and scope Escape to the focused UI.  
   **Inspiration:** Claude’s explicit queue controls and removable queued web messages. **Platforms:** All. **L/M = 1.5.**  
   **Omnigent fit:** Makes long-running shared sessions predictable.

8. **Give the approval dock compact and expanded states.**  
   **Where:** `DecisionDock`. Retain inline cards and pinned access. A compact summary should open the full request; simple decisions may expose actions directly when enough payload remains visible. Replace arrow-only discovery with a selectable request list. Use a native sheet for substantial phone forms and preserve shared drafts.  
   **Inspiration:** Attention queues and native detail presentation. **Platforms:** All, especially iPhone. **L/M = 1.5.**  
   **Omnigent fit:** Preserves the agreed dual placement with less duplicated visual weight.

9. **Make reading the default phone posture.**  
   **Where:** Conversation navigation and composer focus. Open existing runs with the keyboard hidden unless the user explicitly resumes editing. Preserve drafts, support interactive dismissal, and expose **Jump to latest** after scrolling away. Incoming output must not displace the user’s reading position.  
   **Inspiration:** Established mobile conversation behavior and remote-agent supervision. **Platforms:** iPhone and narrow iPad windows. **L/M = 1.5.**  
   **Omnigent fit:** Supports brief checks on work running elsewhere.

10. **Complete accessibility across the decision and review journeys.**  
    **Where:** Theme roles, buttons, queue controls, inspector navigation, and forms. Reuse adaptive foregrounds, verify enabled/disabled contrast, provide appropriate touch targets, and test Dynamic Type, VoiceOver, Reduce Transparency, and Reduce Motion. Ensure every essential action is reachable without hover.  
    **Inspiration:** Apple accessibility conventions. **Platforms:** All. **L/M = 1.5.**  
    **Omnigent fit:** Preserves theme choice while making core workflows dependable.

11. **Build a complete review-and-feedback loop.**  
    **Where:** Changes and Pull Requests. Offer useful review scopes, including **Last turn** when the backend can identify it reliably. Use an expandable diff workspace on Mac/iPad and focused file navigation on iPhone. Persist comment drafts and provide **Send feedback to agent**, followed by a delivery acknowledgment. Track the reviewed revision and flag stale review state after changes.  
    **Inspiration:** Codex review scopes, Claude comment submission, Factory agent feedback, Cursor mobile diffs, Zed review. **Platforms:** All. **L/L = 1.0.**  
    **Omnigent fit:** Completes the journey from delegated work to informed intervention.

12. **Ship useful notifications and one focused Live Activity.**  
    **Where:** Notification settings, session-follow controls, and iOS activity presentation. Start with required input and optional completion alerts, grouped by session and linked to the relevant request or result. Follow a selected run with semantic states. Support inline replies for suitable questions; approval actions need sufficient context and current request validation.  
    **Inspiration:** Codex notification controls, Claude action-required pushes, Cursor Live Activities, Apple notification APIs. **Platforms:** iPhone first; coordinated Mac behavior. **L/L = 1.0.**  
    **Omnigent fit:** Makes remote work useful while the app is closed. Validate existing infrastructure before estimating delivery.

13. **Deliver a small command palette and fast attention navigation.**  
    **Where:** Native Commands and session navigation. Start with Find session, New session, Next request needing response, Open Changes, Switch server, and Focus composer. Display scope and keyboard hints. A searchable status preview is more useful initially than a large command catalog.  
    **Inspiration:** Raycast, Linear, Codex, cmux. **Platforms:** Mac and hardware-keyboard iPad. **M/M = 1.0.**  
    **Omnigent fit:** Makes the existing information architecture easier to traverse.

14. **Make sub-agents understandable as a group.**  
    **Where:** Sub-agent chips and Agents panel. Show `2 agents · 1 running · 1 ready`, expandable to goals, meaningful activity, and decisions. Open child transcripts with an obvious route back. Roll routine child notifications into the parent while keeping blocked child work discoverable.  
    **Inspiration:** Warp notification rollups and Cursor child transcripts. **Platforms:** All. **M/M = 1.0.**  
    **Omnigent fit:** Exposes delegation without requiring constant transcript switching.

15. **Clarify workspace and terminal navigation.**  
    **Where:** `WorkspaceInspector`, Chat/Terminal picker, and terminal panel. Use labeled navigation when tabs cannot fit. Distinguish agent-owned and user workspace terminals, identify the input destination and connection state, and allow substantial terminal/file work to expand into the primary pane.  
    **Inspiration:** Codex’s chat/worktree association, cmux metadata, Claude’s movable panes. **Platforms:** Mac/iPad; focused destinations on iPhone. **M/M = 1.0.**  
    **Omnigent fit:** Supports terminal-oriented harnesses while preserving clear ownership.

---

**4. Bigger bets**

1. **A multi-session “Now” view built on the existing Canvas.**  
   Organize work around **Needs you**, **Running**, and **Ready to review**, with a dense list as well as a spatial view. Show the goal, project, latest meaningful event, and next action. A peek should expose the actual question and waiting age; supported decisions should be answerable there.

   Preserve pinning and stable navigation rather than continually moving the selected row as statuses change. “Ready to review” should mean a reviewable result exists, not merely that generation stopped.

2. **A durable goal and checkpoint experience across harnesses.**  
   Codex’s goal controls and Factory’s milestones support a stronger long-running-work model than a perpetual transcript spinner. Omnigent could expose the objective, agreed plan, completed checkpoints, remaining work, and a recap that does not interrupt execution.

   Keep the presentation consistent while showing only controls the selected harness supports. Pause, stop, resume, and edit-goal can have different consequences; those differences should remain visible.

3. **Cross-device continuation with explicit host availability.**  
   Resume at the selected request, file, diff hunk, or transcript position. Preserve drafts and show concurrent resolution: `Approved by Sam on Mac · 12:42`. Make the server authoritative for decisions.

   Show whether execution depends on a particular computer, whether it is reachable, and when state was last refreshed. Keep-awake controls can help local workflows but should not imply cloud independence. Distinguish continuing the interface on another device from migrating the execution environment. Spotlight and App Intents can provide direct entry to outstanding work.

4. **A review package at the end of each task.**  
   Combine the agent’s summary with changed files, the exact revision, test evidence, screenshots/artifacts, unresolved questions, and a clear feedback action. Distinguish agent-reported claims from captured execution results.

   This makes “ready to review” substantive and gives iPad a valuable role as a focused review surface. It also supports Omnigent’s broader outputs beyond code.

5. **A browser workspace with visible control and human takeover.**  
   Show the active site, agent activity, execution environment, and **Take control**. Keep tabs associated with their session and make exposed context explicit. Human login steps should return cleanly to the agent workflow.

   Codex’s visible cursor, Claude’s session tab groups, and ChatGPT’s context banner offer distinct useful references. Preserve a coherent experience across Chromium and WebKit editions while exposing capability differences accurately.

---

**5. What not to copy**

- **A full IDE compressed onto a phone.** Prioritize decisions, focused review, monitoring, and short steering messages. Keep fresh task creation easy without surrounding it with every desktop control.
- **A universal “waiting first” sort.** Attention needs prominence, but pinned work, stable selection, and review readiness also matter. The research does not establish one universal ordering.
- **Diff feedback that silently waits for an unrelated message.** Use an explicit submission action with visible draft and delivery states. Sending every comment keystroke immediately would create a different problem.
- **One-click “always allow” without understandable scope.** Preserve Omnigent’s existing widening confirmation and name the affected action, directory, site, or session precisely.
- **One generic meaning of “Auto.”** Automated approval review, permission classifiers, sandbox access, and model routing are different mechanisms. Explain the selected harness’s behavior.
- **Remote-control screens that imply the host is always available.** Connection loss, sleeping hosts, expired requests, and stale information need clear states. Do not copy another product’s timeout or retention numbers without a product reason.
- **Terminal attachment as a prerequisite for ordinary decisions.** Keep strong terminal access, but let supported approvals and questions be handled from their attention surface.
- **Every agent event as a large card.** Compact disclosures suit routine tool activity. Decisions, errors, and durable results deserve stronger structure.
- **Notification volume as proof of capability.** Aggregate routine child activity, make completion alerts configurable, and avoid making eight simultaneous Live Activities a target.
- **Hidden gestures as the only route to important controls.** Long-press model overrides and hover previews can be useful accelerators; visible alternatives must remain available.
- **Liquid Glass over every surface.** Use system materials for navigation and transient controls. Prose, code, and approval payloads need stable backing.
- **Fake progress or interchangeable spinners.** Context usage is not task progress. Running, reconnecting, reviewing an approval, waiting for input, and stopped are distinct states.
- **A permanently visible mission-control dashboard.** Make orchestration a destination. A focused session should remain calm.
- **Features copied from historical announcements without checking their lifecycle.** Cursor’s deprecations and Vibe Kanban’s sunset are reasons to favor durable workflows over feature-name parity.

**How to validate these recommendations**

Use the playground for visual comparison:

```sh
cd apps/apple/Packages/OmnigentUI
swift run OmnigentPlayground
```

Then launch the actual apps from the repository root:

```sh
just apple-run
just apple-run-appstore
just apple-run-ios
```

For iPad, use an installed simulator name:

```sh
xcrun simctl list devices available
just apple-run-ios device="<installed iPad simulator name>"
```

Follow the [Apple app README](../../README.md) for prerequisites and first-time project generation. These commands are verification instructions, not checks performed during this review.

1. **Five-second state test:** Show Streaming Turn and Pending Approvals to someone unfamiliar with the app. Ask what is happening, what needs them, and which machine is executing the work.
2. **Approval comprehension test:** Present seven requests, including a command, long file path, form, and external authorization. Have the person inspect the payload, approve one request, redirect another, and explain the difference between approval and broader permission.
3. **Queue/steer test:** While an agent works, draft a follow-up. Ask what Send will do before pressing it. Edit and remove a queued message, exercise supported steering, and verify that Stop remains available.
4. **Phone reading test:** Open a running session, read earlier output, draft a message, dismiss the keyboard, and return to the latest output. Neither reading position nor draft should be lost.
5. **Review feedback test:** Review three files with one long code line on iPhone and iPad. Add comments, switch files, resume drafts, and submit feedback. Confirm delivery without requiring an unrelated chat message. Change the revision and verify stale review state is visible.
6. **Inbox triage test:** Resolve requests from three sessions consecutively. Check that each exposes enough context and that moving to the next item is predictable.
7. **Remote and concurrent-action test:** Disconnect or sleep the execution host, then reconnect. Resolve a pending request from another device. Confirm stale actions cannot be submitted and the first device shows the updated outcome.
8. **Notification test on a physical iPhone:** Background and lock the phone during a run. Trigger required input and completion, open their deep links, and verify correct behavior if the request has already been resolved. Check Live Activity updates and privacy settings.
9. **Adaptive and accessibility test:** Repeat approval and review with larger text, VoiceOver, Increase Contrast, and Reduce Transparency. Resize iPad windows mid-draft and test keyboard commands with focus in the composer, a dialog, and a terminal.