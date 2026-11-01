# Omnigent native apps: UI/UX review with competitor research

Reviewer: Claude (independent review). Date: 2026-11-01.
Inputs: the 10 `current-*.png` captures, `apps/apple/docs/web-ui-spec.md` (including the 2026-10-31
Decisions), `apps/apple/docs/ui-polish-review.md`, and the `OmnigentUIComponents` sources. The
competitor research comes from public pages fetched on 2026-11-01. Claims marked *[unverified]*
come from a search summary only; the primary page could not be read.

## The short version

The playground UI now reads like a calm ChatGPT-style chat app. That is the right base, but
Omnigent's job is different: people run several long-lived agents at once and need to know
which one needs them. The 2026 competitors have converged on this. Claude Code's agent view
groups sessions as "Needs input / Working / Completed". Codex has an Activity view, a floating
status pet, and a phone tab bar of "Tasks / Approve / Review". Cursor iOS tracks up to eight
agents in Live Activities. Warp puts state badges on tabs and keeps a notification mailbox.

Omnigent already has the pieces: Inbox, Running, Needs response, the decision dock, a menu bar
extra and a Dock badge. They don't yet add up to one clear signal, and the iPhone app has none
of the system surfaces (notifications with actions, Live Activities, widgets, App Intents)
where a phone-based agent supervisor earns its keep. My three main asks:

1. **Make "needs you" one consistent signal.** Use the same state, color, count and glyph in
   the row, Inbox, Dock badge, menu bar, notification and Live Activity.
2. **Use brand pink only for "needs you" and the single primary action,** and label every
   control that is icon-only or ambiguous today.
3. **Build the iPhone app around approving and reviewing agent work.** That means actionable
   notifications, a Live Activity, an approval sheet and a phone diff reader. A chat client
   with a keyboard is the wrong center.

---

## 1. Competitor findings

