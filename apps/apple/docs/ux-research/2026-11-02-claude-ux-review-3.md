# Omnigent native apps: UI/UX review 3 (Claude)

Reviewer: Claude (independent review). Date: 2026-11-02.

Inputs:
- **Real app, this pass:** iPhone 17 Pro, iPad Pro 13" (M5) and iPhone Duo simulators running a
  Debug build of this worktree from 2026-11-01 23:26–23:44 (another session's derived data; a fresh
  build was too slow on the loaded host) with `-OmnigentDemo`, and the Mac App Store edition of the
  same build launched with `-OmnigentDemo` and captured window-only (`screencapture -l`).
- **Real app, earlier today (reused):** `parity-*`, `tabs2-*`, `fork-*`, `rb-*`, `cli-*` and `duo-*`
  captures in `/private/tmp/claude-502/`.
- **Gallery export:** `OmnigentPlayground --export-gallery` for `mac,iPhone,iPadPro13-landscape,duo`,
  light and dark. The full catalog is 1,028 images at about 1 s each on this (heavily loaded) host,
  so I kept the first 107 (design system and transcript components) and exported every page
  (`--gallery-filter pages`, 246 images).
- **Code:** `OmnigentUIComponents` (design tokens, transcript, markdown, composer, tabs, sidebar),
  `OmnigentAppUI` and the app targets.
- **Competitor research:** public pages fetched on 2026-11-01 and 2026-11-02. Claims marked
  *[unverified]* rest on a search summary only.

Measurements are in points unless marked px. Contrast ratios were sampled from the captures with a
WCAG 2.x luminance script (darkest glyph pixel against the dominant background in the box).

## The short version

Phases 1 and 2 landed well. The titlebar tab strip, split view, the CLI style and the compact
iPhone composer are the right moves, and today's captures look calmer than review 2's. What is left
is mostly **finish**, and most of it is cheap:

1. **The type scale is upside down in places.** On the Mac, markdown `###` renders at 13 pt and
   `####` at 11 pt under 15 pt body text, because headings use system text styles while prose uses a
   custom size. Seven text sizes plus fixed 7, 8 and 9 pt glyphs are in use.
2. **Some states are hard to read.** The selected sidebar row on iPad and iPhone draws **white text
   on a pale pink fill (1.34:1)**, and the sidebar section headers are 1.7:1.
3. **Short conversations on iPhone sit at the bottom of the screen.** The bottom scroll anchor leaves
   a 110–150 pt empty band under the navigation bar and drops the large title into the middle of the
   screen. It is the first thing a user sees after sending a first message.
4. **Phone controls are cramped where there is room, and roomy where there is none.** The model chip
   is capped at 96 pt ("Sam…lanced") next to ~170 pt of empty bar. Code and diffs use 16 pt
   monospace and clip after about 25 characters on iPhone.
5. **Phase 3 hasn't started.** There are no notification actions, Live Activities, widgets, App
   Intents, Spotlight or Handoff anywhere in the code. The competitor bar moved again: GitHub,
   Cursor and Codex all control local agents from the phone now.

Performance is in good shape when nothing runs: the iPhone and iPad simulators sit at 0.0% CPU
with an approval-blocked conversation open, and a 3,000-row transcript settles to 0.0% after about
1.8 s of first layout (Debug). **A session that is working costs 13–15% of a core even when no new
output arrives**, all of it SwiftUI redrawing the looping "working" indicators every frame. The
other risks are per-token work in the transcript's `body` (an `.equatable()` check that compares
whole row arrays is 11% of the 3,000-row launch) and offset-keyed `ForEach`es (section 4).

---

## 1. Competitor findings (new since review 2)

Review 2's table ([2026-11-01-claude-ux-review.md](2026-11-01-claude-ux-review.md)) still stands.
These are the additions and changes.

