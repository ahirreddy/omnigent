# Omnigent native apps: UI/UX review 3 (fit, finish, performance, competition)

Reviewer: Fable (independent review). Date: 2026-11-02; web research performed 2026-11-01.

Inputs:
- The `cli-*`, `cli-ios-*`, `tabs2-*`, `fork-*`, `rb-*`, `parity-*`, `gallery-*`, `duo-*` and
  `rm-*` captures in `/private/tmp/claude-502/`, and the full gallery export in
  `gallery-export/` (I read about 45 of them; file names are cited inline).
- `apps/apple/docs/ui-ux-roadmap.md`, both 2026-11-01 reviews, `web-ui-spec.md`,
  `follow-ups.md`, `composer-sizing.md`, `gallery.md`.
- The `OmnigentUIComponents` sources (DesignSystem, Transcript, Transcript/CLI, Composer, Tabs,
  Commands, Markdown, SessionList, Inbox, Inspector), `OmnigentStores/ConversationStore`,
  `OmnigentAppUI/Adapters` and `OmnigentRemoteBrowser/View`.
- Public pages fetched on 2026-11-01. Claims marked *[search]* come only from a search summary;
  *[unverified]* means no primary page confirmed it. Neither kind supports a recommendation on
  its own.

I did not read the other two review-3 files before writing this. No product code was changed,
no app was driven, and no screen was captured.

## The short version

Phases 1 and 2 landed and they show. "Needs you" is one signal now (`SessionRow`, the sidebar
counts, the dock and the Inbox agree), pink is scarce, the composer on iPhone is a 48 pt bar
with a real Stop, the tab strip and split view work on all three device classes, the CLI style
is a convincing Codex look-alike (`cli-omnigent-dark.png` side by side with the real CLI), and
the remote browser has the one thing the competition lacks: a persistent "Agent is browsing ·
Take Over" bar.

What's left is finish, and it is mostly measurable:

1. **Vertical rhythm in chat style.** A settled answer is followed by a reserved 28 pt action
   row plus 24 pt row spacing plus the bubble's own spacing, so Mac transcripts show about 60 pt
   of air between an answer and the next question (`cli-chat-plain.png`, `fork-mac-hover.png`).
   ChatGPT and Claude keep that gap under 32 pt by overlaying the actions.
2. **Three type systems on one screen.** On iPad in CLI style the sidebar is system sans, the
   transcript is mono, and the approval card inside the transcript is sans again with mono
   paths (`cli-ios-ipad-omni-light.png`). H3 markdown headings on Mac are 13 pt bold inside 15 pt
   prose (`MarkdownView.headingFont`), smaller than the paragraph they head.
3. **Decisions appear twice.** The inline card and the dock show the same request with the same
   buttons at the same time (`cli-nord-approval.png`, `tabs2-ipad-split.png`,
   `cli-ios-duo-folded-omni-light.png`). On an iPhone that is two Approve buttons on one screen.