| Product | Platform | Patterns worth borrowing | Source |
|---|---|---|---|
| Codex app | Mac | Positioned as a "command center for agents". Threads are grouped by project and you switch between them without losing context. | https://openai.com/index/introducing-the-codex-app/ |
| Codex app: worktrees | Mac | A "Worktree" toggle under the composer gives each chat its own worktree. "Hand off" moves a chat between Local and Worktree, and "Create branch here" unlocks commit/PR. It keeps the 15 most recent worktrees and snapshots each one before deleting it. | https://learn.chatgpt.com/docs/environments/git-worktrees |
| Codex app: review pane | Mac | A scope selector (Unstaged / Staged / Commit / Branch / **Last turn**). Stage or revert per file and per hunk. `/review` presets. **Anti-pattern:** inline "+" comments don't reach the agent until you send a message. | https://learn.chatgpt.com/docs/code-review |
| Codex app: long-running work | Mac | A `/goal` progress row above the composer (pause / resume / edit / clear). A side chat gives a recap without interrupting the run. A "Prevent sleep while running" setting. | https://learn.chatgpt.com/docs/long-running-work |
| Codex app: attention | Mac | An Activity view (bell, ⌘⌥U) of unread, running and waiting chats. Turn-completion alerts can be set to never / background / always. Permission and question alerts have separate toggles. | https://learn.chatgpt.com/docs/notifications |
| Codex app: "pet" | Mac | A floating status companion showing Running / Needs input / Ready / Blocked, with Needs input first (⌥Space). | https://learn.chatgpt.com/docs/pets |
| Codex app: approvals | Mac | Sandbox modes (read-only / workspace-write / full access) are separate from approval policy. An "Auto" preset. **Auto-review** sends eligible approvals to a reviewer agent, with statuses Reviewing / Approved / Denied / Timed out. | https://learn.chatgpt.com/docs/agent-approvals-security |
| Codex app: terminal | Mac | One terminal per chat, tied to that chat's worktree. Ctrl+` toggles it. The agent can read terminal output. Saved commands become shortcuts. ⌘K opens a command palette. | https://learn.chatgpt.com/docs/integrated-terminal |
| Codex Computer Use | Mac | A visible virtual cursor shows what the agent is doing, and it works in the background without stealing focus. Permission is per app ("Allow Codex to use Calculator?") with Always allow / Allow / Cancel. Users mainly complain about speed. | https://www.macstories.net/notes/openais-new-codex-app-has-the-best-computer-use-feature-ive-ever-tested/ , https://learn.chatgpt.com/docs/computer-use |
| Codex on iPhone ("Remote") | iPhone | A bottom tab bar: **Tasks / Approve / Review / New task**. Host filter chips (All / Cloud / MacBook / Devbox). A "Permission requested" card with the command in monospace and **Approve / Always approve / Deny / "Tell Codex what to do"**. A "2 files changed +38 −12" summary that drills into a line-range diff. | https://learn.chatgpt.com/docs/mobile |
| Codex pairing | Mac + iPhone | Mac Settings > Connections > "Control this Mac", then scan a QR code. **Anti-pattern:** it only works while the Mac stays awake. | https://learn.chatgpt.com/docs/remote-connections |
| ChatGPT for Mac | Mac | A Chat Bar on ⌥Space. "Work with Apps" shows a banner listing exactly which apps and content are in context (for terminals, the last 200 lines). | https://help.openai.com/en/articles/9295241-accessing-the-launcher-chatgpt-macos-app , https://help.openai.com/en/articles/10119604-work-with-apps-on-macos |
| ChatGPT iOS | iPhone | A voice Live Activity on the Lock Screen and in the Dynamic Island. An effort picker (Instant / Medium / High / Extra High). **Long-press Send to pick a model for one message.** Triggered tasks pause at approval steps. | https://help.openai.com/en/articles/6825453-chatgpt-release-notes |
| Claude Code desktop | Mac | A row under the prompt sets Environment (Local/SSH/Cloud), folder, permission mode and model before the first send, and the mode is remembered per folder. Click the "+12 −1" card to open the diff, hover a line, click + to comment, and ⌘↵ submits every comment to Claude. Drag-and-drop panes (Changes, Browser, Terminal, Files, Plan, Background tasks). Shortcuts: ⌘⇧M (mode), ⌘⇧I (model), ⌘; (side chat), Ctrl+` (terminal), ⌘/ (shortcut sheet). | https://code.claude.com/docs/en/desktop |
| Claude Code permission modes | Mac / CLI | Manual / Accept edits / Plan / Auto (a classifier) / Bypass. Plan approval offers "Yes, and use auto mode / Yes, manually approve edits / No, keep planning". Auto mode pauses after 3 consecutive or 20 total blocks. A "Recently denied" list with retry. | https://code.claude.com/docs/en/permission-modes |
| Claude Code queue vs steer | CLI / desktop | Enter while the agent works **queues** the message. Esc interrupts and keeps completed work. Ctrl+Enter sends queued messages now. ↑ pulls queued items back into the input. | https://code.claude.com/docs/en/interactive-mode |
| Claude Code agent view | CLI | Groups are **Pinned, Ready for review, Needs input, Working, Completed**. State icons: Working (animated), Needs input (yellow), Completed (green), Failed (red), Stopped (grey). Space opens a **peek panel** with the exact question and "waiting 3m". Press a number to pick a choice. ↑/↓ moves between sessions while peeking. Filters such as `s:blocked a:reviewer #1234`. **Anti-pattern:** a permission prompt can't be answered from the list; you must attach first. | https://code.claude.com/docs/en/agent-view |
| Claude remote control / mobile | iPhone | The phone is a window onto a session running on your computer; rows show a computer icon with a green dot. Two push toggles: "Push when Claude decides" and "Push when actions required". Forwarded dialogs expire after 5 minutes. **Biometric step-up** (Face ID/passkey) after 18 h. Bypass mode can't be enabled from the phone. | https://code.claude.com/docs/en/remote-control , https://code.claude.com/docs/en/mobile |
| Claude Code on the web | Web | You can take back a queued message with ✕. Auto-fix PRs. Share visibility is Private / Team / Public. | https://code.claude.com/docs/en/claude-code-on-the-web |
| Claude Quick Entry | Mac | Double-tap ⌥ (configurable) opens an overlay with a text box and the 5 most recent chats. | https://support.claude.com/en/articles/12626668-use-quick-entry-with-claude-desktop-on-mac |
| Claude in Chrome | Browser | Tabs the agent opens go into **a tab group per session**. The permission dialog offers "allow all actions on this site for the session". Login pages and CAPTCHAs pause for the human. | https://code.claude.com/docs/en/chrome |
| Conductor | Mac | Each task gets a workspace (branch, terminal, diff, review). The diff viewer has per-commit filtering, inline comments, and resolution of GitHub threads. Suggested next actions: Create PR, Fix checks, Merge when ready. The changelog lists "Tool Approval", "New queue", "Command Palette", "Conductor for iOS" and "Remote control" (titles only). | https://conductor.build/docs/reference/diff-viewer , https://conductor.build/changelog |
| cmux | Mac | Ghostty-based. A **blue notification ring** on a pane and a lit tab when an agent needs attention. Jump to the latest unread with ⌘⇧U. The sidebar shows branch, PR status, cwd, listening ports and the latest notification text for each tab. Hooks install for Claude Code and Codex. | https://github.com/manaflow-ai/cmux |
| Cursor 3 Agents Window | Mac | Agents run in parallel locally, in worktrees, in the cloud, and over SSH, in tabs or a grid. `/best-of-n` runs the same task across models, each in its own worktree. `/multitask` runs async subagents instead of queueing. **Anti-pattern:** churn (Editor worktrees and best-of-n were deprecated). | https://cursor.com/changelog/3-0 , https://cursor.com/changelog/04-24-26 |
| Cursor iOS / iPad | iPhone, iPad | **Live Activities track up to 8 agents** on the Lock Screen and in the Dynamic Island. A push when a turn finishes. Subagent cards open the child transcript. A changed-files diff on iPhone and full-width diffs on iPad. Squash-merge, auto-merge, and "fix failing check" from the phone. Design Mode lets you draw on screenshots, with Pencil on iPad. | https://cursor.com/docs/cloud-agent/mobile |
| Cursor web | Web PWA | cursor.com/agents is an installable control plane. Slack notifications when an agent finishes. | https://cursor.com/blog/agent-web |
| Devin | Web | The sidebar groups **Working / Ready / Blocked / Inactive**. ⌥J/K moves between sessions. **Hover preview cards** show status, latest reply and PRs. One searchable activity view with type filters. Shell commands are time-travel links. Word-level diff highlights. A notification inbox with per-type "also push to phone" switches. | https://docs.devin.ai/release-notes/overview.md , https://docs.devin.ai/work-with-devin/devin-session-tools.md |
| Factory | Desktop / web | Outputs (diffs, docs, live sites) sit beside the session, and inline diff comments go to the Droid. **Missions:** approve a plan first, then Mission Control shows features and milestones as checkpoints. | https://docs.factory.com/docs/factory-app/overview , https://docs.factory.com/docs/missions/overview |
| GitHub Copilot agents | Web | Mission Control assigns tasks across repos and offers live logs plus pause, refine or restart. Logs group similar tool calls and preview outputs inline. Review happens in three passes: logs, then Files changed, then checks. | https://github.blog/ai-and-ml/github-copilot/how-to-orchestrate-agents-using-mission-control/ , https://github.blog/changelog/2026-01-26-introducing-the-agents-tab-in-your-repository/ |
| GitHub Mobile + connected Copilot | iPhone | A Copilot tab sorted by state with real-time filters, native session logs, stop, and create/review PR. Since 2026-10-28, **one session list across web, mobile, CLI, VS Code and Slack**; local sessions can be steered from the phone, and gated tool calls ask for approval. "Watch and fix" in the merge box. | https://github.blog/changelog/2026-04-01-github-mobile-stay-in-flow-with-a-refreshed-copilot-tab-and-native-session-logs/ , https://github.blog/changelog/2026-10-28-work-from-anywhere-with-a-new-connected-copilot-cloud-experience |
| Jules | Web | "Give me a plan", and you approve the plan before any code changes. Browser notifications when it's done or needs input. | https://jules.google/docs/ |
| Warp | Mac | **Tab icons show agent state** (working, blocked, completed, errored) plus an attention badge that clears when you visit. In-window toasts for another tab's agent (at most two, hover pauses them). A mailbox with All / Unread / Errors. Child-agent notifications roll up to the parent through a pill bar. | https://docs.warp.dev/agents/capabilities/agent-notifications/ |
| Zed | Mac | External agents (Claude, Codex) as threads over ACP. A change-summary accordion above the composer. "Review Changes" opens a multibuffer with accept/reject per hunk. "Restore Checkpoint" on each edit. **Follow-agent mode.** | https://zed.dev/docs/ai/agent-panel , https://zed.dev/docs/ai/external-agents |
| Linear | Mac, iPhone | Inbox triage keys: J/K, H snooze, U read, Backspace delete. ⌘K command menu. When you delegate to an agent, the agent becomes the *delegate* and the human stays the owner; an agent should emit a "thought" within 10 s. | https://linear.app/docs/inbox , https://linear.app/developers/agents |
| Raycast | Mac | Root Search plus Quick AI. Chat runs in its own process so the palette stays instant. ⌘P chat search shows each chat's status. Auto model tiers: Lightweight / Balanced / Flagship. | https://www.raycast.com/changelog |
| Perplexity / Comet | iPhone | Comet launched on iPhone in March 2026 with an assistant and voice. Live Activities are used for followed items. *[unverified: search summary only]* | https://www.macrumors.com/2026/03/18/perplexity-comet-browser-iphone/ |
| Apple: macOS Tahoe | Mac | **Live Activities from a nearby iPhone appear in the Mac menu bar.** Clicking one opens the app through iPhone Mirroring. | https://www.apple.com/newsroom/2025/06/macos-tahoe-26-makes-the-mac-more-capable-productive-and-intelligent-than-ever/ |
| Apple: iOS 26 / Liquid Glass | iPhone | Tab bars and toolbars float above content and shrink on scroll. Search sits at the bottom in Messages, Mail and Notes. Use the system containers (NavigationSplitView, TabView, toolbars) to get the material for free. *[HIG page text unverified]* | https://www.apple.com/newsroom/2025/06/apple-elevates-the-iphone-experience-with-ios-26/ , https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass |
| Apple: iPadOS 26 | iPad | Freely resizable windows, tiling, Exposé, and a menu bar (swipe down) with search. Apps reopen at their last size. | https://www.apple.com/newsroom/2025/06/ipados-26-introduces-powerful-new-features-that-push-ipad-even-further/ |
| Apple: notifications / Live Activities | iPhone, Mac | Up to 3 quick actions. `UNTextInputNotificationAction` for inline reply. `threadIdentifier` groups notifications per conversation. Live Activities support push-to-start, push updates and App Intent buttons. Keep sensitive content off the Lock Screen. *[HIG text partly unverified]* | https://developer.apple.com/documentation/usernotifications/unnotificationaction , https://developer.apple.com/design/human-interface-guidelines/live-activities , https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications |
| Sculptor / Vibe Kanban | Mac / web | Sculptor runs each agent in a container, and "Pairing Mode" syncs that work into the local repo. Vibe Kanban is a Plan / Prompt / Review board of task cards with diff comments (it is being sunset). | https://imbue.com/sculptor/ , https://www.vibekanban.com/ |