**Changed since review 2:**
- The ChatGPT agent is "no longer available"; ChatGPT Work replaces it
  ([help](https://help.openai.com/en/articles/11752874-chatgpt-agent)).
- ChatGPT Atlas "has been retired and no longer receives updates"
  ([help](https://help.openai.com/en/articles/20001371-chatgpt-atlas-retirement)).
- Arc closes new accounts on Oct 22, ends sync on Nov 23 and ends the desktop app on
  Dec 22, 2026 ([arc.net](https://arc.net/)).
- Claude merged Chat and Cowork, and "branching a conversation from an earlier point isn't
  available" there ([support](https://support.claude.com/en/articles/16761823-claude-cowork-and-chat-are-one-claude)).

Lesson: don't bind the agent-browsing design to any one vendor's surface. Omnigent's fork chat is
now a differentiator against Claude.

| Product | Platform | Pattern worth borrowing | Source |
|---|---|---|---|
| Warp vertical tabs | Mac | "View as" Panes (one row per split pane) or Tabs. "Density" Compact (default) or Expanded. "Pane title as" Command / Working Directory / Branch. A search field filters tabs and panes. | https://docs.warp.dev/terminal/windows/vertical-tabs |
| Warp pane status | Mac | Per-pane agent badge: in progress, done, error, cancelled, blocked, with the Claude Code / Codex / Gemini CLI brand icon. The dot clears on focus. **Hover a row for a detail card** without moving focus. | same |
| Warp tabs, editing | Mac | Drag a pane header onto another tab group to move it; drop between groups for a new tab. Double-click a row to rename inline (Enter / Esc). | same |
| Warp blocks | Mac | Cloud-agent command exits are matched to the block where the command started. Unattended runs end as **"blocked"** when they need input. Inline Markdown tables and Mermaid in agent output. | https://docs.warp.dev/changelog/2026/ |
| Dia | Mac | Arc-style pinned tabs; a "Close Tabs in One Click" sidebar button for unpinned tabs; an Active Tab Indicator; ⌘⇧D pins a tab; the tab switcher was cut from 10 tabs to 5 ("Simpler Tab Switching"). | https://www.diabrowser.com/changelog |
| Dia | Mac / Windows | **Focus Mode** hides the sidebar or top tabs and works with split view. "Smoother Sidebar and Splitview Transitions" keep web content in place. Queue and steering controls. | same |
| Dia split view | Mac | Drag a tab to the screen edge to split; "No menus, no keyboard shortcuts to memorize." | https://www.diabrowser.com/release-notes/1-25-0-details-that-delight |
| Safari tabs | Mac | Separate vs Compact tab layout ("the active tab is the Smart Search field"). ⌘1–⌘9 switch tabs. Auto-close after a day / week / month. "Organize tabs" with automatic Topics. | https://support.apple.com/guide/safari/tabs-ibrw1045/mac |
| iOS 26 tab bar | iPhone | "When users scroll, tab bars shrink to bring focus to the content", and re-expand on scroll up. Controls float as a Liquid Glass layer. | https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/ |
| Claude desktop (Code) | Mac | Titlebar pane buttons (Terminal, Changes, Browser, Files) with overflow in "⋮". **Option-click opens a second session beside the first**; ⌘⌃W takes a session out of split; panes pop out into windows. | https://code.claude.com/docs/en/desktop |
| Claude desktop transcript | Mac | Transcript view modes cycled with **Ctrl+O**: Normal (tool calls collapsed into summaries), Thinking, Verbose (every tool call and read). | same |
| Claude desktop details | Mac | A session rail you can hide; a details panel with cards for environment, changes, running tasks and **context usage**; "Group and sort" for the sidebar. | same |
| Claude Remote Control | iPhone | QR code from the CLI (spacebar). "Claude Code reconnects automatically when your machine comes back online." Spawn modes same-dir / worktree / session. | https://code.claude.com/docs/en/remote-control |
| Claude Dispatch | iPhone → Mac | Send a task from the phone; push "when a session finishes or needs approval". | https://code.claude.com/docs/en/desktop |
| Claude computer use | Mac | Notification "Claude is using your computer · press Esc to stop". Per-app Allow for this session / Deny; terminals warned as "Equivalent to shell access". | https://code.claude.com/docs/en/computer-use |
| Claude in Chrome | Chrome | Pauses on login pages and CAPTCHAs for the human; agent tabs go in a per-session tab group; a visible Chrome window. | https://code.claude.com/docs/en/chrome |
| Claude drafts | All | "Edit Claude's drafts in place": drafts open beside the conversation for targeted edits. | https://support.claude.com/en/articles/12138966-release-notes |
| Codex in ChatGPT iOS | iPhone | Reaches chats on a paired Mac/Windows host via QR; start chats, steer active work, approve commands, review diffs, terminal output and screenshots; switch hosts. **"Sessions drop if the host sleeps."** | https://learn.chatgpt.com/docs/remote-connections |
| Codex app | Mac | Composer predictions: "Press Tab to accept" a suggested next message (beta). | https://help.openai.com/en/articles/6825453-chatgpt-release-notes |
| ChatGPT | iPhone / Mac | A Chat / Work toggle above the composer; Quick chat next to New chat. Locked chats (PIN or device auth); two signed-in accounts on iOS. | https://learn.chatgpt.com/docs/app , release notes above |
| ChatGPT branching | Web / iOS | "Branch in new chat" from ⋯ on web; long-press a message on mobile for Branch or Edit. *[unverified]* | release notes above |
| ChatGPT cloud browser | Web | Takeover from the "…" menu; on login the agent "will pause and prompt you to take control"; credentials typed during takeover "are not visible to the model." | https://help.openai.com/en/articles/20001280-using-cloud-browser-in-chatgpt |
| Atlas (retired) | Mac | A per-site "ChatGPT page visibility" toggle in the address bar (Allowed / Not Allowed); logged-out mode. | https://openai.com/index/introducing-chatgpt-atlas/ |
| Perplexity Comet | Mac / Win | A three-way agent consent: browse yourself / let Comet browse **once** / let it browse automatically. Steps show live or in an "Assistant sidecar". | https://www.perplexity.ai/hub/blog/comet-assistant-puts-you-in-control |
| Comet iOS | iPhone / iPad | "Search results remember their place", "Omni-box adapts to the page", a polished iPad sidebar. | https://9to5mac.com/2026/05/21/perplexitys-comet-ai-browser-for-ios-upgraded-with-8-major-improvements/ |
| Cursor | Desktop | **Enter queues while the agent works** (queued items listed below the active task, drag to reorder); ⌘Enter sends now. On the web, Tab queues and "Send now" steers at the next tool call. Checkpoint restore keeps messages. | https://cursor.com/docs/agent/overview |
| Cursor iOS | iPhone | Remote control of **local** agents (Oct 6, 2026), with a "Keep this computer awake" toggle. | https://cursor.com/changelog |
| GitHub Copilot sessions | Web / mobile | Delegated sub-agent activity is "collapsed by default, with a heads-up display showing what it's working on right now". Setup steps show start and finish. | https://github.blog/changelog/2026-03-19-more-visibility-into-copilot-coding-agent-sessions/ |
| GitHub Copilot CLI remote | Mobile / web | Steer mid-session "or queue the next message as soon as the current step finishes"; approve or deny; QR to connect; live streaming. | https://github.blog/changelog/2026-05-18-remote-control-for-copilot-cli-sessions-now-generally-available-on-mobile-web-and-vs-code/ |
| GitHub assisted permissions | All | Modes manual / **assisted** / allow-all. A model auto-approves "clearly safe" requests; admins can block Allow All but keep Assisted. | https://github.blog/changelog/2026-10-26-github-copilot-assisted-permissions-generally-available/ |
| Zed | Mac | Terminal tabs can be dragged into the Agent Panel; queued messages in the panel (Oct 28); a change accordion above the composer; Follow mode. | https://zed.dev/releases/stable , https://zed.dev/docs/ai/agent-panel |
| Linear display options | Mac / web | Per-view display options (⇧V) with "Set as default" and "Reset to default"; ⌘B list/board; "Show empty groups". | https://linear.app/docs/display-options |
| Linear refresh | Mac / web | "Smaller icon-only tabs", a sidebar "a few notches dimmer", fewer separators, warmer less-saturated grays. | https://linear.app/now/behind-the-latest-design-refresh |
| Raycast | Mac | Page Up / Page Down in lists and grids; exact-pixel window sizing. | https://www.raycast.com/changelog |

**Takeaways for Omnigent**

1. **A row per pane, with state, unread and hover detail** (Warp, Dia). Our strip already has
   state dots. Add the hover detail card, and on iPhone the same state in the Tabs list.
2. **Transcript density is a named, cycled mode** (Claude's Ctrl+O Normal / Thinking / Verbose;
   Copilot's collapsed sub-agent HUD). Our Plain / Styled / Rich is about *rendering*; we still lack
   a *verbosity* control.
3. **Queue and steer are both first-class with distinct keys** (Cursor, Copilot, Zed, Dia). This
   matches our roadmap item 10; Cursor's drag-to-reorder queue is the bar.
4. **Remote control of local agents from the phone is now table stakes** (Claude, Codex, Cursor,
   GitHub), and every one of them pairs with a QR code. The ones that drop sessions when the host
   sleeps are criticized for it; Claude reconnects automatically.
5. **Agent browsing pauses for login and CAPTCHA, and the human's credentials never reach the
   model** (Claude in Chrome, the ChatGPT cloud browser). Comet's "once / always" consent is a good,
   simple model for per-site permission.
6. **Density is per view and reversible** (Linear "Set as default / Reset", Warp Compact/Expanded,
   Dia Focus Mode). No vendor publishes row heights or type scales, so our own token audit matters
   more than copying numbers.

---

## 2. Roadmap status since review 2

Checked against the code on 2026-11-02 (`grep` across `Apps/` and `Packages/`).

| Roadmap item | Status | Evidence |
|---|---|---|
| 1. One "needs you" signal | **Done** (mostly) | Sidebar "Needs you 2" capsule, row capsules, tab dots, header line "Waiting for you · 1 request". The iPhone Tabs list has no state yet. |
| 2. Emphasis discipline | **Done** | Pink only on Approve, Send and Needs-you in today's captures. Selection fill still uses the accent (see F2). |
| 3. Approval-mode chip | **Done** | "Ask first / Auto-edit / Full access", ⇧Tab handling in `ComposerView.swift:210`. |
| 4. Agent-first configuration | **Partly** | Agent · model chip. The iPhone bar truncates it to 96 pt (F6). |
| 5. Execution context row | **Done** | `ExecutionContextRow`. The iPhone new-session page shows the host twice (F12). |
| 6. Label ambiguous controls | **Partly** | The fork glyph (`arrow.triangle.branch`) reads as a "Y" at 12 pt (F15). |
| 7. Approval card v2 | **Done** | Payload first, Approve / Reject, "Tell the agent instead". |
| 8. Dock compact/expanded | **Done** | The dock repeats the inline card's choices on iPad (F13). |
| 9. Inbox triage | **Done** | J/K/E and arrows in `InboxView.swift:43`. |
| 10. Queue / steer / stop | **Done** | "Send now · steer", "Queue", filled Stop. |
| 11. Live sub-agent groups | **Done** | `SubagentGroupView`, elapsed via `TimelineView`. |
| 12. iPhone reading posture | **Partly** | Keyboard hidden on open, Jump to latest. Short transcripts float to the bottom (F1). |
| 13. ⌘K and ⌘/ | **Done** | `PaletteCommands`, shortcuts sheet. |
| 14. Workspace and terminal navigation | **Done** | Terminals are tabs in the strip. |
| 15. Real-app parity | **Done**, with gaps | Mac connect screen ignores the theme and shows `127.0.0.1` (F9). |
| 16–18. Notifications, Live Activity, widgets, continuity | **Not started** | No `ActivityKit`, `UNNotificationAction`, `AppIntents`, `CoreSpotlight`, `NSUserActivity` or `WidgetKit` anywhere; iOS has no `UNUserNotificationCenter` at all. |
| 19–22. Mission Control, review mode, goals, trusted browsing | **Started: browsing** | The remote browser tab has "Agent is browsing · Take Over". The rest is not started. |

---

## 3. Fit and finish

Severity: **High** (a user notices it in the first minute or it fails accessibility), **Medium**,
**Low**.

### 3.1 Type scale

What the code sets today (`DesignSystem/Theme.swift`, `Markdown/MarkdownView.swift:97`):

| Role | Mac | iOS | Source |
|---|---|---|---|
| Prose body | 15 / 23 line height (measured 23.9) | 17 / 25 (measured 25.3) | `Typography.proseSize` + `leading = 5` |
| Markdown H1 | `.title` 22 semibold | 28 semibold | `headingFont(1)` |
| Markdown H2 | `.title2` 17 semibold | 22 semibold | `Typography.title` |
| Markdown H3 | `.headline` **13** bold | 17 semibold | `headingFont(3)` |
| Markdown H4+ | `.subheadline` **11** semibold | **15** semibold | `headingFont(default)` |
| Code blocks, diffs, file lists | `.callout` mono 12 | `.callout` mono **16** | `Typography.code` |
| Tab titles | `.callout` 12 | 16 | `TabItemView.swift:51` |
| Captions (timestamps, labels) | `.caption` 10 | 12 | 175 call sites |
| Fixed sizes | 7, 8, 9, 10, 11, 12, 13 pt | same (they don't scale) | 17 `.system(size:)` call sites |

| # | Finding | Severity |
|---|---|---|
| T1 | **H3 and H4 are smaller than body text on the Mac** (13 and 11 pt under 15 pt), and H4 is smaller than body on iOS (15 under 17). Headings read as captions. Tie heading sizes to `proseSize`: H1 ×1.4, H2 ×1.2, H3 ×1.07 semibold, H4 = body semibold. | High |
| T2 | **Headings don't group with their content.** Every markdown block is separated by 16 pt (`Spacing.paragraph`), and headings add only 4–8 pt on top. Use 24 pt above H1/H2, 16 above H3, and 6–8 pt below every heading. | Medium |
| T3 | **16 pt monospace on iPhone is too big for code.** The diff in the approval card clips at about 25 characters per line (iPhone 17 Pro, `iphone-approval-light.png`), and file paths truncate to "…ttentionSection.swift". ChatGPT and Claude iOS use a smaller code face than body. Use `.footnote` mono (13 pt, scaled) on compact width, with horizontal scrolling and a wrap toggle. | High |
| T4 | **Two families in one card.** The approval card lists files in mono, but the diff header's file name is proportional (`Omni/iOS/SessionRow.swift`, `caption`). Pick one: mono for paths everywhere, or proportional with a mono tail. | Low |
| T5 | **Fixed 7–9 pt glyphs don't scale and are below Apple's minimum.** `SessionInspectorView.swift:273` (7 pt), `SessionHeaderView.swift:146` (8 pt), `TabItemView.swift:108` (the tab close × at 9 pt), `FileTreeView.swift:129` and `DiffRows.swift:87` (9 pt). Use `.caption2` with `imageScale(.small)`, or `@ScaledMetric`. | Medium |
| T6 | **Too many sizes.** Mac chrome mixes 10, 11, 12, 13 and 15 pt; iOS mixes 12, 13, 15, 16 and 17. Define named roles (`Typography.meta`, `.label`, `.body`, `.code`, `.title`) and route the 175 `.caption` and 101 `.callout` call sites through them. | Medium |
| T7 | **The iOS large-title subtitle is tiny.** "Finished" under a 34 pt title is 12–13 pt grey, and in short conversations it sits mid-screen (F1). Use `.subheadline` and the header status line ("Finished · 2 files changed") as the subtitle. | Low |
| T8 | **Inline code is bigger than code blocks.** Inline spans use `inlinePresentationIntent = .code` (`MarkdownDocument.swift:163`), so they render in SF Mono at the full body size (15 pt Mac, 17 pt iOS), while code blocks use `.callout` mono (12 pt Mac, 16 pt iOS). SF Mono at body size also reads larger and wider than the SF text around it (gallery `components.transcript.message--assistant`). Render inline code at about 0.9 × body and add 2–3 pt of horizontal padding inside the tinted background. | Medium |

### 3.2 Spacing and grid

| # | Finding | Severity |
|---|---|---|
| S1 | **About a third of padding literals are off the 4 pt grid.** Of ~170 `.padding(_:)` literals in `Packages/`: 20× 10, 11× 6, 9× 5, 5× 3, 5× 14, 4× 7, 2× 18, plus 2.5 and 1.5. Also `Spacing.small + 2` for tab padding (`TabItemView.swift:71`), list markers at 22/12 pt (`MarkdownView.swift:115`), `FlowLayout` spacing 6 (`MessageViews.swift:272`), and corner radii of 4, 5, 6, 7, 10, 12, 14 and 36 alongside the tokens 8/16/20/24. `Theme.Radius.small` and `.medium` are both 8. | Medium |
| S2 | **Compact gutters are tighter than iOS margins.** Chat uses 12 pt (`Spacing.compactGutter`) and CLI 10 pt (`CLIMetrics.compactGutter`) on iPhone; the system readable margin on an iPhone 17 Pro is 16–20 pt. Text at 12 pt from the edge also sits closer to the edge than the 16 pt composer inset below it. Use 16 for both. | Medium |
| S3 | **Mac reserves an empty 28 pt action row under every message** (`MessageActionRow.swift:76–84`), on top of the 24 pt turn spacing. User-bubble-to-reply gaps measure about 55 pt and reply-to-next-bubble about 38 pt plus the reserved row. Overlay the hover actions instead (they already avoid reflow) and drop turn spacing to 20. | Medium |
| S4 | **CLI blocks use 14 pt gaps and 14 pt band padding** (`CLIMetrics.blockGap`, `bandPadding`). That is one line of 13 pt mono, but off-grid; 12 or 16 lines up with everything else. | Low |
| S5 | **The server name floats away from its status dot.** `SidebarParts.swift:51–53` gives the name `.frame(maxWidth: 130)` with the default centre alignment, so short names ("Offline demo", "This Mac") sit about 35 pt from the dot (`iphone-sessions-light.png`). Add `alignment: .trailing` or `fixedSize()`. | Low |

### 3.3 Contrast (measured)

| Where | Foreground on background | Ratio | Needs | Severity |
|---|---|---|---|---|
| iPad sidebar, selected row title | `#FFFFFF` on `#E5DCE6` | **1.34** | 4.5 | **High** |
| iPad and iPhone sidebar section headers ("Pinned", "Sessions") | `#B3B5BA` on `#E6EAEE`; `#C4C4C6` on white | **1.70 / 1.74** | 4.5 (3 for large) | High |
| Server status "Offline demo" | `#808488` on `#E6EAEE` | 3.12 | 4.5 | Medium |
| Composer placeholder "Reply…" (iPad) | `#858588` on `#F4F4F4` | 3.35 | 4.5 (placeholder: 3 is common) | Low |
| Dock harness line "Codex" | `#858589` on `#F6F6F6` | 3.40 | 4.5 | Low |
| Row relative time "2y" | `#7F7F7F` on white | 4.00 | 4.5 | Low |
| "Needs you" capsule text, light (iPhone) | `#DF3C85` on `#FAE2ED` | **3.35** | 4.5 | High |
| "Needs you 2" count, light | `#DF3C85` on `#F2F2F2` | 3.66 | 4.5 | Medium |
| Approve label, white on pink (17 pt regular) | `#FFFFFF` on `#DF3C85` | 4.10 | 4.5 | Medium |
| Mac dark: selected row, section header, time | | 15.3 / 7.3 / 7.2 | 4.5 | OK |

The last four rows were measured after Astra's first pass flagged the light-theme pink; the
measurement confirms its token calculation. The fix is a darker "needs you" foreground for light
themes (around `#B8236A` passes 4.5:1 on the capsule) while the fill keeps the brand pink.

- **F2: the selected sidebar row (High).** `SidebarSelection.swift` replaces the list row background
  with the theme's 8% accent fill on iOS, but the system still treats the row as selected and draws
  its label in white. The Mac path already removes the system highlight; the iOS path needs the
  same, or a selection fill dark enough for white text. Today the selected session is the hardest
  row to read.
- **Section headers** use a tertiary style. Use `.secondary`, which is 3.4:1 and fine at this size
  and weight, or `.secondary` + semibold.

### 3.4 Layout bugs seen in the real app

| # | Screen | Finding | Severity |
|---|---|---|---|
| F1 | iPhone, any short conversation | **Short transcripts float to the bottom.** The likely cause: `TranscriptView.swift:107` uses `.defaultScrollAnchor(.bottom, for: .initialOffset)`. With one or two messages the content hugs the composer, leaving a 110–150 pt blank band under the toolbar, and the large title ("Project notes", "New conversation") lands mid-screen (`iphone-readonly-short.png`, `iphone-short-conversation.png`). Anchor at the top until the content is taller than the viewport (ChatGPT, Messages). | **High** |
| F3 | iPhone conversation | **Orphan copy buttons.** A copy icon floats under the navigation bar with no message visible (`iphone-approval-light.png`, `parity-iphone-dark.png`): it belongs to a message scrolled away. On touch the persistent copy row is noise; put Copy in the long-press menu (it is already there) and drop the always-visible icon. | Medium |
| F4 | iPhone new-session page | **The composer floats in the middle of the screen**, about 60 pt above the keyboard while typing and centred with the mascot when idle (`iphone-new-session-typing.png`). Pin the composer to the keyboard and let the mascot and heading move up, as ChatGPT does. | Medium |
| F5 | iPhone read-only session | **The composer says you can't send but still offers "+ Reply…".** Replace the field with a single "Read only · Fork to continue" row. | Medium |
| F6 | iPhone composer | **The agent and model chip is capped at 96 pt** (`ComposerBarMetrics.modelWidth`, `ComposerCompactBar.swift:40`) and middle-truncates to "Sam…lanced" next to ~170 pt of empty bar. Let it take the free width (`layoutPriority`, `ViewThatFits`), truncate the tail, and drop the agent name before the model. | Medium |
| F7 | iPad split | **The right pane's first tab is clipped at its leading edge** ("e first r…" in `ipad-launch.png`); this is the known narrow-section follow-up. Scroll the selected tab fully into view and fade the edge. | Medium |
| F8 | iPad tab strip | **The tab close button is 16 × 16 pt** (`TabItemView.swift:107–110`) on touch; Apple's minimum is 44. Give it a 44 pt `contentShape`, or show it only on the selected tab with a 28 pt hit area plus long-press "Close". | High |
| F9 | Mac Connect window | **It ignores the theme and the naming rule.** The window uses the system grey canvas instead of the theme's, and "Recent servers" lists `127.0.0.1:6895` as both title and subtitle (`mac-demo-a.png`); `verify-real-app.md` says loopback servers read "This Mac". Two identical Connect windows opened on launch. | Medium |
| F10 | Mac / Duo demo | **`-OmnigentDemo` opens the Connect screen** on the Mac and the folded Duo when no server is bound, while iPhone and iPad open the demo. A demo flag that needs a URL typed is a trap for reviewers and tests. | Low |
| F11 | iPhone Tabs list | **Subtitles show raw agent ids** ("tabs_fixture_agent", "fixture_agent"), not display names; rows show no state (needs you, running); "+" and "Done" share one glass capsule with a wide gap (`parity-iphone-tabs-dark.png`). | Medium |
| F12 | iPhone new session | **The host appears twice**: in the context row ("Sample Codex · Offline demo host ●") and again as a laptop + dot in the composer. Keep one. | Low |
| F13 | iPad / iPhone with a question | **The dock repeats the inline card's buttons.** On iPad the right pane shows "Sessions and chat / Approvals first" twice, one above the other (`ipad-launch.png`). Decision 1 keeps both surfaces; when the inline card is on screen, collapse the dock to a one-line "1 request · Show" summary. | Medium |
| F14 | Mac remote browser | **Letterboxing.** The remote page is drawn with ~75 pt dark bands above and below (`rb-mac-agent-owns.png`); the "default" profile label at the top right is cryptic. Size the remote viewport to the pane, and label the profile "Profile: Default". | Medium |
| F15 | Mac hover actions | **The fork glyph reads as a "Y"** at caption size (`fork-mac-hover.png`). Use `arrow.triangle.branch` at `.body` scale with a tooltip, or `square.on.square.dashed`-style "Fork" text on hover. | Low |
| F16 | Empty states | **Three different empty-state voices.** New session: "What should we build?"; an empty chat: "What should we work on?" plus "Lifecycle details are in the inspector." (`TranscriptBanners.swift:23–27`, `tabs2-mac-split.png`). The second line is internal language. Use one heading, and a useful second line ("Send a message to start, or pick an agent below"). | Low |
| F17 | iOS sidebar | **No visible way to Settings or Appearance on iPhone**: they live inside the server menu ("Offline demo ▾"). There is also a 110 pt empty band above the "Omnigent" header (`iphone-sessions-light.png`). Add a toolbar gear (or account avatar) and let the list start under the status bar. | Medium |
| F18 | Approval card on iPhone and Duo | Approve and Reject are 50 pt pills side by side at the left; "Tell the agent instead" is not visible in the inline card on the phone. Put the three actions in a full-width stack on compact width, Approve first. | Low |
| F19 | Transcript states (gallery, all devices) | **Two review-2 items are still open.** A user message with unknown content still shows the dashed "? Message content" box (review 2 X8), and "Working…", "Interrupted" (a radio-dot) and "Responding" (a grey dot under the text) still sit at three different indents with three different glyphs (X7) (`pages.transcript.conversation--streaming--*`). | Medium |
| F20 | Gallery vs real iPad | The gallery's iPad pages draw an inline navigation title and no titlebar tab strip, while the real iPad app shows the strip (`ipad-launch.png`). Pages reviewed only in the gallery miss the strip's layout cost on iPad. | Low |

### 3.5 Consistency

- **Chat vs CLI.** The CLI composer has no host chip, and its status line repeats the configuration
  pickers (known follow-up). CLI hangs its `›` and `•` markers 6 pt from the edge on iPhone, while
  chat text starts at 12 pt; a single 16 pt gutter would align both styles with the composer.
- **Selection.** Mac selection is the softened accent with the primary label color, iOS is the
  softened accent with white text (F2), and the iPhone Tabs list uses a checkmark. Use a fill plus
  primary text on every platform.
- **Counts.** "Inbox 2" is plain grey; "Needs you 2" is a pink capsule. Good per the "pink only for
  needs you" rule, but the two counts sit in adjacent rows with different alignment and size.
- **Titles.** "New conversation" (iPhone after first send) vs the first-message title the Mac shows
  in tabs. Derive the title the same way on every platform.
- **Light/dark parity.** Dark is the stronger theme. In light, the user bubble (`#F0F0F0`-ish on
  white) and the card surfaces barely separate from the canvas; the approval card relies on a 1 px
  border. Add 2–3% more fill to light surfaces, matching the dark theme's 6% lift.

---

## 4. Performance

### Measured

| Scenario | Result |
|---|---|
| iPhone 17 Pro simulator, demo, approval-blocked conversation open, 15 s idle | **0.0% CPU**, 336 MB RSS (Debug) |
| iPad Pro 13" simulator, demo, split of two conversations, idle | **0.0% CPU**, 314 MB RSS |
| iPhone, sending a message (demo reply) | 24–29% for ~2 s, back to 0.0% within 3 s |
| Mac App Store edition, Connect screen, idle | 0.0% CPU, 106 MB RSS |
| iPhone cold launch to first stable frame (Debug, busy host, load average 26) | ≈ 6.7 s; `simctl launch` returned at 1.2 s. Not representative; re-measure on an idle machine with `xctrace` App Launch. |

| Mac playground, Long Transcript (3,000 rows), Debug, `xctrace` Time Profiler from launch | Main thread busy for **≈1.8 s** after the window appears, then idle; one **254 ms microhang** at 2.6 s. Idle afterwards: **0.0% CPU**, 165 MB RSS. |
| Same profile, app frames | `TurnSegment ==` (the `.equatable()` check on every segment, which compares whole row arrays): **≈11%** of main-thread samples. `TranscriptView.segments(for:)`: ≈5%. The rest is SwiftUI/AppKit layout of the first screen. |
| Mac playground, Streaming Turn, **idle** (nothing new arriving), Debug | **13–15% CPU, sustained.** The profile has no app frames: it is SwiftUI re-rendering the display list every frame for the looping indicators (Otto's working bob, the typing dots, the live dot, the rotating tool symbol), and each frame also re-runs `NSHostingView.updateConstraints` / `SizeConstraints.update` for the window. |

Debug numbers overstate Release by a large factor; the *shape* is what matters. The streaming-idle
number is the one users will feel: a Mac with three agents working in three windows is paying for
continuous animation even when nothing changes. Raw traces: `perf/long.trace` and
`perf/stream.trace` in the session scratchpad.

### Hotspots in the code

The 100% CPU loop from republished focused values is fixed (`FocusedActionsRelay` in
`ConversationScreen.swift:70`, `TabPages.swift:82`, `ConnectedServerView.swift:28`,
`PaletteCommands.swift:48`), and the CLI palette is cached per theme (`CLIPaletteCache`). What
remains:

0. **Continuous indicator animations (measured, above).** `OttoView.swift:43`
   (`phaseAnimator` offset bob), `TypingIndicator` and `LiveIndicator` (`Theme.swift:264–300`),
   `CLILines.swift:49`, and `.symbolEffect(.rotate)` in `ActivityRowViews.swift:199` each loop
   forever while a turn runs. Keep one indicator per visible turn, prefer render-server effects
   (`symbolEffect(.pulse)`, Core Animation) over SwiftUI `phaseAnimator` state, cap the rate, and
   stop them when the window is occluded or not key (`appearsActive`, `scenePhase`).
1. **Per-update transcript work in `body`.** `TranscriptView.body` (`TranscriptView.swift:37–38`)
   recomputes `Self.segments(for: state)` and `lastAnswerID` on every state change, which is every
   streamed delta. Both are O(rows), and `.equatable()` then compares every segment's full row
   array (`TurnSegment ==`, 11% of launch in the 3,000-row profile). Memoize the segments in the
   view state, keyed on the revision of finished rows, append only the streaming tail, and give
   `TurnSegment` a cheap identity-plus-revision equality.
2. **Offset-keyed `ForEach`.** 18 `ForEach(Array(x.enumerated()), id: \.offset)` sites, including
   markdown blocks (`MarkdownView.swift:45`). When a streamed paragraph splits into two blocks,
   every later block changes identity and re-lays out. Give blocks a stable id (source range start).
3. **Spinners per running session.** `SessionRow.swift:88` and `TabItemView.swift:226` each run a
   mini `ProgressView`; with several agents working, the sidebar and strip animate continuously.
   Use one static "working" glyph with a slow pulse, or animate only the focused window's.
4. **Favicons decode in `body`.** `TabItemView.swift:178/188–193` and
   `BrowserFavicon.image` call `NSImage(data:)` / `UIImage(data:)` on every evaluation of every
   tab. Cache the decoded image on the tab model.
5. **Closure-valued environment.** `conversationActions` (`MessageViews.swift:7`) is a struct of
   closures set from `TranscriptView.body`, together with a fresh `OpenURLAction`
   (`TranscriptView.swift:94–103`). Neither is equatable, so every reader re-evaluates whenever the
   transcript does. Wrap them in a reference type created once per screen (the `FocusedActionsRelay`
   pattern).
6. **Scroll-geometry callbacks.** Two `onScrollGeometryChange` closures run on every scroll frame
   (`TranscriptView.swift:115–126`). They return small values, so the cost is fine today; keep the
   `follow` model's work O(1) there.
7. **Two `TimelineView`s** (Inbox rows every 60 s, sub-agent elapsed every 30 s) are fine.

---

## 5. Recommendations

### 5.1 Fit-and-finish fixes (small, high impact), ranked

1. **Fix the iOS selected-row contrast** (F2) — `OmnigentUIComponents/SessionList/SidebarSelection.swift`.
2. **Top-anchor short transcripts on iPhone** (F1) — `Transcript/TranscriptView.swift`.
3. **Make the heading scale relative to body and group headings with their content** (T1, T2) —
   `Markdown/MarkdownView.swift`, `DesignSystem/Theme.swift`.
4. **Smaller, scrollable code on compact width** (T3) — `Theme.Typography.code`, the decision
   card's diff (`Decisions/`), `OmnigentWorkspaceUI/Views/DiffRows.swift`.
5. **Readable section headers and a darker light-theme "needs you" foreground** (contrast table) —
   `SessionList/SidebarView.swift`, `DesignSystem/ThemeColor.swift`, `NeedsYouCapsule`.
5a. **Inline code at 0.9 × body with padding** (T8) — `Markdown/MarkdownDocument.swift`.
6. **44 pt tab close on touch** (F8) — `Tabs/TabItemView.swift`.
7. **Let the iPhone model chip use the free width** (F6) — `Composer/ComposerCompactBar.swift`,
   `Composer/ConfigurationMenu.swift`.
8. **Drop the always-visible copy row on touch** (F3) — `Transcript/MessageActionRow.swift`.
9. **Overlay Mac hover actions instead of reserving 28 pt** (S3) — `Transcript/MessageActionRow.swift`.
10. **Pin the new-session composer to the keyboard** (F4) — `NewSession/NewSessionPage.swift`.
11. **One 16 pt compact gutter for chat and CLI** (S2) — `Theme.Spacing.compactGutter`,
    `CLIMetrics.compactGutter`.
12. **Theme and "This Mac" on the Connect window** (F9) — `OmnigentAuthUI`, `Apps/Omnigent-macOS`.
13. **Display names and state in the iPhone Tabs list** (F11) — `Tabs/TabOverview.swift`.
14. **Collapse the dock when the inline card is visible** (F13) — `Decisions/DecisionPresentation.swift`.
15. **Grid and radius cleanup** (S1, T5) — a lint rule plus `Theme` tokens.

### 5.2 Bigger improvements, ranked

1. **Phase 3, starting with actionable notifications on iPhone and a QR pairing flow.** Every
   competitor now controls local agents from the phone. Approve / Deny / Reply actions, grouped by
   session, plus "reconnects when your Mac wakes" (Claude) instead of "sessions drop" (Codex).
   Owner: `Apps/Omnigent-iOS`, a new `OmnigentNotifications` package, server APNs.
2. **An "Agents" Live Activity** (`3 working · 1 needs you`), which also appears in the macOS Tahoe
   menu bar. Owner: a widget extension target, `OmnigentStores` attention state.
3. **A transcript verbosity mode** (Normal / Thinking / Verbose, cycled with ⌃O), separate from
   Plain / Styled / Rich, with sub-agent activity collapsed into a one-line HUD by default
   (Claude desktop, Copilot). Owner: `Transcript/CLI/TranscriptAppearance.swift`, `TurnViews.swift`.
4. **A type and spacing token pass with a lint gate**: named roles, 4 pt grid, radius set, no
   fixed sizes; the gallery's contrast check extended to every text role. Owner: `DesignSystem/`,
   `Gallery/` render tests.
5. **Tab strip v2**: hover detail cards (Warp), "Close other tabs" and auto-close of idle primary
   chats (Safari, Dia), Option-click to open in split (Claude), and a vertical-tabs option for many
   agents. Also fixes the "primary chats accumulate" follow-up. Owner: `Tabs/`, `OmnigentAppUI/Tabs`.
6. **Queue v2**: list queued items under the running turn, drag to reorder, Edit / Send now /
   Remove (Cursor). Owner: `Composer/QueueStrip.swift`.
7. **Trusted browsing M2–M3**: pause and hand over at login and CAPTCHA, a "once / always for this
   site" consent (Comet), credentials typed during takeover kept from the model (ChatGPT), a
   per-session tab group. Owner: `OmnigentRemoteBrowser`, `browser-host/`.
8. **iPhone phone ergonomics pass**: a bottom toolbar on the session list with New and Settings
   (Mail/Notes iOS 26 pattern), the composer pinned to the keyboard, and Approve/Reject in the
   thumb zone of the dock. Owner: `SessionList/`, `Composer/`, `Decisions/`.

### 5.3 Top 10 to do next

| # | Change | Owner area |
|---|---|---|
| 1 | Fix white-on-pale selected sidebar rows on iOS (1.34:1), the 1.7:1 section headers and the 3.35:1 light "Needs you" text | `OmnigentUIComponents/SessionList/SidebarSelection.swift`, `SidebarView.swift` |
| 2 | Top-anchor short transcripts on iPhone; keep the large title under the toolbar | `OmnigentUIComponents/Transcript/TranscriptView.swift` |
| 3 | Heading scale relative to body (no heading smaller than body) and heading spacing 24 above / 8 below | `OmnigentUIComponents/Markdown/MarkdownView.swift`, `DesignSystem/Theme.swift` |
| 4 | Compact-width code and diffs at 13 pt mono with horizontal scroll and a wrap toggle | `DesignSystem/Theme.swift`, `Decisions/`, `OmnigentWorkspaceUI/Views/DiffRows.swift` |
| 5 | Touch hit targets: 44 pt tab close on iPad; remove the persistent copy row on touch | `Tabs/TabItemView.swift`, `Transcript/MessageActionRow.swift` |
| 6 | iPhone composer: model chip takes free width; new-session composer pinned to the keyboard; read-only state without a field | `Composer/ComposerCompactBar.swift`, `NewSession/NewSessionPage.swift`, `Composer/ComposerView.swift` |
| 7 | Running-session CPU: one render-server "working" indicator per visible turn, paused when the window is inactive (today 13–15% of a core while idle); then memoized segments with cheap `TurnSegment` equality, stable markdown block ids, cached favicons | `DesignSystem/OttoView.swift`, `DesignSystem/Theme.swift` (indicators), `Transcript/TranscriptView.swift`, `Transcript/TurnLayout.swift`, `Markdown/MarkdownDocument.swift`, `Tabs/TabItemView.swift` |
| 8 | Typography and spacing tokens with a lint gate (named text roles, 4 pt grid, radius set, no fixed 7–9 pt) | `OmnigentUIComponents/DesignSystem/`, `.swift-format`/lint config |
| 9 | Actionable iPhone notifications (Approve / Deny / Reply, grouped per session) and QR pairing | `Apps/Omnigent-iOS`, `OmnigentAppUI`, server APNs |
| 10 | Transcript verbosity mode (Normal / Thinking / Verbose, ⌃O) with collapsed sub-agent HUD | `Transcript/CLI/TranscriptAppearance.swift`, `Transcript/TurnViews.swift`, `SubagentGroupView.swift` |

## What not to copy

- Sessions that silently drop when the host sleeps (Codex remote).
- Removing branching (Claude's merged app). Keep fork chat.
- Default-expanded tool output; Zed users are asking for the opposite *[unverified]*.
- Building takeover around one vendor's agent browser; two were retired this year.
- A compact tab layout that moves in and out between OS releases (Safari, *[unverified]*):
  pick one strip and keep it.