4. **Three Otto empty states with three copies** ("What should we build?", "What should we
   work on? Send a message to get started.", "What should we work on? Lifecycle details are in
   the inspector.") can appear in one split window (`tabs2-mac-split.png`).
5. **The remote browser letterboxes** instead of resizing the host viewport to the pane, so an
   iPad shows the page in a 720 pt-tall band with grey above and below (`rb-ipad-page.png`,
   `rb-mac-split.png`), and a raw encoder error reaches the user as a toast.
6. **Performance is structurally sound** (lazy rows, stable ids, Equatable segments, a parse
   cache, the focused-value relay) but three unstable environment values and a full re-parse of
   the streaming message on every delta remain. They are the same shape as the loop the relay
   fixed, one level down.

The competitive picture changed since the last review: ChatGPT Atlas is retired, Arc shuts down
on 2026-12-22, and no competitor documents a phone Stop or a persistent agent-browsing banner.
Those two are Omnigent's to own; the rest of this document is about making the existing
surfaces feel finished.

---

## 1. Competitor findings (late 2026)

### Corrections to the brief

- **ChatGPT Atlas is retired** and receives no updates; tabs, bookmarks and history do not
  transfer (https://help.openai.com/en/articles/20001371-chatgpt-atlas-retirement). Its agent
  mode is a historical reference only. The classic "ChatGPT agent" is also gone
  (https://help.openai.com/en/articles/11752874-chatgpt-agent).
- **Arc stops working on 2026-12-22**; new accounts ended 2026-10-22 (https://arc.net/). Dia is
  the successor and **has no iOS app** *[search]*.
- **The ChatGPT desktop app was rebuilt on 2026-07-09** as one app for Chat, Work and Codex
  (https://help.openai.com/en/articles/20001276). Chat Bar and Work with Apps are 2024 features
  of ChatGPT Classic and are not mentioned for the new app.
- **Apple's foldable is "iPhone Duo"** (https://www.apple.com/iphone-duo/specs/). The iOS 26
  SDK letterboxes a centred window on its inner display; the iOS 27.1 SDK is needed for full
  display with vertical bars (https://developer.apple.com/iphone-duo/prepare/).
- No product I could read documents hover-only versus always-visible message actions, an
  explicit phone Stop, or a persistent "agent is browsing" indicator with take-over. These are
  gaps, not patterns.

### Tab strips and split panes

| Product | Platform | Pattern | Source |
|---|---|---|---|
| Claude Code desktop | Mac | Panes drag by header and resize by edge; ⌘\ closes the focused pane. Option-click a sidebar session or right-click → Open in → Split view; **the focused pane stays bright and the other dims**; ⌘-click opens a new window; ⌘⌃W leaves split. Diff and terminal pop out into their own window. | https://code.claude.com/docs/en/desktop |
| Claude Code desktop | Mac | ⌘; opens a side chat that reads the main thread but never writes back. | https://claude.com/blog/claude-code-desktop-redesign |
| Cursor 3.24–3.27 | Mac | Drag a tile's chat tab onto another tile to move it; double-click to rename; hover shows agent details; subagents and side chats open as tabs beside the parent; ⌘⇧T reopens the last closed tab; Back restores closed file, terminal, browser and Changes tabs; focused pane and the agent's own tabs survive a restart. *[search for dates]* | https://prod.cursor.com/docs/release-notes |
| Cursor 3.0 | Mac | Agents Window: parallel agents local, in worktrees, cloud and SSH, as tabs or a grid, kept beside the IDE. | https://cursor.com/changelog/3-0 |
| Warp | Mac | Vertical tab sidebar; "View as" Panes or Tabs; tab item shows the focused session or a 3-line summary; Compact or Expanded density. **Five pane badges**: magenta clock (running), green check (done), red triangle (error), grey stop (cancelled), yellow stop (blocked on approval), plus an unread dot that clears on focus. | https://docs.warp.dev/terminal/windows/vertical-tabs |
| Warp 2026.07.03 | Mac | Fork: Enter opens the conversation in a new pane, ⌘Enter in a new tab. | https://docs.warp.dev/changelog/2026/ |
| Ghostty 1.3 | Mac | Drag splits to rearrange with a handle at the top of each split; double-click a divider to equalise; double-click a tab to rename; undo for closing splits, tabs and windows (1.2). | https://ghostty.org/docs/install/release-notes/1-3-0 |
| Zed | Mac | Threads sidebar (⌘⌥J); Terminal Threads whose sidebar title follows the running process (`claude`, `codex`) and notify when it needs attention. | https://zed.dev/blog/terminal-threads |
| Zed | Mac | `tabs.show_close_button` defaults to `hover`; `activate_on_close` defaults to `history`. | https://zed.dev/docs/reference/all-settings |
| cmux | Mac | Vertical sidebar per workspace: branch, PR, cwd, listening ports and the latest notification text. A blue ring on the pane and a lit tab when an agent waits; ⌘⇧U jumps to the latest unread. | https://github.com/manaflow-ai/cmux |
| Dia 1.52 | Mac | The active tab's favicon stays visible when it scrolls out of view; sidebar or top-bar tab layout; "Open as Split". *[search for split]* | https://www.diabrowser.com/changelog/mac/1-52-0 |
| Comet (Mar 2026) | Mac | Option-click an inactive tab to split; tab-group badges and agent-activity animations. *[search]* | https://www.perplexity.ai/help-center/comet/en/articles/12324462-split-view-mode |
| Safari, macOS Tahoe | Mac | Recessed pill tabs; opaque button backgrounds over translucent chrome. *[search]* | https://www.macstories.net/stories/macos-26-tahoe-the-macstories-review/2/ |
| Apple HIG | All | Tab bars navigate, never act; no overflow "More"; split views only in regular width, a 1 pt divider, persistent selection in each pane, several ways to reveal a hidden pane. | https://developer.apple.com/design/human-interface-guidelines/tab-bars , https://developer.apple.com/design/human-interface-guidelines/split-views |

### Terminal-style transcripts and density

| Product | Platform | Pattern | Source |
|---|---|---|---|
| Claude Code desktop | Mac | Verbose / Normal / Summary control tool-call detail. | https://claude.com/blog/claude-code-desktop-redesign |
| Cursor 3.4 | Mac | Tool-call density Compact / Balanced / Detailed, plus compact chat responses. Agents text size (S/M/L/XL) is separate from the editor font; chat width slider 600–1600 px. *[search for the slider]* | https://cursor.com/changelog/3-4 |
| Warp | Mac | A block is one command and its output; agent-run commands appear as compact summaries that expand. Thinking display: show-and-collapse (default), always, never. | https://www.warp.dev/blog/block-model-behind-warps-agentic-development-environment |
| Zed | Mac | `buffer_line_height` presets: standard 1.3, comfortable 1.618 (default); `agent_ui_font_size` separate from `ui_font_size`. | https://zed.dev/docs/reference/all-settings |
| Codex app | Mac | Appearance: UI font 14 px, code font 14 px, contrast 45 (light) / 60 (dark), background #FFFFFF / #181818, translucent sidebar toggle. | https://learn.chatgpt.com/docs/app/settings |
| Codex app | Mac | Terminal per thread (Ctrl+`), scoped to the project or worktree; ⌘K is the palette and does not clear. | https://learn.chatgpt.com/codex/integrated-terminal |
| GitHub Copilot | Web, mobile | Session logs cluster related tool calls, preview tool output inline, show file changes as expandable diffs, one icon per tool call, full Bash commands visible. Mobile renders the same logs natively with state filters and Stop. | https://github.blog/changelog/2026-01-26-introducing-the-agents-tab-in-your-repository/ , https://github.blog/changelog/2026-04-01-github-mobile-stay-in-flow-with-a-refreshed-copilot-tab-and-native-session-logs/ |
| Terminal.app, Tahoe | Mac | Clear Light / Clear Dark profiles; SF Mono 12 pt and 120×30 defaults (up from 11 pt and 80×24). *[search]* | https://arstechnica.com/gadgets/2025/09/macos-26-tahoe-the-ars-technica-review/ |
| Xcode 26 | Mac | Transcript pane plus artifacts pane; conversation sidebar; panes lay out as tabs so several agents run in parallel; Stop at the composer's lower right; per-response Undo Changes. | https://developer.apple.com/documentation/xcode/coding-intelligence |
| Claude (apps) | All | Three families: Serif for replies, Sans for UI and user input, Mono for code; OpenDyslexic option; no text-size control. *[third-party observation]* | https://maketypework.com/the-voice-of-an-agent/ , https://support.claude.com/en/articles/8887527-customizing-your-appearance-settings |
| Apple HIG | iOS | Body 17/22, Headline 17/22 semibold, Callout 16/21, Footnote 13/18, Caption 1 12/16, Caption 2 11/13; minimum 11 pt. macOS: Body 13/16, Callout 12/15, Footnote 10/13; minimum 10 pt. Avoid tight leading on three or more lines. | https://developer.apple.com/design/human-interface-guidelines/typography |
| Apple HIG | All | Controls: iOS 44×44 default, 28 minimum; macOS 28 default, 20 minimum; 12 pt around bezelled controls, 24 pt around bezel-free. | https://developer.apple.com/design/human-interface-guidelines/accessibility , https://developer.apple.com/design/human-interface-guidelines/buttons |

### Agent browsing and take-over

| Product | Platform | Pattern | Source |
|---|---|---|---|
| Codex Computer Use | Mac | Its own cursor, in the background, "without interfering with your own work"; stop or take over at any time; per-app always-allow list; asks before sensitive actions. Windows takes the real pointer in the foreground (the version to avoid). | https://openai.com/index/codex-for-almost-everything/ , https://learn.chatgpt.com/docs/computer-use |
| ChatGPT cloud browser | Web | Pauses by itself on sign-in or confirmation; the user takes over via a link; no manual pause and no browsing indicator. | https://help.openai.com/en/articles/20001280-using-cloud-browser-in-chatgpt |
| ChatGPT agent (retired) | Web | Screenshots were not captured during human take-over; the agent resumed from its prior state. | https://help.openai.com/en/articles/11752874-chatgpt-agent |
| Claude Code desktop | Mac | Browser pane (⌘⇧B) with a clean profile; each site asks Allow once / Always allow / Deny. | https://code.claude.com/docs/en/desktop |
| Claude in Chrome | Browser | Agent tabs go into a colour-coded group; the side panel defaults to auto-approve (the version to avoid). No banner is documented. | https://support.claude.com/en/articles/12012173-get-started-with-claude-in-chrome |
| Comet | Mac, Android | A pulsing blue highlight around the page while the assistant browses; it shows where it clicks; Stop and "provide more guidance"; pauses on login or purchase; browse yourself / browse once / auto-browse tiers. On iOS the agent runs in a cloud browser and reports progress as screenshots in the chat. | https://www.perplexity.ai/en-GB/hub/blog/comet-assistant-puts-you-in-control , https://www.macstories.net/news/comet-is-the-first-agentic-browser-for-ios-worth-trying/ |
| Cursor | Mac | Local browser as a pane or window; Manual approval (recommended), allow-listed actions, or auto-run; Design Mode picks elements into the composer (⌘⇧D). No local take-over is documented; cloud agents have remote desktop control *[unverified]*. | https://cursor.com/docs/agent/tools/browser , https://cursor.com/changelog/3-0 |
| Devin | Web | Take-over requires stopping or pausing first, then terminals become writable; hand back by telling Devin what changed. Command History jumps to any point. | https://docs.devin.ai/work-with-devin/devin-session-tools |
| iTerm2 3.7 | Mac | AI chat "orchestration" reads by default and asks before typing into a session; control is granted per session and revocable. *[search]* | https://iterm2.com/documentation-ai-chat.html |

### Phone and foldable ergonomics

| Product | Platform | Pattern | Source |
|---|---|---|---|
| ChatGPT iOS (2026) | iPhone | Model picker moved to the top of the conversation (Jun 10); long-press Send for a one-off model (Jun 8); reopened conversations show finished answers at once instead of replaying the stream (Aug 7); failed dictation retries once (Aug 7); pinned chats sync (Aug 20); locked chats hidden from history and search (Oct 20). | https://help.openai.com/en/articles/6825453-chatgpt-release-notes |
| Codex iPhone | iPhone | Tasks / Approve / Review / New task bar (mockup); host chips; a "Permission requested" card with the command and Approve / Always approve / Tell Codex what to do / Deny; Remote GA 2026-06-25 and the host must stay awake. | https://learn.chatgpt.com/docs/mobile , https://learn.chatgpt.com/docs/remote-connections |
| Claude iOS | iPhone | Code tab in the Claude app; `/remote-control` then a QR code; push when a decision is needed; no Bypass mode from the phone; dictation is mic on the right, arrow to send, ✕ to cancel. | https://code.claude.com/docs/en/mobile , https://support.claude.com/en/articles/10065434-using-dictation-on-the-claude-mobile-apps |
| Cursor iOS (beta 2026-06-29) | iPhone, iPad | iOS 26 required; Live Activities for up to 8 agents; push on finish, needs input, ready for review; full diff review with squash, auto-merge, update branch; Remote Control needs the Mac awake. | https://cursor.com/changelog/ios-mobile-app , https://cursor.com/docs/cloud-agent/mobile |
| Raycast iOS 1.5 | iPhone | Queue follow-ups while the AI responds; Steer redirects; edit and resend; background chats with a Live Activity (1.2.7); customisable tab bar with More (1.3.8). | https://www.raycast.com/changelog/ios |
| GitHub Mobile | iPhone, Android | Native session logs, state filters, Stop, create or review PR; Android puts Copilot in the navigation bar. Since 2026-10-28 one session list across web, mobile, CLI, VS Code and Slack, with local devices registered for steering. | https://github.blog/changelog/2026-04-01-github-mobile-stay-in-flow-with-a-refreshed-copilot-tab-and-native-session-logs/ , https://github.blog/changelog/2026-10-28-work-from-anywhere-with-a-new-connected-copilot-cloud-experience/ |
| Linear mobile (2026-07-30) | iPhone | A delegated-issues section under My Issues shows coding-session status; triage keys 1/2/3. *[unverified: changelog page did not load]* | https://linear.app/changelog |
| iPhone Duo | iPhone | Outer 5.4″, inner 7.6″. On the outer display controls move to a vertical side column: top bar buttons at the top, bottom ones at the bottom, tab bar stays bottom-aligned, wide items stay in the bar, overflow to a menu. Sheets slide off the fold; system components nudge interactive elements off the crease; the outer camera region is always reserved; `ReservedRegion` API. | https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo , https://developer.apple.com/videos/play/tech-talks/111466/ |
| iPadOS 27 | iPad | Apps rebuilt with the latest SDK opt in to window resizing; design for a range of sizes with size classes, not devices. | https://developer.apple.com/videos/play/wwdc2026/102/ |
| iOS 26 | iPhone | The tab bar shrinks on scroll; `Tab(role: .search)` puts search in the bar; `.tabBarMinimizeBehavior(.onScrollDown)`. *[search]* | https://developer.apple.com/videos/play/wwdc2025/323/ |

### Polish details

| Product | Platform | Pattern | Source |
|---|---|---|---|
| Apple HIG (materials, scroll views) | All | Liquid Glass only in the navigation layer, never in content; prefer the automatic scroll-edge effect; split panes each have one, at the same height; concentric radii for custom controls. | https://developer.apple.com/design/human-interface-guidelines/materials , https://developer.apple.com/design/human-interface-guidelines/scroll-views , https://developer.apple.com/design/human-interface-guidelines/toolbars |
| Apple HIG (sidebars, 2026-06-08) | Mac | Sidebars float in the glass layer and extend to the edges; coloured sidebar icons; no critical actions at the bottom; two hierarchy levels at most. | https://developer.apple.com/design/human-interface-guidelines/sidebars |
| macOS 27 | Mac | A uniform toolbar across the top of apps; edge-to-edge sidebars; a Liquid Glass slider from ultra-clear to fully tinted; every window gets the same tighter corner radius. *[search for the radius]* | https://www.apple.com/newsroom/2026/06/apple-unveils-next-generation-of-apple-intelligence-siri-ai-and-more/ , https://developer.apple.com/videos/play/wwdc2026/102/ |
| Apple HIG (pointing devices, 2026-10-28) | iPad | Default glass highlight on bar buttons, tab bars and segmented controls; let the pointer reveal and hide controls, with touch equivalents. | https://developer.apple.com/design/human-interface-guidelines/pointing-devices |
| Linear (2026-03-12 refresh) | Mac | Dimmed navigation sidebar, more compact rounded desktop tabs with smaller icons and text, fewer separators, warmer grey; no density setting. | https://linear.app/now/behind-the-latest-design-refresh |
| Linear | Mac | "Time in status" on hover over the status dot; hover cards the cursor can enter; a fix for choppy expansion of agent thoughts. *[search]* | https://linear.app/changelog/page/3 |
| Raycast | Mac | Enter runs the primary action; ⌘K shows the rest, filterable by typing. No latency figures are published. *[search]* | https://manual.raycast.com/action-panel |
| GitHub Copilot CLI | CLI | "No, and tell Copilot what to do differently (Esc)"; a timeline that records whether each decision came from the user, assisted permissions, policy or unattended fallback. *[search]* | https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/configure-copilot-cli |
| Apple HIG (progress) | All | Prefer determinate progress; keep indeterminate indicators moving so a stalled process does not read as frozen. | https://developer.apple.com/design/human-interface-guidelines/progress-indicators |

### What this changes for Omnigent

- **Density is now a user control everywhere** (Claude Verbose/Normal/Summary, Cursor
  Compact/Balanced/Detailed, Warp thinking modes, Zed line-height presets). Omnigent's
  Plain/Styled/Rich and the width setting are the right shape; what's missing is the same
  control for *tool-call* detail and a chat text size.
- **Focus dimming in split view** (Claude Code) and **tab state badges with an unread dot that
  clears on focus** (Warp) are the two cheapest split and tab polish items with a documented
  precedent.
- **Nobody documents a phone Stop or a persistent agent-browsing banner.** Omnigent has both.
  Keep them, name them in marketing, and finish the browsing banner with Comet's pulsing frame
  and Codex's visible cursor.
- **Atlas and Arc are cautionary tales**, not references: both retired within a year of launch.
  Prefer system containers and patterns with a long shelf life.
- **The Duo needs the iOS 27.1 SDK**, vertical bars on the outer display, and interactive
  controls kept off the crease. Today's gallery render runs the composer and a bubble across the
  crease (`duo-unfolded.png`).

---

## 2. Fit and finish

Severity: **High** (frequent surface, visibly unfinished), **Medium**, **Low**. Measurements
come from the sources where I could find the number, and from captures where I could not
(stated as approximate).

### 2.1 Type scale, line heights and paragraph spacing

What the code defines (`DesignSystem/Theme.swift`, `ReadingStyle.swift`, `Markdown/MarkdownView.swift`,
`Transcript/CLI/TranscriptAppearance.swift`):

| Role | Mac | iPhone / iPad | Note |
|---|---|---|---|
| Chat prose | 15 pt + 5 pt leading = 20 pt line (1.33) | 17 + 5 = 22 (1.29) | Scaled with `@ScaledMetric(relativeTo: .body)`; iOS matches HIG Body 17/22. |
| H1 / H2 / H3 / H4+ | `.title` 22 / `.title2` 17 / `.headline` 13 / `.subheadline` 11 | 28 / 22 / 17 / 15 | **H3 (13 pt) is smaller than the 15 pt prose on Mac; H4 (11 pt) is smaller than prose on both.** |
| Paragraph gap | 16 pt (`Spacing.paragraph`) | 16 | 0.8 of a line on Mac, 0.73 on iOS. Fine. |
| Row gap between turns | 24 pt (`Spacing.row`) | 24 | Plus the reserved action row (below). |
| Labels / captions | `.callout.medium` (12) / `.caption` (10) ×122 uses | 16 / 12 | Caption is the most used style in the package (122 sites); on Mac that is the 10 pt floor. |
| CLI mono | 13 pt (Terminal.app's new default is 12; Codex app code is 14 px) | 15 pt | `blockGap` 14, `bandPadding` 14, `gutter` 16, compact gutter 10. |
| Code | `.callout` monospaced (12 Mac / 16 iOS) | | Inline code at 16 pt inside 17 pt prose on iOS reads large; 15 would sit better. |

Issues:

| # | Severity | Finding | Where |
|---|---|---|---|
| T1 | High | **Reserved action row inflates the rhythm.** On Mac `MessageActionRow` keeps a 28 pt `Color.clear` placeholder while hidden so revealing it never moves the transcript. Stacked with the 24 pt row gap and the message VStack spacing, an answer and the next question sit about 60 pt apart (`cli-chat-plain.png` at 2×: 130 px). ChatGPT and Claude overlay the actions in a fixed 24–32 pt gap. | `Transcript/MessageActionRow.swift:80-84`, `Theme.Spacing.row` |
| T2 | High | **Heading scale inverts on Mac.** `## Summary` (title2, 17) is fine, `### Weekend in Mossbell` (headline, 13 bold) is 2 pt smaller than the body. Use a prose-relative scale: H1 1.5×, H2 1.25×, H3 1.1× semibold, H4 1.0× semibold, all from `proseSize`. | `Markdown/MarkdownView.swift:97-104` |
| T3 | Medium | **Three families on one screen in CLI style on iPad.** Sidebar (sans), transcript (mono), decision card (sans with mono paths) and the dock (sans). Pick one of: mono-styled decision cards in CLI style, or keep cards sans but drop the mono status line to a labelled bar. | `cli-ios-ipad-omni-light.png`, `Decisions/DecisionCardView.swift` |
| T4 | Medium | **Sub-minimum text and a small close target.** Avatar initials are 8 pt bold rounded (HIG minimum is 10 on Mac, 11 on iOS), which is why the light "SL" avatar the last review flagged is illegible. The tab close `×` is a 9 pt symbol in a 16 pt frame, under the 20 pt Mac minimum; the 7 pt status dot is a symbol and is fine. | `Inspector/SessionHeaderView.swift:146`, `Tabs/TabItemView.swift:103-112` |
| T5 | Low | **CLI line height is implicit.** `cliFont()` sets size and weight but no `lineSpacing`, so the line height is whatever SF Mono reports. Side by side with the real Codex CLI (`cli-omnigent-dark.png`) the Omnigent column is in fact a little tighter (the same four turns span about 620 px against 650 px), so this is not a defect, but a Standard 1.2 / Comfortable 1.4 preset like Zed's would make it deliberate and let the chat and CLI styles share one setting. | `Transcript/CLI/CLISourceText.swift:172-190` |
| T6 | Low | Phone CLI mono at 15 pt scaled to about 17 clips the itinerary table at "Saturday afternoo" with no scroll affordance (`cli-iphone.png`). Tables and diffs in CLI style on compact width should drop to 13 pt or scroll horizontally with a fade. | `Transcript/CLI/CLIStyledMarkdown.swift`, `Decisions/DecisionCardParts.swift` |
| T7 | Low | The "Type" gallery entry renders the prose sample as raw markdown source and indents the block 130 px from its heading (`components.designSystem.type--prose--omni-light.png`). It is the one place a reviewer looks for the scale. | `Gallery/Catalog/CatalogDesignSystem.swift` |

### 2.2 Grid adherence, alignment, radii, separators, icons

Tokens: spacing 2/4/8/12/16/24/32, radii 8 (small and `DesignTokens.radius`), 16 (card), 20
(bubble), 24 (composer), control 28/34/32 on Mac and 44 on touch, icon 16.

| # | Severity | Finding | Where |
|---|---|---|---|
| G1 | Medium | **Off-grid literals.** `padding 18`/`14` in the session header, `padding(.vertical, 60)` under the empty transcript, radius 6 on CLI revealed actions, radius 36 on the playground phone frames, paddings 1.5/2.5/3/5/7 elsewhere. Small, but each one is a place the 4 pt grid is not enforced. | `Inspector/SessionHeaderView.swift:33`, `Transcript/TranscriptBanners.swift:18`, `Transcript/CLI/CLIRevealedActions.swift:31` |
| G2 | Medium | **Two radii families in one card.** The decision card is 16 pt with a 0.5 pt border; the code block inside it is 8; the Approve capsule is a pill; the iPhone diff block inside the card is about 12. HIG asks for concentric radii: inner = outer − inset. Define `Radius.inner(of:inset:)` and use it in cards. | `Decisions/DecisionCardParts.swift`, `Theme.Radius` |
| G3 | Medium | **Tab strip truncation.** Tabs shrink to 112 pt (icon plus about eight characters), so a strip of seven reads "Refacto…", "zsh — cl…", "Why does…", "Omnige…" (`components.tabs.strip--overflow--omni-dark.png`); the status dot lands on the ellipsis of "Omnige…●". Dia keeps the active favicon visible; Warp shows a summary. Prefer a 140 pt floor, drop the title before the status glyph, and show the full title in a hover card (Cursor 3.24). | `Tabs/TabItemView.swift:19-26`, `Tabs/TabStrip.swift` |
| G4 | Medium | **Inspector tabs are still icon-only** (folder, ±, branch, chip, terminal, info) with the selected one in system blue, not the theme accent, on the light Mac capture (`parity-tabs-titlebar-inspector-light.png`); the empty Terminals pane repeats its own title under the header. | `Inspector/WorkspaceInspector.swift:148`, `components.inspector.workspace--terminals--omni-light.png` |
| G5 | Medium | **Split-pane focus is invisible.** In `tabs2-mac-split-focus.png` the only cue is the text cursor. Claude Code dims the unfocused pane; iPad shows a 2 px grey line at the top of the focused pane (`tabs2-ipad-split.png`) that reads as a scroll-edge artefact. One cue, both platforms: dim the inactive pane's toolbar and composer to 70%. | `Tabs/TabSplitView.swift` |
| G6 | Low | The user bubble's 0.5 pt border on a 20 pt radius and the card's 0.5 pt border on 16 pt look different in weight at 1× (iPad light); the bubble's reads as none. Use 1 pt on light, 0.5 on dark, or drop the bubble border. | `Transcript/MessageViews.swift:76-80` |
| G7 | Low | The tool-group row shows a "1 failed" pill *and* a green check at once (`components.transcript.tools--group--omni-dark.png`). One status glyph per row. | `Transcript/ToolViews.swift` |
| G8 | Low | The "Live and typing" gallery sample draws its dots over the label (`components.designSystem.pills--all--omni-dark.png`). | `Gallery/Catalog/CatalogDesignSystem.swift` |

### 2.3 Touch targets and truncation

| # | Severity | Finding | Where |
|---|---|---|---|
| H1 | High | **Decisions render twice on the phone.** The inline card (Approve, Reject) and the dock ("Edit 2 files · Review ›") are both on screen (`cli-ios-duo-folded-omni-light.png`, `tabs2-ipad-split.png` right pane: three option pills in the card and the same three in the dock). On a 466 pt-wide folded Duo that is two Approve paths and 60 pt-tall pills. Rule: when the inline card is visible in the viewport, the dock collapses to its one-line summary; when it scrolls off, the dock expands. | `Transcript/ConversationScreen.swift:130-145`, `Decisions/DecisionDock.swift` |
| H2 | High | **CLI composer on iPhone has no visible controls.** `cli-iphone.png` shows `› Ask the agent to do anything` and nothing else: no +, mic, Send or Stop, while the chat composer on the same device shows all four. The code puts them "at the band's trailing edge: always on touch" (`CLIComposer.swift:27-28`), so either the capture predates it or the band hides them when empty. Verify on device; the Stop in particular must never depend on focus. | `Transcript/CLI/CLIComposer.swift` |
| H3 | Medium | **Sidebar titles truncate to nine characters** when the Needs-you capsule is present on iPad ("Native mo…", "Choose th…", `cli-ios-ipad-omni-light.png`). Let the capsule shrink to a dot plus count on compact rows, as Warp's badge does. | `SessionList/SessionRow.swift` |
| H4 | Medium | The context row truncates mid-word on iPhone ("Codex · Ma…auth-refresh", `pages.transcript.conversation--errors--iPhone--omni-dark.png`). Truncate per segment (host first, then repo), never the whole string. | `Composer/ExecutionContextRow.swift` |
| H5 | Medium | Tabs sheet rows on iPhone show raw agent ids as subtitles (`tabs_fixture_agent`, `parity-iphone-tabs-dark.png`). Show the harness display name and the project. | `Tabs/TabOverview.swift` |
| H6 | Low | The fork sheet's title says "Fork from this response" and its button says "Clone" (`fork-mac-sheet.png`), with 120 pt of empty form below. One verb. | `Inspector/ShareForkSheets.swift:217-222` |
| H7 | Low | The CLI status line on iPhone reads "Sample Balanced" in ochre mono with nothing else (`cli-ios-duo-folded-omni-light.png`); fixture data, but it shows the line needs a glyph or label when the directory and branch are hidden at compact width. | `Transcript/CLI/CLIComposerStatusLine.swift:56-59` |

### 2.4 Empty, loading and error states

| # | Severity | Finding | Where |
|---|---|---|---|
| E1 | High | **Three Otto empty states, three copies**, visible together in a split window (`tabs2-mac-split.png`): "What should we build?" (new session), "What should we work on? Send a message to get started." (empty session) and "… Lifecycle details are in the inspector." (empty session with lifecycle rows). One heading; the sub-line carries the difference. Otto should appear once per window. | `NewSession/NewSessionPage.swift:30`, `Transcript/TranscriptBanners.swift:23-29` |
| E2 | High | **Raw error text in a toast.** "browser host error internal: encoder: x264 ignored a qpfile IDR request; switching to encoder restarts" (`rb-mac-split.png`). Users get "The browser stream restarted" and a Details disclosure; the string goes to the log. | `OmnigentRemoteBrowser/View`, `Tabs/RemoteBrowserPreview.swift` |
| E3 | Medium | **Three banner layouts for three errors** on one phone screen (`pages.transcript.conversation--errors--iPhone--omni-dark.png`): the failure banner puts Copy beside a filled button, the connection banner puts Copy before Retry/Dismiss, the delivery banner has one full-width tinted button. One banner grammar: glyph, title, one line, actions right-aligned, Copy in the overflow. | `Transcript/TranscriptBanners.swift:58-110`, `Composer/ComposerParts.swift:7-40` |
| E4 | Medium | **No elapsed time while streaming in CLI style** (`cli-nord-streaming.png`): the real Codex CLI shows "Working (12s · esc to interrupt)"; Omnigent shows only the status-line hint. The chat style has "Working…" with a rotating label but no timer either. Add `· 12s` to both (the data is in `turnDurations` once settled; a `TimelineView(.periodic(by: 1))` on the live fold is enough). | `Transcript/TurnViews.swift:65-96`, `Transcript/CLI/CLIActivityViews.swift` |
| E5 | Medium | "Working…" appears twice in the live turn (fold title and indicator, `components.transcript.turn--live--omni-light.png`), and the `WorkingIndicator` uses the mascot as a spinner, which the roadmap's "no pet status UI" rule argues against. Keep Otto in empty states; use `ProgressView` or the typing dots here. | `Transcript/TurnViews.swift:76` |
| E6 | Medium | The remote browser's loading and ended states are letterboxes with no page (`rb-ipad-page.png`: a 720 pt band of page in a 1770 pt pane). See P7 below for the fix; until then centre a "Connecting to the agent's browser…" label in the empty area. | `OmnigentRemoteBrowser/View/RemoteBrowserView.swift:19-21` |
| E7 | Low | The "Message content" dashed placeholder from review 1 (X8) is still in the parity captures (`parity-tabs-titlebar-inspector-light.png`, `duo-unfolded.png`). | `Transcript/MessageViews.swift` (`UnsupportedContentView`) |
| E8 | Low | "Signing token — Optional" still shows "Enter PR title." under it (`rm-decisions-phone-dark.png`); `follow-ups.md` says the real app does not wire `validateForm`. | `Decisions/DecisionFormView.swift` |

### 2.5 Light and dark parity

| # | Severity | Finding | Where |
|---|---|---|---|
| L1 | Medium | **Light-mode Inbox code block is a black card** inside a light card (`rm-inbox-triage-760-light.png`): the only near-black surface on the screen. Use the CLI canvas colour of the current theme at light, or a tinted surface. | `Inbox/InboxRow.swift`, `Decisions/DecisionCardParts.swift` |
| L2 | Medium | **System blue leaks into light mode:** the iPad sidebar's New session and Inbox icons, the selected inspector tab, the browser "Personal" profile chip, and the gallery's sign-in screens (`parity-ipad-light.png`, `parity-tabs-titlebar-inspector-light.png`, `tabs2-mac-split.png`, `duo-folded.png` gallery side vs the pink simulator side). `AuthBannerView` hard-codes `.blue`. | `OmnigentAuthUI/Views/AuthBannerView.swift:34-40`, `Inspector/WorkspaceInspector.swift:148` |
| L3 | Medium | The pinned "Needs you" row on iPad light draws pink text on a pink wash (`tabs2-ipad-split.png`): it looks disabled. Selected-plus-attention needs the capsule on a neutral selection fill. | `SessionList/SessionRow.swift`, `Theme.selection` |
| L4 | Low | In dark mode the dock's Reject and Approve read as equal weight (`parity-tabs-titlebar-dark.png`); in light the Approve is clearly primary. Check the dark `onAccent` and the bordered button's fill. | `Decisions/DecisionDock.swift` |
| L5 | Low | The light CLI palettes hold up: Omnigent light's `heading` 0xA34D14 and `dim` 0x6C664B are both about 5.3:1 on the 0xF7F5FD canvas. The light user band (`cli-omnigent-light.png`) is a flat grey on white where the real Codex light theme tints it; a 4% accent wash would tie it to the theme. | `Transcript/CLI/CLIPalette.swift:95` |

### 2.6 Mac, iPad and iPhone consistency; chat versus CLI

| # | Severity | Finding | Where |
|---|---|---|---|
| C1 | High | **The Mac composer differs between captures of the same state.** `parity-tabs-titlebar-dark.png` has an unlabeled laptop glyph, no + and no mic; `parity-tabs-titlebar-inspector-light.png` has +, "Ahir's MacBook Pro", mic. One is the fixture, one the real app, but the roadmap's "verify in the real app" step should catch this: the control set must not depend on data availability. | `Composer/ComposerControls.swift` |
| C2 | Medium | **Chat and CLI disagree on what a turn shows.** CLI prints "Worked for 3s · 9:45 PM" under every answer; chat shows a timestamp only on hover and never the duration outside the fold. Show "Worked for 3s" in both, and make the chat timestamp a hover tooltip on the duration. | `Transcript/TurnViews.swift`, `Transcript/CLI/CLITranscriptRows.swift` |
| C3 | Medium | **Plain rendering in chat style** (`cli-chat-plain.png`) mixes sans user bubbles with mono raw markdown in the same column. Either Plain forces CLI style, or the chat column renders Plain inside a code-coloured block. | `Markdown/MarkdownView.swift:22-31` |
| C4 | Medium | **Widening options differ by surface.** The CLI card has a "More approval options…" menu; the Inbox card lays out three outlined chips (Approve and remember / Approve for this session / Always allow). The roadmap chose the menu. | `Inbox/InboxRow.swift`, `Decisions/DecisionCardView.swift` |
| C5 | Medium | **Copy icons on touch sit at different heights** under user bubbles (right) and answers (left) with 60 px of air between (`parity-ipad-light.png`). On touch, show actions only under answers; put the user message's in the long-press menu (the code's `showsOnTouch` already intends this; the capture shows both). | `Transcript/MessageViews.swift:48-52` |
| C6 | Medium | **iPhone navigation bar is 130 pt tall** with the title and "Finished" subtitle and no large title drawn (`parity-iphone-dark.png`); `follow-ups.md` attributes the empty band to `TitlebarBackdrop`. Fix before adding anything to the bar. | `Transcript/CLI/TranscriptAppearance.swift:207` |
| C7 | Low | The Duo unfolded gallery runs a user bubble and the composer across the crease and draws a stray horizontal bar under the composer (`duo-unfolded.png`). HIG: keep interactive elements off the fold. Unverifiable on the simulator until Xcode can unfold; keep it on the list. | `Adaptive/DuoLayout.swift` |
| C8 | Low | Mac prose at 15 pt is 2 pt above HIG body; it reads well in the 720 pt column. Keep it, but add a chat text-size setting (Cursor S/M/L/XL), since the CLI already has one. | `Transcript/CLI/TranscriptSettings.swift:31-36` |

---

## 3. Performance

### What the captures and code show working

- `TranscriptView` is a `LazyVStack` keyed by stable row ids; segments are `Equatable` and
  folded once per body; markdown for settled rows comes from `MarkdownCache` (512 entries);
  `TranscriptFollow` only scrolls while following. This is the right skeleton.
- `FocusedActionsRelay` keeps the `focusedSceneValue` identity stable per menu signature, which
  closed the 100% CPU loop. `ConversationScreen` and `TabsPlayground` use it.
- `TranscriptAppearance` is laid out so SwiftUI's bytewise comparison works (the `Double` first).
- Otto's bob is an `offset` phase animation on a `Canvas` (a transform, not a redraw).
- `InboxRow` and `SubagentGroupView` use `TimelineView(.periodic)` at 60 s and 30 s rather than
  timers.

### Hotspots that remain

| # | Impact | Finding | Where |
|---|---|---|---|
| P1 | High | **`openURL` is rebuilt on every `TranscriptView` body.** `OpenURLAction { … }` is a new closure each pass, so the environment value changes on every streaming revision and every view that reads `openURL` (each `Text` with a link, every `MarkdownBlocksView`) is invalidated, defeating `.equatable()` on the segments. Hoist it into `@State` or a stored property created in `init`, or set it once in `ConversationScreen`. | `Transcript/TranscriptView.swift:97-106` |
| P2 | High | **`ConversationActions` is an environment value made of closures.** `MessageRowView`, `ActivityRowViews`, `CLIMessageViews` and `TranscriptBanners` read `\.conversationActions`; the struct is rebuilt by `ConversationContainer` on each of its body passes and is not `Equatable`, so SwiftUI treats it as changed every time. This is the relay problem one level down: give it the same `menuSignature`/forwarding treatment (`FocusedActions`) or store it in a `@State` relay in `ConversationScreen`. The same applies to `ComposerActions`, `TabActions` and `SidebarActions` where they are passed through the environment. | `Transcript/MessageViews.swift:7`, `ViewState/ConversationState.swift:238`, `OmnigentAppUI/Screens/ConversationContainer.swift:78-90` |
| P3 | High | **Streaming re-parses the whole message per delta.** `MarkdownView` with `isStreaming` calls `MarkdownParser.parse(text)` (swift-markdown, full document) on every body pass, and Plain does the same for tinting (`SourceTinting.spans`). A 20 KB reply at 20–50 deltas/s is O(n) per delta, O(n²) per reply, on the main actor. Options: parse once per `revision` into `@State` keyed by `(row.id, text.utf8.count)`; or split the stable prefix (everything before the last blank line) through the cache and parse only the tail. | `Markdown/MarkdownView.swift:27`, `Transcript/CLI/CLIStyledMarkdown.swift:13`, `Transcript/CLI/CLISourceText.swift:26-45` |
| P4 | Medium | **`MarkdownCache` is keyed by the full text.** Every settled row hashes its whole string on every body pass to look up the cache (`entries[text]`), and eviction is FIFO over a `[String]` with `removeFirst()` (O(n)). Key by row id plus a cheap length-and-tail hash, or store the parsed blocks on the `Row` when the core settles it. | `Markdown/MarkdownDocument.swift:217-239` |
| P5 | Medium | **Segments and decorations are recomputed on every body pass.** `TranscriptView.body` runs `TurnLayout.segments(TranscriptLayout.items(for: rows))` and `decorations(for:)` per segment, on every revision and on every unrelated invalidation (an environment change from P1/P2 included). Memoise on `state.revision` in `@State`, or compute once in the adapter. | `Transcript/TranscriptView.swift:36-37, 236-262` |
| P6 | Medium | **Two scroll-to-bottom paths per delta.** `onScrollGeometryChange(contentSize.height)` and `onChange(of: state.revision)` both call `proxy.scrollTo` while following; with a `LazyVStack` that is two layout passes per token. Keep the geometry one (it also covers late-sizing rows) and drop the revision one, or coalesce into a single `Task` per frame. | `Transcript/TranscriptView.swift:116-124` |
| P7 | Medium | **Remote browser never resizes the viewport to the pane.** `RemoteBrowserView` letterboxes a fixed viewport (`videoGravity = .resize`, `RemoteViewportGeometry`); the fixture driver has `resize(viewport:)` but the view does not call it on layout. Debounce the pane size (250 ms) and ask the host for a matching viewport, as every VNC client and Codex do. This is also the biggest visible gap in `rb-ipad-page.png`. | `OmnigentRemoteBrowser/View/RemoteBrowserView.swift:58-78`, `Fixture/FixtureRemoteBrowserDriver.swift:143` |
| P8 | Low | **Geometry writes in the tab strip.** `TabStrip` and each `TabStripSection` store `frame(in: .global)` in `@State` on every layout change (a window resize, the split divider moving, the inspector opening), which re-evaluates the strip once more per change. Harmless today; it matters if the strip ever animates with the divider. Store only what the drag needs (the divider x and section widths) and compare before writing. | `Tabs/TabStrip.swift:96-116` |
| P9 | Low | **`onHover` on every message row** flips `@State` and runs a `Theme.Motion.feedback` animation; with `MessageActionsHost` inside each row, a mouse sweep down a 50-row transcript animates 50 reveals. Fine today; it becomes visible once P1/P2 are fixed and rows stop re-rendering for other reasons. Consider one hover tracker at the transcript level that publishes the hovered row id. | `Transcript/MessageActionRow.swift:120-150` |
| P10 | Low | **Favicon decode in the tab item.** `NSImage(data:)` runs inside `TabItemView` whenever the tab's favicon data is present; cache the decoded `Image` by data hash in the tab model. | `Tabs/TabItemView.swift:188-194` |
| P11 | Low | `Theme.relativeDate` allocates a `DateFormatter` per call. It has no callers now (`RelativeTime.short` is used); delete it before someone finds it. | `DesignSystem/Theme.swift:106-120` |

Instrumenting P1–P3 is cheap: `swift test --filter GalleryCatalogRenderTests` already renders
every state; adding `os_signpost` around `MarkdownView.body` and counting body evaluations in
a streaming fixture (`pages.transcript.conversation--streaming`) will show whether the count
drops from "every delta × every visible row" to "every delta × one row".

---

## 4. Top 15 recommendations (ranked by impact ÷ effort)

S = a day or two, M = up to a week, L = more.

1. **Fix the three unstable environment values** (P1, P2, P5). *Mac, iPad, iPhone; S.*
   `TranscriptView.swift`, `MessageViews.swift`, `ConversationContainer.swift`. Store `openURL`
   and `ConversationActions` in a relay like `FocusedActionsRelay`, memoise segments on
   `revision`. Inspired by the project's own `FocusedActionsRelay` and Cursor's long list of
   "tabs restore / focus persists" fixes (they shipped the hard version; take the easy one).
2. **Overlay message actions instead of reserving a row** (T1). *Mac; S.*
   `MessageActionRow.swift`, `Theme.Spacing.row`. Draw the action row in an `overlay(alignment:
   .bottomLeading)` inside the row gap and cut `Spacing.row` to 16 for answers. Target: answer to
   next bubble ≤ 32 pt. Inspired by ChatGPT and Claude's hover rows.
3. **One decision surface at a time** (H1). *All; S–M.* `ConversationScreen.swift`,
   `DecisionDock.swift`. When the inline card is in the viewport the dock is a one-line summary;
   when it is not, the dock expands. On iPhone the expanded dock is the sheet the roadmap chose.
   Inspired by Codex's single "Permission requested" card and Xcode's single Stop.
4. **Prose-relative heading scale and a chat text-size setting** (T2, C8). *All; S.*
   `MarkdownView.swift:97`, `TranscriptSettings.swift`. Headings at 1.5/1.25/1.1/1.0× of
   `proseSize`; a Small/Default/Large/Extra Large chat size beside the CLI slider. Inspired by
   Cursor Agents text size and Zed's `agent_ui_font_size`.
5. **Incremental streaming parse** (P3, P4). *All; M.* `MarkdownView.swift`,
   `CLISourceText.swift`, `MarkdownDocument.swift`. Parse the stable prefix through the cache
   and only the tail per delta; key the cache by row id. Measured target: body evaluations per
   delta constant in reply length. Inspired by ChatGPT's "finished answers render at once"
   change (Aug 2026): don't re-animate, don't re-parse.
6. **Resize the remote viewport to the pane and humanise host errors** (P7, E2, E6). *Mac,
   iPad; M.* `RemoteBrowserView.swift`, `RemoteBrowserPreview.swift`. Debounced `resize(viewport:)`
   on layout; a "Connecting…" state; errors as "The browser stream restarted" with Details.
   Inspired by Comet's pulsing frame (add it to the "Agent is browsing" bar) and Codex's visible
   cursor.
7. **Split-pane focus dimming and a tab unread dot that clears on focus** (G5, G3). *Mac,
   iPad; S.* `TabSplitView.swift`, `TabItemView.swift`. Dim the inactive pane's toolbar and
   composer; keep the pink dot for needs-you, a grey dot for unread that clears when the tab is
   focused; title truncates before the glyph; hover card with the full title and status.
   Inspired by Claude Code's split dimming and Warp's unread dot.
8. **One empty state, one copy, once per window** (E1). *All; S.* `NewSessionPage.swift`,
   `TranscriptBanners.swift`. "What should we work on?" everywhere; the sub-line varies; Otto
   only in the pane that has focus. Inspired by nothing in particular; it is housekeeping.
9. **Elapsed time on the live turn in both styles** (E4, C2). *All; S.* `TurnViews.swift`,
   `CLIActivityViews.swift`. "Working · 12s" in chat, "• Working (12s · esc to interrupt)" in
   CLI; "Worked for 3s" under settled answers in chat too. Inspired by the Codex CLI and HIG's
   "keep it moving" rule.
10. **One banner grammar** (E3). *All; S.* `TranscriptBanners.swift`, `ComposerParts.swift`.
    A `StatusBanner(kind:title:detail:actions:)` with the glyph on the left, actions right, Copy
    in the overflow; the three existing banners become three kinds. Inspired by Linear's banner
    restraint and HIG alerts.
11. **Concentric radii and the 4 pt grid enforced by a lint** (G1, G2). *All; S.* `Theme.swift`
    plus a SwiftLint custom rule for `padding(` and `cornerRadius:` literals outside `Theme`.
    Inner radius = outer − inset in cards. Inspired by HIG's concentric-corner guidance for
    Liquid Glass.
12. **Finish the theme in light mode** (L1, L2, L3). *All; S.* `AuthBannerView.swift`,
    `WorkspaceInspector.swift`, `InboxRow.swift`, `SessionRow.swift`. No `.blue`; the Inbox
    command block on a tinted surface; the selected needs-you row keeps the capsule on a neutral
    fill. Inspired by Codex's documented light/dark pairs (contrast 45/60).
13. **Tool-call density control to match the transcript density control** (new). *All; M.*
    `ToolViews.swift`, `TranscriptSettings.swift`. Compact (one line per group) / Balanced
    (today) / Detailed (every call expanded), remembered per style. Inspired by Claude Code
    Verbose/Normal/Summary, Cursor Compact/Balanced/Detailed, Warp thinking modes.
14. **CLI line height presets and compact-width tables** (T5, T6). *All; S.* `CLISourceText.swift`,
    `CLIStyledMarkdown.swift`. Standard 1.2 / Comfortable 1.4; tables and diffs in CLI style
    scroll horizontally with an edge fade at compact width. Inspired by Zed's line-height presets
    and Terminal.app's 12 pt default.
15. **Labelled inspector tabs and real agent names in the Tabs sheet** (G4, H5). *Mac, iPad,
    iPhone; S.* `WorkspaceInspector.swift:148`, `TabOverview.swift`. A labelled segmented picker
    when ≥ 420 pt, icons with tooltips below; harness display name and project as the sheet
    subtitle. Inspired by Zed's "title follows the process" and HIG's "label tabs".

Verification for each: the gallery export for the touched entries in light and dark on
`mac,iPhone,iPadPro11,duo,duo-unfolded`, then the real app on the Mac and one simulator, as
`docs/verify-real-app.md` describes. For 1 and 5, add a body-evaluation counter to the
streaming fixture and record before and after.

---

## 5. Bigger bets

1. **A measured design system.** Turn `Theme` into the source of truth with a type ramp
   (`prose`, `heading(1…4)`, `label`, `caption`, `mono`) derived from one base size per
   platform, a spacing scale on 4 pt, concentric radii, and a lint that fails on literals outside
   it. Export the ramp and the tokens into the gallery's Type entry (T7) so the catalogue is the
   spec. Payoff: every item in section 2 becomes a one-line change instead of a hunt, and the web
   UI spec can share the numbers.
2. **A streaming-first transcript pipeline.** Move folding, markdown parsing and diff detection
   off the view and into the adapter, keyed by core revision, producing immutable `[TurnSegment]`
   with pre-parsed blocks. The view then has nothing to compute in `body`, environment values are
   stable, and the same pipeline serves chat, CLI and a future "Summary" density. This is what
   makes a 2,000-row session with three streaming sub-agents feel like a text editor rather than
   a web page.
3. **Own "the agent is browsing".** Comet shows where it clicks; Codex has its own cursor;
   nobody has a persistent banner plus a one-tap hand-back on Mac, iPad and iPhone. Finish it: a
   pulsing accent frame while the agent acts, a cursor overlay from host pointer events, per-site
   Allow once / Always / Deny before the first navigation, a clean profile per session, and the
   banner's text naming the current action ("Agent is filling the search form"). Then use the
   same frame and banner for agent-owned terminals, so take-over is one idea across the app.

---

## 6. What not to copy

- **Atlas or Arc as references.** Both are gone within a year. Prefer system containers.
- **Codex's Windows foreground pointer take-over** and Devin's "pause before you can take
  over". Omnigent's background hand-off is better; keep it per pane.
- **Claude in Chrome's auto-approve default** and Copilot CLI's "approve this tool for the rest
  of the session" (it also approves pending parallel requests). Scope approvals to the command.
- **"Always approve" as a prominent phone button** (Codex iPhone). Keep it behind "More approval
  options…" with the confirmation.
- **Long-press as the only path** (ChatGPT's send and + gestures). Fine as accelerators; never
  for Stop or Approve.
- **Global hotkeys that need Screen Recording and Accessibility** for a text box (Claude Quick
  Entry).
- **Replaying a finished transcript as if streaming** on reopen (the bug ChatGPT fixed in Aug
  2026). Omnigent's `isStreaming` flag already prevents it; keep the test.
- **Comet's cookie transfer to a cloud browser** without per-task consent.
- **A phone tied to a host that must stay awake** without a clear offline state (Codex, Claude,
  Cursor all document the limitation). Omnigent's server model avoids it; say so in the UI.
- **Liquid Glass in the content layer**, stacked glass, or custom scroll-edge effects over the
  system ones (HIG). The transcript, code and approval payloads stay on opaque surfaces.
- **Overflow "More" tabs** for sessions (HIG). The strip scrolls; the overview sheet is the
  escape.
- **Eight simultaneous Live Activities** as a target (Cursor's cap is a limit, not a goal).
- **Per-chat text size and chat width knobs without persistence tests** (Cursor's forum threads
  show the bugs). One setting per style, stored once.
- **The mascot as a status indicator.** Otto is for empty states and onboarding; the working
  indicator is a spinner or the typing dots.

---

## 7. How to check this review

```sh
cd apps/apple/Packages/OmnigentUI
# The screens cited above, framed, both appearances:
swift run OmnigentPlayground --export-gallery /tmp/omnigent-review3 \
  --gallery-filter transcript.message,transcript.turn,transcript.tools,transcript.banners,decisions,tabs.strip,composer.touch-bar,pages.transcript \
  --gallery-devices mac,iPhone,iPadPro11,duo,duo-unfolded --gallery-frames on
open /tmp/omnigent-review3/index.html
```

Then in the real apps (`just apple-run`, `just apple-run-ios`), with a long streaming session:

1. **Rhythm:** measure the gap between an answer and the next bubble with the Accessibility
   Inspector; it should be ≤ 32 pt after recommendation 2.
2. **Decisions:** trigger two requests on an iPhone; only one Approve should be on screen at a
   time (recommendation 3).
3. **Streaming cost:** with Instruments' SwiftUI template, count `MarkdownView.body` evaluations
   during a 20 KB reply before and after recommendations 1 and 5; the count should stop growing
   with reply length.
4. **Split focus:** open a split, click each pane; the inactive pane should dim and the tab
   strip should show which pane owns the menus (recommendation 7).
5. **Browser:** open the remote browser in a tall iPad pane; the page should fill the pane within
   250 ms of a resize, and an encoder restart should read as a sentence, not a log line
   (recommendation 6).
6. **Light mode:** flip the Mac app to light with the Omnigent theme; nothing on the sign-in,
   sidebar, inspector or Inbox should be system blue (recommendation 12).