**Cross-cutting takeaways**

- Every serious competitor puts **"waiting on you" at the top of the list**: Claude agent view,
  Devin, Codex Activity, Warp and GitHub Mobile.
- **On the phone, the core verbs are approve, review and steer.** Composing a fresh task matters
  less: Codex's tab bar is literally Tasks / Approve / Review / New task.
- **Approvals show the payload** (the exact command or the files) and offer **3–4 choices at
  most**, one of which is "tell the agent what to do instead" (Codex mobile, Claude plan review).
- **Diff comments should go straight to the agent.** Claude's ⌘↵ submits all comments, and
  Factory and Conductor work the same way. Codex holding comments until the next message is the
  pattern to avoid.
- **Live Activities and actionable notifications are now table stakes on iPhone** (Cursor tracks
  8 agents). With macOS Tahoe they show up in the Mac menu bar for free.

---

## 2. Review of the current UI

Severity: **Critical** (breaks trust or core flow), **High**, **Medium**, **Low**. The Mac
playground's left toolbar pill (scenario picker) and palette button are playground chrome, so
I don't review them.

### Cross-platform (shared components)

| # | Surface | Issue | Severity |
|---|---|---|---|
| X1 | State model | **"Needs you" disagrees with itself.** In the approvals capture the dock says "7 requests need your response", the sidebar shows "Needs response 1" and "Inbox 3", the Inbox header says "4 items", and the session with 7 pending requests shows a *running sparkle* in its row, not the "Needs response" badge that spec 4.1 requires. Users will stop trusting the counts. | Critical |
| X2 | Composer: approval-mode chip | **"Approve for me" reads as a button that approves the pending request**, and it sits right under "Respond to the pending request above to continue". The chip names a *mode* with an *action-shaped* phrase, using the same hand icon as "Needs response". On compact widths it collapses to a bare hand glyph. | High |
| X3 | Brand color | Pink is used for Share (a filled capsule), Approve, "Open approval page", Submit, the queue icons, the context ring, the sub-agent icons, links, the selection fill and kind labels. In the approvals capture, **four filled pink buttons** are visible at once. Pink no longer means "act here". | High |
| X4 | Approval card | It doesn't show *what* will happen: "Codex wants to edit 3 files in …/auth" lists neither the files nor a diff. Three permission-widening options get the same visual weight as text chips. No keyboard hint for ⌘↵, and no "deny with instructions" path. | High |
| X5 | Context tray | Unlabeled glyphs: a pink spinning-looking ring (context usage? loading?), a laptop icon (host, with no name or online dot), and a ↘↖ "expand" icon. The PR shows as "#20001536" with a commit-graph glyph that looks like a branch. | Medium |
| X6 | Sub-agent chips | "Write auth tests Running ↗" is static text. There's no live activity, elapsed time or blocked state, and ↗ suggests it leaves the session. On compact widths the chips stack and use a lot of vertical space. | Medium |
| X7 | Transcript states | "Interrupted" uses an ✕ in one capture and a radio-dot in another. "Responding" is a grey dot plus a label below the text. "Working…" and "Worked" sit at different indents. Large dead gaps (about 100pt) between a user bubble and the next fold. The real app shows "Worked ›" with no duration. | Medium |
| X8 | Unknown content | The user bubble shows a dashed box with "? Message content". It looks like a rendering failure. | Medium |
| X9 | Queue strip | The ↑ in a circle (send now / steer?) and the ✕ in a circle are unlabeled, and "Queued" sits far from the text. It's unclear whether ↑ means "interrupt and steer" or "send after the current turn". | Medium |
| X10 | Model chip | "Default" (new session) and "OA Default" (real apps) say nothing about which agent or model will run. For a meta-harness, the harness is the most important choice, yet it hides behind a tiny letter glyph. | High |
| X11 | Form card | A "Signing token — Optional" field shows the validation hint "Enter PR title." (wrong field). In dark mode, the disabled "Submit" is a muted pink that still looks enabled. | Low |

### Mac

| # | Surface | Issue | Severity |
|---|---|---|---|
| M1 | Real app vs playground | **The shipped Mac app hasn't caught up with the playground.** It has no header actions besides the globe and the inspector toggle, no context tray, no approval-mode chip, and no Inbox counts. The server shows as raw "127.0.0.1". Transcript text ("Are you still there?") shows through the transparent titlebar with no scroll-edge effect. What users see is this capture, not the playground. | Critical |
| M2 | Sidebar density | Five nav rows (New session, Inbox, Canvas, Running, Needs response) above four sections push actual sessions below the fold on a 13" display. Running and Needs response duplicate the Inbox and the status grouping. | Medium |
| M3 | Session row glyphs | Trailing glyphs are a tiny sparkle (running), a red ! (error) and a hollow "o" (disconnected) that reads like a typo. None has a tooltip-level label in view. There's no unread treatment and no secondary line for repo/branch. | Medium |
| M4 | Header | Chat/Terminal is a custom segmented control floating next to the title. With a single viewer, the avatar cluster plus Info plus a pink Share pill crowd the toolbar. On narrow widths the title truncates ("Refactor token refre…") while 800pt of toolbar sits empty. | Medium |
| M5 | Right panel | Icon-only tabs (folder, ±, branch, chip, terminal, info) with no labels. The Terminals tab spends the top third on a 3-row list, so the terminal itself is cramped. Terminal names are IDs ("zsh · u-4f2k9q"). Header controls (avatars, Share) jump over the inspector when it opens. | Medium |
| M6 | Inbox | Rows span the full width (about 1,500pt) with timestamps at the far right. There are no inline actions (approve or reply) in view, no keyboard triage, and no snooze or done. *Capture is pre-polish; the spec plans in-place expansion.* | Medium |
| M7 | New session | A lot of empty canvas. There are no recent repos, no "waiting on you" items, no host status, and no visible agent choice. "No worktree" is phrased as a negative. | Medium |
| M8 | Keyboard | No ⌘K palette and no ⌘/ shortcut sheet, and shortcuts aren't shown on buttons (Approve). `SessionCommands` covers ⌘↵, ⌘., ⌘[ ⌘] and others, but you can't discover them. | Medium |
| M9 | Light mode | Generally good. The pale "SL" avatar and the light-pink disabled Submit don't meet contrast. | Low |

### iPhone

| # | Surface | Issue | Severity |
|---|---|---|---|
| P1 | System integration | **No notifications, Live Activity, widget, App Intents or Spotlight.** The only Apple-system integration found is Mac notifications plus the Dock badge (`DesktopNotificationCenter`, `DockAttention`). On a phone, an agent supervisor is mostly used *from the Lock Screen*. | Critical |
| P2 | Conversation screen | The real capture shows a chat with a keyboard and nothing else: no "working" status line, no elapsed time, no approval-mode chip, no sub-agent access, and no way to see changes. The only sign it's running is the Stop button. | High |
| P3 | Composer on the keyboard | The composer card has heavy insets above the keyboard. The "OA Default ⌄" label uses about 40% of the control row without saying anything useful. | Medium |
| P4 | Approvals on the phone | The dock shows a full card with 3 widening chips. On a 6.1" phone, a tall dock plus the keyboard leaves almost no transcript. There's no bottom sheet, no detents, and no haptic or confirmation feedback. | High |
| P5 | Navigation | The right-panel tabs become a "Session actions" menu of sheets (spec G43). That buries Changes and Terminal. Codex puts Review in the tab bar. | Medium |

### iPad

No iPad capture was supplied, so these items are inferred from the shared adaptive layout
(`AdaptiveLayoutWidth`, `AppShell`, `DuoLayout`) and should be verified on a device.

| # | Surface | Issue | Severity |
|---|---|---|---|
| D1 | Layout | Risk that the iPad simply gets the Mac layout or a stretched phone. iPad should get the sidebar plus the conversation plus an inspector that can stay open, and full-width diffs (Cursor iPad). | Medium |
| D2 | Keyboard and pointer | Make sure `SessionCommands` show up in the iPadOS 26 menu bar and the ⌘ HUD, and that hover states work with a trackpad. | Medium |
| D3 | Windowing | iPadOS 26 resizable windows: one session per window, opened through drag-and-drop of a row (`NSUserActivity`), the same as on Mac. | Low |

---

## 3. Top 15 recommendations (ranked by impact ÷ effort)

### 1. One "needs you" state, everywhere *(both; Impact H, Effort S)*
- **What:** define one precedence in the core: Needs you > Failed > Working > Unread > Idle.
  Render it the same way in:
  - the `SessionRow` trailing slot, as a small pink "Needs you" capsule with a count when it's
    more than 1, which beats the running spinner
  - the Inbox and Needs response counts, from the same source of truth
  - the Dock badge, the menu bar extra icon, the iOS app badge and the notification badge
- **Fixes:** X1 and M3. Replace the hollow "o" with `bolt.horizontal.circle` (disconnected) and
  give every glyph a `.help` tooltip and an accessibility label.
- **Inspired by:** Claude Code agent view (state icons, Needs input first), Warp (tab state
  badge that clears on visit), Devin (Working / Ready / Blocked groups).
- **Brand fit:** pink *becomes* the "needs you" color, which is exactly what a brand accent
  should mean in a supervision tool.

### 2. Pink discipline: one pink thing per screen *(both; H, S)*
- **What:** keep pink for the "needs you" signal, the single primary action in a focused card,
  selection, and the focus ring.
- **Demote:**
  - Share to a standard toolbar button (`person.crop.circle.badge.plus`, no fill)
  - "Open approval page" to `.bordered`
  - sub-agent icons, queue icons and the context ring to secondary
- **Inspired by:** Linear and ChatGPT for Mac restraint, and Apple HIG's tint usage.
- **Brand fit:** the dark #0E0B19 canvas with a single pink focal point looks more premium and
  more "Omnigent" than pink everywhere.

### 3. Rename and re-symbol the approval-mode chip; add ⇧Tab cycling with a HUD *(both; H, S)*
- **What:** the chip shows a *state noun* and a shield, not a hand:
  - `shield` "Ask first"
  - `shield.lefthalf.filled` "Auto-edit"
  - `shield.slash` "Full access"
  - Codex's "Approve for me" becomes "Auto-approve"
- **Risk tint:** neutral, then amber, then red. On compact widths show the shield plus a
  1-word label, never a bare glyph.
- **Cycling:** ⇧Tab (spec 4.15) and ⌘⇧M (Claude desktop) cycle the mode with a brief toast
  ("Auto-edit · edits apply without asking").
- **Fixes:** X2.
- **Inspired by:** Claude Code permission modes and ⌘⇧M, Codex sandbox and approval separation.
- **Brand fit:** it keeps Omnigent's "policies and approvals" identity readable at a glance.

### 4. Label every ambiguous control *(both; M–H, S)*
- **Context tray:**
  - Host chip: `laptopcomputer` + "MacBook" + a green or hollow dot.
  - Context ring: a neutral gauge with a "62% context" tooltip and VoiceOver label.
  - Remove ↘↖ or make it "Expand editor (⌘⇧E)".
- **Queue strip:** ↑ becomes "Steer now", ✕ becomes "Remove", and show "Sends after this turn".
- **Right panel tabs:** a native segmented `Picker` with labels when there's room, and icons
  with tooltips otherwise.
- **Unknown content blocks** become a neutral chip: "Attachment · trace.json" or
  "Unsupported content · View raw".
- **Fixes:** X5, X8, X9, M5.
- **Inspired by:** Claude Code's "+12 −1" card and ChatGPT's "Work with Apps" context banner,
  which say exactly what's in context.

### 5. Bring the real Mac and iPhone apps up to playground parity, then add a "verify real app" step to every polish pass *(both; H, M)*
- **What:** wire up the header actions, context tray, mode chip and Inbox counts in the
  shipping app.
- **Mac titlebar:** use the system scroll-edge effect (or `.toolbarBackground` with a material)
  so the transcript doesn't show through.
- **Server name:** show the friendly name with a connection dot instead of "127.0.0.1".
- **Fixes:** M1.
- **Inspired by:** nothing glamorous. Every review here is moot if the capture users see looks
  like M1.

### 6. Approval card v2: payload first, one primary, an "Approve…" menu *(both; H, M)*
- **Body:**
  - Commands in an SF Mono block.
  - For edits, a file list with "+N −M" per file that expands to an inline diff.
  - For MCP or OAuth, the host and the scopes.
- **Buttons:** **Approve** (pink, labeled "⌘↵"), **Deny**, and a split-button **"Approve…"**
  menu holding the widening options. Keep the confirmation (Decision 3).
- **"Tell the agent instead…"** expands a one-line field (deny with feedback).
- **Answered state:** collapse to one line ("✓ Approved · 3 files · 2s ago").
- **Dock:** keep it (Decision 1) but limit it to a one-line summary per request that expands on
  click, with "1 of 7 ›" paging plus **"Review all"**, which opens the Inbox filtered to this
  session.
- **Fixes:** X4.
- **Inspired by:** Codex mobile (Approve / Always approve / Deny / "Tell Codex what to do"),
  Claude plan review, Claude in Chrome's "allow for this site this session".

### 7. Actionable, grouped notifications on Mac and iPhone *(both; H, M)*
- **Categories:**
  - `APPROVAL`: **Approve**, **Deny**, **Reply…** (`UNTextInputNotificationAction`). Approve
    uses `.authenticationRequired` on iPhone; widening choices only appear in the app.
  - `QUESTION`: Reply…
  - `DONE`: Open, Review changes
- **Grouping:** `threadIdentifier` = session id, so one session's alerts stack together.
- **Interruption level:** `.timeSensitive` for approvals only.
- **Settings:** a Notifications pane with per-type switches (Needs approval, Question, Turn
  finished: never / when in background / always, Errors) and a "Sub-agents roll up into the
  parent" rule.
- **Inspired by:** Codex notification settings, Claude remote control's two toggles, Devin's
  per-type push switches, Warp scoping child-agent notifications to the parent.
- **Brand fit:** this is where "approvals from any device" actually happens.

### 8. Inbox as a triage tool *(both; H, M)*
- **Layout:** cap the width at about 760pt. Rows: kind icon, then session title in semibold,
  then a one-line payload, then "waiting 12m".
- **Inline actions:** selecting a row embeds the Approval card v2 or a reply field in place.
- **Mac keys:** J/K (and ↑/↓) move, Space peeks, ⌘↵ approves, E marks done, H snoozes
  (1h / tomorrow), U toggles read.
- **iPhone swipes:** leading Approve (plain requests only), trailing Snooze and Done.
- **Empty state:** Otto with "You're all caught up".
- **Filters:** add a "Waiting on you" segment as the default.
- **Fixes:** M6, and **avoids Claude's "must attach to approve" anti-pattern**.
- **Inspired by:** Linear Inbox keys, Claude agent view's peek, Warp mailbox filters.

### 9. ⌘K command palette and quick switcher, plus a ⌘/ shortcuts sheet *(Mac, iPad; H, M)*
- **What:** one palette searches sessions (with state glyphs), commands (New session in repo…,
  Approve newest, Switch server, Toggle terminal, Change model, Change mode) and settings.
- **Results:** shortcuts on the right, recents first, and number keys for the top 9.
- **Speed:** it must open instantly. Raycast moved chat into its own process to protect palette
  latency.
- **Shortcut sheet:** ⌘/ opens a native sheet listing `SessionCommands`.
- **Fixes:** M8.
- **Inspired by:** Linear ⌘K, Raycast Root Search, Codex ⌘K, Conductor Command Palette, Claude
  desktop ⌘/.

### 10. Live sub-agent rows instead of static chips *(both; M, S–M)*
- **Each row shows:** a spinner or status glyph, the sub-agent name, the current activity
  ("Running tests…") and the elapsed time.
- **Needs you:** a sub-agent that needs you shows the pink capsule *on the parent's row*.
- **Opening:** clicking opens the child in the Agents inspector tab, so you don't leave the
  parent (↗ only for "Open in new window").
- **Collapse:** completed children fold to "2 done".
- **Inspired by:** Warp's child pill bar (resolve a blocked child from the parent), Cursor
  subagent cards, Codex Active/Done.
- **Brand fit:** sub-agents are part of Omnigent's identity, so they deserve a first-class row.

### 11. iPhone: thumb-zone supervision *(iPhone; H, M)*
- **Status line:** a one-line status above the composer ("● Working · 4m · running
  `cargo test`"), with Stop on the right and a tap to expand the current fold.
- **Approvals:** present them as a **bottom sheet with detents** (`.height(220)`, `.large`),
  not a tall dock. Haptic `.success` or `.warning` on answer.
- **Title menu:** Chat / Terminal / Changes / Files / Agents (in a `toolbarTitleMenu`).
  Changes gets a badge with the count.
- **Composer:** model chip shows the harness logo plus a short name ("Codex · High"). Long-press
  Send for "Send with…" (model/agent for this message).
- **Fixes:** P2–P5.
- **Inspired by:** Codex mobile Approve/Review tabs, ChatGPT iOS long-press Send, iOS 26
  bottom-anchored controls in Mail and Messages.

### 12. Make the agent (harness) a first-class choice *(both; M–H, M)*
- **Composer and new session:** split the model menu into an **Agent** picker (Claude Code,
  Codex, Cursor, Pi, Copilot, Antigravity, custom, each with its logo) and a model/effort
  picker scoped to that agent.
- **Never show "Default":** show the resolved name ("Claude Code · Opus · High") and dim it
  when it's inherited.
- **Remember per repo** (Claude remembers the mode per folder).
- **Inspired by:** Claude desktop's environment/mode/model row, Cursor's "pick model per
  agent", Zed's external agents as threads.
- **Brand fit:** this is *the* differentiator of a meta-harness, and the UI currently hides it.

### 13. New-session page that earns its space *(both; M, S)*
- **Below the composer:**
  - "Waiting on you (2)" cards
  - "Recent" (3 sessions)
  - Recent repos as chips
- **Context chips:** "Worktree: Off ⌄" (a toggle, like Codex), and a host chip with an online
  dot.
- **Plan first:** a "Plan first" toggle maps to plan mode.
- **Otto:** keep him small, and let him react (blink) to typing only when Reduce Motion is off.
- **Fixes:** M7.
- **Inspired by:** Claude Quick Entry (recents), Codex worktree toggle, Jules "Give me a plan".

### 14. Terminals as real tabs *(Mac, iPad; M, S)*
- **Tab strip:** replace the list-over-terminal with a tab strip on the terminal surface. Show
  "claude (agent)", then cwd-based names ("zsh — client-core"), plus status dots. The agent TUI
  is pinned first.
- **Takeover banner:** when you type into the agent's TUI, show "You're controlling the agent
  terminal · Hand back".
- **Shortcut:** Ctrl+` toggles the terminal.
- **Inspired by:** cmux (branch, PR, cwd and ports in the tab metadata, plus attention rings),
  Codex per-chat terminal, Claude desktop Ctrl+`.

### 15. Turn-end change card and a phone diff reader *(both; H, L)*
- **Change card:** every turn that edits files ends with a card: "3 files · +38 −12 · Review".
- **Mac Changes tab:**
  - a scope picker (This turn / Uncommitted / Branch / PR)
  - per-hunk comments that **go to the agent right away** (⌘↵ submits all), and per-hunk revert
- **iPhone:** a file list, then a full-screen unified diff with word-level highlights. Swipe
  between files, long-press a line to comment.
- **iPad:** a full-width split diff.
- **Inspired by:** Claude desktop diff comments, Codex "Last turn" scope, Zed per-hunk review,
  Devin word-level highlights, Cursor iPad full-width diffs. **Avoid:** Codex holding comments
  until the next message.

---

## 4. Bigger bets

1. **"Agents" Live Activity, Dynamic Island, and the Mac menu bar for free.**
   - **What it is:** a single Live Activity summarizing the user's running sessions on a server:
     "3 working · 1 needs you", with the top session's current step and elapsed time.
   - **How it works:** the server starts and updates it via ActivityKit push-to-start and
     pushes. The expanded view has one App Intent button, "Review" (open the app). Plain
     approve stays a notification action that requires authentication.
   - **Bonus:** with macOS Tahoe, iPhone Live Activities show in the Mac menu bar, so users
     away from their main Mac still see it.
   - **Related:** a Lock Screen and Home Screen widget ("Needs you: 2"), and a Control Center
     control "New Omnigent session".
   - **Rationale:** Cursor already tracks 8 agents this way. For a product whose pitch is
     "collaborate on the same live session from any device", this is the most visible proof.
   - **Guardrail:** keep commands and paths off the Lock Screen, and show titles only.

2. **Mission Control: turn Canvas into a state board.**
   - **What it is:** make Canvas's default layout a board with columns **Needs you / Working /
     Ready for review / Done**, with cards showing live activity, diff stat, PR checks and
     viewers. Keep freeform as an option.
   - **Keyboard:** J/K and Space peek (approve or reply inline), Enter opens. On Mac, also
     offer it as a separate window ("Mission Control", ⌘⇧0) for a second monitor.
   - **iPad:** this becomes the home screen.
   - **Rationale:** Claude agent view, GitHub Mission Control, Devin's grouped sidebar, Factory
     Missions and Vibe Kanban all point here. A freeform canvas of cards is a weaker answer to
     "what needs me?". This also lets you retire the Running and Needs response nav rows
     later, without breaking Decision 3's filters.

3. **Continuity: Handoff, Spotlight, App Intents, QR pairing.**
   - **Handoff:** an `NSUserActivity` per session, so a session open on iPhone appears in the
     Mac Dock and vice versa.
   - **Spotlight:** index session titles and summaries with `CSSearchableItem`.
   - **App Intents** (for Shortcuts, Siri and Spotlight actions): "Start session in repo…",
     "What needs me?", "Approve newest request" (with confirmation).
   - **Pairing:** pair the phone with a server by scanning a QR code shown in Mac Settings,
     like Codex Remote.
   - **Rationale:** these are native-only advantages the web app can't match, and they
     reinforce the multi-device story without new UI chrome.

4. **Review mode as a destination.**
   - **What it is:** a full-window review surface per session (Mac and iPad): a file tree,
     split or unified diff, comments that go to the agent, checks, and Merge, Auto-fix and
     "Watch and fix".
   - **iPad:** Pencil markup on screenshots and previews that is sent to the agent.
   - **Rationale:** Codex, Claude desktop, Conductor and GitHub all treat review as the second
     half of agent work. Omnigent's PR tab is today a list.

5. **Trusted agent browsing.**
   - **What it is:** in the embedded Chromium pane, show a visible agent cursor and a
     "Agent is browsing · Take over" banner. Use a per-session tab group and a clean profile
     per session (no personal cookies).
   - **Approvals:** per-site prompts ("Allow on github.com for this session"). Pause on login
     and CAPTCHA pages for the human.
   - **Rationale:** Codex Computer Use's cursor is the most praised part of that app. Claude in
     Chrome's tab groups and site prompts set the expectation for consent.

---

## 5. What not to copy

- **Claude agent view's "attach to answer a permission prompt".** If Omnigent shows a request
  in a list, notification or Live Activity, plain approvals must be answerable right there.
  Widening approvals keep the confirmation (Decision 3).
- **Codex holding diff comments until the next message.** Comments should reach the agent when
  you submit them.
- **Remote control that dies when the laptop sleeps** (Codex, Cursor and Claude remote control
  all depend on it). Omnigent's server model avoids this, so don't build phone features that
  assume a desktop is awake.
- **A read-only sub-agent view** (Codex). You should be able to answer a blocked child from the
  parent.
- **Floating mascots or "pets" as status UI** (Codex pet). Otto belongs in empty states and
  onboarding. Status belongs in the menu bar extra, the Dock badge and the Live Activity, which
  are native and don't cover content.
- **In-window toast stacks** (Warp). On Apple platforms, use system notifications. Inside the
  window, show one banner only for *another* session that needs you.
- **Surface sprawl and churn** (Cursor deprecating Editor worktrees and best-of-n within one
  release). Omnigent already has Inbox, Canvas, Running and Needs response for overlapping
  jobs. Merge before adding more.
- **Marketing model names and "Default"** in the composer (the ChatGPT model menu history).
  Show the resolved agent and model.
- **Rich controls or sensitive text in Live Activities** (Apple HIG). Commands can contain
  secrets.
- **Running the agent browser in the user's real profile** (Claude in Chrome). Use a clean
  per-session profile.
- **Web idioms in a native app:** hover-only actions, dashed placeholder boxes, custom
  segmented controls, filled pill buttons in the toolbar, full-width list rows on wide windows,
  and custom scrollbars. Use `Picker(.segmented)`, toolbar items, `List` selection, context
  menus and system materials.
- **One-click permission widening** (as on the web). Keep the native confirmation.
