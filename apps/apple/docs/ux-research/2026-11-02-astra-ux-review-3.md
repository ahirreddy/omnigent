# Omnigent native apps: UI/UX review 3 (Astra / gpt-6-astra)

Reviewer: Astra (`gpt-6-astra` through the Codex CLI 0.166.0, Databricks provider, read-only
sandbox). Date: 2026-11-02. Recorded by Claude; the text below is Astra's output, verbatim.

How it was run:
1. **Blind pass.** Astra got the product brief, the list of changes since review 2, the user's ask,
   and 16 screenshots (Mac real app: tab strip, split view, hover actions, remote browser, CLI style
   against the user's Codex CLI, CLI Styled/Nord, the Connect screen; iPhone real app: session list,
   approval, new session, short conversation, long reply in dark, Tabs list, CLI Nord; iPad Pro 13
   split; folded iPhone Duo approval). It could read the repository but saw no other reviewer's
   conclusions. Web search doesn't work through this provider.
   `codex exec -m gpt-6-astra -s read-only -i <16 images> - < prompt`
2. **Second pass.** Astra got its own first pass plus the verified competitor table from
   [Claude's review 3](2026-11-02-claude-ux-review-3.md) section 1 (the table and the list of
   retirements only, not Claude's takeaways or findings) and the 2026-11-01 table, and revised.

Section A is the revised review (the one to use). Section B is the blind first pass, kept for the
record. Prompts and full logs: `astra-review3-prompt.md`, `astra-review3.log`,
`astra-review3-pass2-prompt.final.md` and `astra-review3-pass2.log` in the session scratchpad.

---

# A. Revised review (second pass, with verified competitor evidence)

## 1. Summary

The visual direction still works: the purple-black canvas, restrained pink, neutral user bubbles, and compact composer feel like one product. The immediate weaknesses remain input reliability, navigation, narrow-layout review, accessibility, and potentially expensive update paths.

The competitor evidence changes the roadmap more than the visual diagnosis:

- **Strengthened:** closable tabs, pane-specific layouts, dedicated change review, compact activity summaries, and clear browser ownership.
- **Elevated:** phone-based supervision, host connection reliability, consistent attention states, and explicit queue-versus-steer behavior.
- **Changed:** preview tabs remain a design proposal, but the supplied evidence does not establish them as a Cursor pattern. Dia directly supports pinned versus disposable tabs.
- **New opportunity:** make existing conversation forking discoverable. Earlier-point branching is unavailable in Claude’s merged Chat/Cowork experience; this comparison does not establish a limitation in Claude Code.
- **Still deferred:** a separate Mission Control canvas. Existing navigation and decisions need to become dependable first.

Review dated **2026-11-02**. Competitor claims use your supplied table and [section 1 of the November 1 research](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/docs/ux-research/2026-11-01-claude-ux-review.md). I did not independently refetch their pages. Screenshot findings and performance risks are carried forward from the first pass, with limited additional source inspection. **No files were edited, and no runtime profiling was conducted.**

## 2. Fit and finish

**High — Phone navigation and first-tap behavior remain the first fixes.** Screens 8 and 11 lose too much space above useful content; the earlier estimate was approximately 200 pt between toolbar and large title in screen 11. Investigate `AppShell` safe-area handling, large-title placement, and short-content alignment together. The screenshot establishes the symptom, not its cause. Separately, [ReadingPostureFocus.swift](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/Packages/OmnigentUI/Sources/OmnigentUIComponents/Transcript/ReadingPostureFocus.swift:29) rejects focus acquired during the first second, including a deliberate tap. Suppress unwanted restoration without suppressing intentional input.

**Medium — Keep the compact composer; correct its surrounding geometry.** The 48 pt bar, 36 pt visible Send/Stop circle, and 44 pt target are appropriate. Screen 10’s estimated 50–60 pt keyboard clearance needs reproduction after the keyboard settles; roughly 8–12 pt of intentional clearance is a reasonable design target. Replace “Sam…lanced” with a meaningful short model name and a fully labelled configuration sheet. Competitor composer features do not justify cramming more metadata into this row.

**High — Adapt to the actual pane width.** A 320 pt minimum pane cannot comfortably absorb 48 pt of regular-width transcript gutters plus card padding. [AdaptiveLayoutWidth.swift](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/Packages/OmnigentUI/Sources/OmnigentUIComponents/Adaptive/AdaptiveLayoutWidth.swift:25) uses iOS size class rather than measured pane width. Screen 15 consequently resembles two compressed desktop layouts. Use compact spacing and card arrangements per pane, with visible expand/restore controls. On folded Duo, 466−84 leaves only 382 pt before application gutters: treat it as narrow content and preserve the system status column.

**High — Separate session lifetime from tab lifetime.** The unified chat/shell/browser strip is useful, but prohibiting closure of primary-chat tabs creates accumulation simply through sidebar browsing. Let users close and reopen the view without stopping or archiving its session. Add explicit pinning and consider preview opening for casual browsing. Dia strengthens the durable/disposable distinction; it does not prove that Omnigent needs every browser tab-management feature.

**High — Touch targets and light-theme contrast remain measurable defects.** The 34 pt iPad tabs, 16×16 pt close control, 22×26 pt overview control, and 9 pt divider grip need usable touch regions or equivalent accessible actions. Provide 44 pt targets without overlapping neighboring controls, plus a menu alternative to divider dragging. The `#DF3C85` accent calculates to approximately 4.10:1 on white and 3.35:1 on its 15% pink badge background. Give small “Needs you” text a darker semantic foreground; verify white approval labels too. These are token calculations, not measurements of composited screenshots.

**High — Approval content needs more space than its containers.** Screens 9 and 14–16 spend scarce width on nested surfaces while truncating paths and clipping code. Show basename first, directory second, and change counts alongside. Keep horizontal scrolling available, but advertise it and offer wrapping plus full-screen review. One outer card and a differentiated code surface are sufficient. A reviewer should identify every affected file before choosing an approval action.

**Medium — Reduce duplicated decisions and action whitespace.** The dock should navigate to a visible decision card; it should expose decision actions when that card is offscreen. On phones, show one actionable request and the remaining count, with a shared draft and response state. Separately, the Mac’s reserved 28 pt action lane contributes approximately 56–60 pt between short exchanges once other spacing is included. Preserve hover stability while fitting actions into existing inter-message space.

**Medium — Specify typographic rhythm.** Retain 15 pt Mac/17 pt touch prose, 5 pt additional leading, 16 pt paragraph gaps, and 24 pt row gaps as the starting system. Actual line height also includes font metrics. Compare a 640–680 pt default reading column against the current 720 pt using technical prose; retain Wide for code-heavy work. Give headings more space before than after. Preserve first-baseline list alignment.

**Medium — CLI appearance must preserve capabilities.** The 13 pt Mac/15 pt touch defaults and proportional internal leading work, but fixed 14 pt outer gaps and user-band padding should scale coherently. Rich output deliberately returns to prose typography; make the preference’s scope understandable. More significantly, CLI’s model menu lacks agent switching and its composer lacks the chat composer’s host control. A display preference should retain those functions.

**Low — Consolidate surface and icon rules.** The 8/16/20/24 pt radius vocabulary is reasonable; layering all of it inside approvals is not. Make the distinction between always-dark code blocks and theme-following diffs intentional. Consider 13–14 pt Mac action symbols while preserving accessible targets. Align separators with meaningful content columns.

**Medium — Empty states should explain the next action.** Replace “Lifecycle details are in the inspector” with actionable copy such as “Send a message to start this session.” Suppress empty-state heroes during history loading. Server entry needs concise setup guidance or a supported pairing path. Do not interpret screen 7’s inactive-window appearance as proof of broken enabled-state contrast.

**High — Browser handoff needs acknowledgment and recovery.** Keep the ownership strip, then add “Taking control…,” “You’re in control,” and explicit handback acknowledgment. Identify the owning session, distinguish live imagery from reconnecting or stale imagery, and offer Fit/Actual size without stretching the remote viewport. The single “Remote page” accessibility element remains insufficient for semantic page interaction; provide a bridge or an explicit alternative workflow. Competitor evidence makes this a more urgent product requirement.

## 3. Performance

These remain **source-level risks, not measured regressions**. Competitor polish cannot establish that Omnigent is slow or identify its bottleneck.

1. **High — Whole-history transformations.** `ConversationAdapter` maps stored rows; `TranscriptView` rebuilds groups and turn segments; CLI adds another traversal. Lazy rendering does not remove this work. Measure transformation time against history length, then retain settled presentation state by revision and update affected rows or turns.

2. **High — Streaming reparses growing text.** `MarkdownView` bypasses its cache during streaming; `CLISourceText` also parses Markdown and reconstructs attributed text. Repeatedly processing the entire prefix can approach quadratic cumulative work. Coalesce updates, retain settled blocks, and move parsing off the UI actor where practical. Preserve prompt feedback and final-output correctness.

3. **High — Cursor changes can recreate unchanged browser stills.** [RemoteBrowserView.swift](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/Packages/OmnigentRemoteBrowser/Sources/OmnigentRemoteBrowser/View/RemoteBrowserView.swift:106) observes viewport, cursor, and still state together, scheduling image creation on the main actor. Separate cursor/layout updates from image identity, cache unchanged stills, and prepare image data away from the UI thread.

4. **Medium — Environment closures may invalidate settled rows.** Fresh `ConversationActions` and `OpenURLAction` values deserve profiling despite `.equatable()`. `FocusedActionsRelay` addresses another publication path; it does not establish stability for all environment values.

5. **Medium — Large individual messages remain eager.** Nested Markdown stacks, table grids, and previews containing up to 400 diff lines can make one visible row expensive. Benchmark large tables and expanded tool output before choosing bounded expansion or virtualization.

6. **Medium — Geometry updates may multiply work.** Multiple transcript scroll triggers and `BoundedScrollView` height feedback deserve instrumentation during keyboard transitions and split resizing. This is a convergence risk, not evidence of another infinite loop. Measure scroll jumps alongside layout work.

7. **Low–Medium — Accumulated tabs increase rendering costs.** The eager tab `HStack`, favicon creation during rendering, and ongoing status animations become more significant as tabs accumulate. Cache icons and pause hidden or inactive animation, retaining existing Reduce Motion behavior.

Keep stable row IDs, the lazy outer transcript, bounded parse caches, the video path outside SwiftUI observation, and `FocusedActionsRelay`. The preview/gallery `AnyView` hook remains an unsupported explanation for shipped-app CPU.

Measure long-history streaming, two active panes, keyboard appearance, split resizing, and cursor movement over an unchanged remote still. Compare frame hitches, main-thread time, update counts, and idle CPU before and after.

## 4. Competitor ideas

The following replaces the memory-based section. Patterns are attributed only where supported by the supplied evidence.

| Evidence | Implication for Omnigent |
|---|---|
| **[Warp vertical tabs](https://docs.warp.dev/terminal/windows/vertical-tabs)** support pane/tab views, Compact/Expanded density, title choices, search, status badges, and hover detail cards. | **Strengthens** searchable navigation and compact desktop density. Add status previews without changing focus. Distinguish unread attention from unresolved work: visiting may clear a notification dot, but an unanswered request must remain pending. |
| **[Dia](https://www.diabrowser.com/changelog)** distinguishes pinned tabs, closes unpinned tabs together, and supports Focus Mode with splits. Its split gesture uses edge dragging. | **Strengthens** closable views, pinning, and focused-pane expansion. **Changes** the attribution for durable/disposable tabs. Offer drag-to-split alongside a discoverable menu; touch and keyboard users need equivalent routes. |
| **[Safari tabs](https://support.apple.com/guide/safari/tabs-ibrw1045/mac)** offer layout choices, numbered shortcuts, and automatic closure. Apple’s iOS 26 announcement describes shrinking bars during scrolling. | **Supports** content-preserving chrome and predictable navigation. Automatic chat-tab closure needs more care: running work, drafts, and pending decisions should never disappear unexpectedly. These sources do not establish a preferred transcript width or typography. |
| **[Claude Code desktop](https://code.claude.com/docs/en/desktop)** has named pane buttons, split/pop-out controls, a hideable rail, context details, and Normal/Thinking/Verbose transcript modes. | **Strongly strengthens** dedicated review, pane focus, and progressive activity detail. Make tool summaries expandable; expose verbose output without making everyone read it. Claude’s in-place draft editing also supports a sustained artifact-editing destination. |
| **[Codex review](https://learn.chatgpt.com/docs/code-review)** provides scopes including Last turn and per-hunk operations; Zed has a change accordion and review multibuffer; Factory accepts inline diff comments. | **Strengthens** change-oriented review with explicit scope. Show “Last turn” versus “All changes” where supported, and provide a visible “Send review” action. The November 1 table flags Codex’s deferred inline-comment delivery as an anti-pattern. |
| **[Cursor](https://cursor.com/docs/agent/overview)** explicitly separates queueing and sending now, lists queued items, and permits reordering. Claude Code and Copilot also distinguish queued follow-ups from steering. | **Elevates** send-intent clarity. Their shortcuts differ, so copy the explicit semantics rather than mixing bindings. Omnigent already has queue controls; improve discoverability and consistency before introducing another queue surface. |
| **[Copilot sessions](https://github.blog/changelog/2026-03-19-more-visibility-into-copilot-coding-agent-sessions/)** collapse delegated activity while showing current work; Warp marks unattended input waits as blocked and associates command completion with its originating block. | **Strengthens** compact tool narration and addressable activity. Preserve command/result identity and expose meaningful blocked states. This evidence does not establish Warp rerun or copy-output controls. |
| **[Codex remote connections](https://learn.chatgpt.com/docs/remote-connections)** support paired-host supervision but drop sessions when the host sleeps. Claude documents reconnection; Cursor offers “Keep this computer awake.” | **Elevates** host readiness, sleep explanation, reconnect feedback, and draft preservation. QR pairing is useful, but successful pairing alone does not establish reliable remote supervision. |
| **Claude Dispatch, Codex mobile, Cursor mobile, and connected GitHub Copilot**, across both tables, support approval, review, steering, and completion/attention signals. | **Strengthens** an iPhone experience centered on finishing a decision. Add grouped notifications that open the exact request or change set. Treat Live Activities as a focused status surface, with meaningful limits and privacy controls. |
| **[Comet consent](https://www.perplexity.ai/hub/blog/comet-assistant-puts-you-in-control)** distinguishes manual browsing, one-time agent browsing, and automatic browsing. Claude pauses at login/CAPTCHA; ChatGPT’s cloud browser offers takeover and documents credential isolation. | **Elevates** explicit permission scope and acknowledged handoff. Omnigent should distinguish one-time, session, and persistent choices where supported. Do not promise credential isolation unless its architecture actually provides it. |
| **[Linear display options](https://linear.app/docs/display-options)** provide per-view settings with defaults/reset; its refresh dims the sidebar and reduces separators. Raycast supports status-bearing chat search and list navigation. | **Strengthens** configurable session density, restrained secondary chrome, and fast search. Start with a small set of useful display choices. Raycast’s evidence does not establish the earlier claim about contextual shortcut presentation. |

Three availability corrections matter. **ChatGPT agent has been replaced by ChatGPT Work**, and **Atlas is retired**; Atlas’s page-visibility toggle is a historical reference only. **Arc closed new accounts October 22 and schedules sync shutdown November 23 and desktop shutdown December 22, 2026.** Dia is the relevant continuing reference for the tab patterns in this evidence.

**Branching is a concrete opportunity.** Claude’s [merged Chat/Cowork documentation](https://support.claude.com/en/articles/16761823-claude-cowork-and-chat-are-one-claude) says branching from an earlier point is unavailable there. Omnigent’s [ForkAdapter.swift](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/Packages/OmnigentAppUI/Sources/OmnigentAppUI/Adapters/ForkAdapter.swift:63) already identifies settled assistant responses as fork points, with conditional UI wiring in `ConversationContainer`. Improve its discovery, naming, and return-to-source experience; verify availability across supported hosts before advertising it broadly. ChatGPT branching remains **unverified** in your table, so this is not an exclusivity claim.

I withdraw unsupported competitor attributions concerning Cursor preview tabs, Zed’s visual restraint/pane-focus treatment, and generic ChatGPT reading-first typography. The Comet iOS refinement row comes from a secondary report; the older Comet Live Activities claim and partly verified HIG claims retain their qualifications. None drives the ranking below.

## 5. Ranked recommendations

### (a) Small fixes

1. **Restore reliable phone entry.** Remove the blank navigation band, honor the first deliberate tap, and verify settled keyboard clearance. These remain more urgent than new features.
2. **Fix accessibility fundamentals.** Enlarge touch regions, darken attention text in light mode, and label ambiguous actions. Preserve existing keyboard, context-menu, and VoiceOver alternatives.
3. **Recover meaningful labels.** Preserve model names and file basenames; expose directories separately. Show host identity and connection state where they affect the next action.
4. **Reduce redundant presentation.** Make the decision dock contextual, reduce hidden-action whitespace, flatten nested approval surfaces, and normalize heading/CLI spacing.
5. **Clarify existing controls.** Keep queue, steer, and Stop distinct; improve empty/loading copy; make supported message-level forking discoverable. These capabilities should not require learning implementation vocabulary.

### (b) Bigger improvements

1. **Fix tab lifecycle and pane adaptation together.** Closable views, pinning, search, pane-local sizing, and expand/restore form one navigation improvement. Preview opening is an Omnigent proposal requiring usability validation.
2. **Build a complete review destination.** Combine readable file summaries, full-screen narrow-layout diffs, explicit change scope, review submission, and return to the originating request. Keep pending versus submitted feedback unmistakable.
3. **Unify attention semantics across surfaces.** Use consistent states in rows, tabs, Inbox, and notifications. Label count units: “7 requests in 1 session” is legitimate; silently treating request and session counts as interchangeable is not. Add focus-preserving previews.
4. **Bring phone supervision and host recovery forward.** Prioritize exact-request notification routing, host switching/status, sleep explanations, and reconnect behavior. Scope Live Activities around the most actionable work.
5. **Complete browser ownership and permission scope.** Add acknowledged transfer, interruption, stale-image feedback, and supported consent durations. Cache unchanged stills as part of this surface’s performance work.
6. **Make transcript updates incremental.** Profile first, then address full-history transformations, repeated parsing, and row invalidation with representative long sessions.
7. **Unify Chat/CLI capabilities and validate real applications.** Keep host, agent, queue, and review functions consistent across presentations. Use the gallery for component coverage, then verify system behavior in actual apps.

The evidence **weakens the case for adding more persistent chrome**: Claude hides its rail, Dia offers Focus Mode, and Apple shrinks bars. It also weakens any assumption that “remote connected” means “reliably available.” Composer prediction, automatic tab organization, locked chats, and elaborate dashboards remain lower priority than the demonstrated defects.

## 6. Top 10 next changes with owner areas

| Rank | Change and acceptance outcome | Owner areas |
|---|---|---|
| **1** | Fix phone header geometry and first-tap focus; Reply works immediately and the keyboard leaves intentional clearance. | `Adaptive/AppShell`, `ReadingPostureFocus`, input integration |
| **2** | Correct touch targets and light-theme attention contrast without overlapping neighboring actions. | `DesignSystem`, `Tabs`, `SessionList`, decision controls |
| **3** | Close primary-chat views without ending sessions; reopen them predictably and distinguish pinned views. | `OmnigentAppUI/Tabs`, `TabStore` |
| **4** | Adapt each split independently; provide expand/restore and retain content position. | `AdaptiveLayoutWidth`, `TabSplitView`, workspace layout |
| **5** | Deliver readable approval review with full-screen expansion and one coherent action state. | `Decisions`, `DecisionDock`, `OmnigentWorkspaceUI` |
| **6** | Align attention states and count units; add previews that preserve focus and pending requests. | `SessionAttention`, `SessionListStore`, Inbox, desktop attention |
| **7** | Make phone supervision survive host unavailability with explicit status, preserved drafts, and precise notification routing. | `ConnectionStore`, notifications, mobile shell |
| **8** | Complete browser handoff acknowledgment and separate cursor updates from unchanged still decoding. | `OmnigentRemoteBrowser`, browser ownership integration |
| **9** | Measure and reduce long-transcript streaming work while preserving scroll position. | `ConversationAdapter`, `Transcript`, `Markdown`, `CLISourceText` |
| **10** | Align Chat/CLI host, agent, queue, and steering controls; make send intent understandable before activation. | `Composer`, `ComposerAdapter`, `MessageQueue`, `Transcript/CLI` |

To verify the next implementation, run `just apple-run` and `just apple-run-ios`. Immediately tap Reply after opening a session, then inspect settled keyboard clearance. Open ten sessions, close their tabs, and reopen them. Review long filenames and long diff lines in iPad portrait and folded Duo. Repeat with larger Dynamic Type and VoiceOver.

While an agent runs, queue a follow-up, edit it, and choose Send now; confirm the visible result matches the label. Disconnect or sleep the host and verify status and draft recovery. Exercise browser takeover/handback, then fork a settled response on a supported host and confirm the source remains accessible. Profile long-history streaming and cursor-only browser movement separately.
---

# B. Blind first pass

**1. Summary.** The visual direction is working. The purple-black canvas, restrained pink, neutral user bubbles, and compact phone composer now feel like one product. The remaining problems are structural enough that another styling pass alone will not solve them.

In priority order:

1. **Fix phone layout and input reliability.** The blank navigation space, keyboard clearance, and one-second focus rejection make the app feel unfinished.
2. **Resolve tab accumulation and split-pane sizing.** Permanent primary chats create navigation debt; iPad splits retain layouts that need more width.
3. **Make approvals easier to inspect.** Truncated filenames, horizontally clipped diffs, and duplicated decision controls consume the space needed for understanding.
4. **Address measurable accessibility gaps.** Several touch controls miss 44 pt, and the light-theme “Needs you” badge has insufficient calculated contrast.
5. **Profile the actual update paths.** Full-history transformations, streaming Markdown parsing, and repeated remote-image creation deserve attention before more visual effects.

Review dated **2026-11-02**, based on the supplied screenshots and repository source. No files edited, web browsing performed, or runtime profiling conducted. Screenshot dimensions below are estimates unless backed by code.

**2. Fit and finish.** The token system is a sound starting point, but several views escape its rules precisely where space becomes scarce.

- **High — Phone navigation wastes the reading area.** Screens 8 and 11 have excessive space above meaningful content; screen 11 appears to lose roughly **200 pt between the toolbar and large title**. This is not useful breathing room. Conversations should open with a compact title/status header and content immediately below it. Investigate the safe-area overlay in [AppShell.swift:145](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/Packages/OmnigentUI/Sources/OmnigentUIComponents/Adaptive/AppShell.swift:145) together with large-title placement and short-content scroll alignment. The screenshot establishes the symptom; it does not establish which mechanism causes it.

- **High — A deliberate first tap can be rejected.** [ReadingPostureFocus.swift:29](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/Packages/OmnigentUI/Sources/OmnigentUIComponents/Transcript/ReadingPostureFocus.swift:29) clears any focus acquired during the first second after appearance. That includes intentional input. Distinguish automatic focus restoration from a user gesture. “Open, tap, nothing happens” is a substantial quality defect.

- **Medium — The compact composer is right; its surrounding geometry needs verification.** The implemented **48 pt bar**, **36 pt visible Send/Stop circle**, and **44 pt target** are appropriate. Screen 10 nevertheless shows approximately **50–60 pt between the composer and keyboard**. Reproduce after the keyboard settles; target roughly 8–12 pt of intentional clearance. The model label also degrades into “Sam…lanced”: preserve a meaningful short model name or show an agent icon opening a fully labelled configuration sheet. Do not squeeze every metadata field into one line.

- **High — Split adaptation should use each pane’s available width.** The minimum pane is **320 pt**, but regular-width transcript gutters consume **48 pt**, before card padding. iOS’s [AdaptiveLayoutWidth.swift:25](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/Packages/OmnigentUI/Sources/OmnigentUIComponents/Adaptive/AdaptiveLayoutWidth.swift:25) follows horizontal size class rather than measured pane width. Screen 15 consequently looks like two compressed desktop layouts. Use compact gutters and card layouts per pane; provide an obvious focused-pane expansion command. Prefer a single review pane when two useful review columns cannot fit.

- **High — Permanent chat tabs undermine the otherwise good unified strip.** Screens 1–3 establish a clear vocabulary for chats, shells, and browsers. However, [TabStore.swift:107](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/Packages/OmnigentAppUI/Sources/OmnigentAppUI/Tabs/TabStore.swift:107) prohibits closing primary chats. Browsing the sidebar therefore progressively fills the strip. Preserve the session’s canonical conversation while allowing its window tab to close. Add preview-open behavior for casual sidebar browsing, with explicit pinning for persistence. Closing a view must remain distinct from stopping or archiving work.

- **High — Touch targets are inconsistent outside the composer.** [TabItemView.swift:11](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/Packages/OmnigentUI/Sources/OmnigentUIComponents/Tabs/TabItemView.swift:11) specifies **34 pt iPad tabs**, while its close control is **16×16 pt**. The overview menu uses **22×26 pt**; the split-divider grip is **9 pt** wide. Supply 44 pt touch regions without overlapping neighboring actions, and offer a menu alternative to precision divider dragging. Keep small Mac visuals where appropriate. Message actions already support keyboard focus, context menus, and VoiceOver: retain those alternatives.

- **High — Approval payloads are too difficult to read in narrow layouts.** Screens 9, 14–16 devote substantial area to nested containers while losing filename and code content. `FileChangeList` uses `.callout.monospaced()` and head truncation; `DiffView` horizontally scrolls long lines. Horizontal scrolling is legitimate, but the screenshots do not advertise it. Preserve the basename, put the directory on a secondary line, and offer a clearly labelled full-screen review with wrap control. On folded Duo, **466−84 = 382 pt** remains before app gutters. Treat that as a narrow phone layout. Never borrow the system’s trailing status column.

- **Medium — Inline decisions and the dock repeat too much.** Screen 15 duplicates the question and its choices; screen 9 repeats the same approval as a large card plus a Review dock. Keep the dock as navigation while the full card is visible, then expose actions when it scrolls away. On phones, show one actionable request plus a count; the current compact limit of three can consume too much height. Preserve shared drafts and a single response state across both presentations.

- **Medium — Typography needs a rhythm specification, not another font family.** [Theme.swift:8](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/Packages/OmnigentUI/Sources/OmnigentUIComponents/DesignSystem/Theme.swift:8) defines **15 pt Mac / 17 pt touch prose**, **5 pt additional line spacing**, **16 pt paragraph gaps**, and **24 pt row gaps**. These are sensible. Actual line height includes font metrics; it is not simply 20/22 pt. The **720 pt reading column** can produce long lines at 15 pt: compare a 640–680 pt default using real technical prose. Keep Wide for code-heavy work. Lists correctly use first-baseline alignment, but headings need asymmetric spacing: more before, less after, rather than the shared 16 pt block gap.

- **Medium — Hidden Mac actions still create conspicuous whitespace.** In screen 3, short exchanges feel disconnected. The implementation reserves **28 pt** for hidden actions; with the user message’s 4 pt internal gap and 24 pt transcript gap, that adds **56 pt below a bubble**. Assistant action spacing totals roughly 60 pt. Preserve hover stability, but reduce the reserved visual lane or position actions within existing inter-message space. Do not shrink every paragraph to compensate.

- **Medium — CLI style needs functional parity and scalable spacing.** Screens 5–6 capture the terminal character well. Defaults are **13 pt Mac / 15 pt touch**, with extra leading of **0.22×font size**. However, outer block gaps and user-band padding remain fixed at **14 pt**, while internal Markdown gaps scale with font size. Normalize these relationships. Rich output deliberately returns to prose typography, so clarify that the CLI size preference does not resize everything. More seriously, `CLIModelMenu` offers model/effort but no agent switch, and the CLI composer lacks the chat composer’s host control. A presentation preference should not remove capabilities.

- **High — Light-theme attention text needs its own accessible color.** The base pink is `#DF3C85`. Calculated sRGB contrast is approximately **4.10:1 on white**, and **3.35:1 on its 15% pink-over-white badge background**. The latter is below 4.5:1 for the small “Needs you” text in screen 8. Use a darker semantic foreground while preserving the brand fill. White text on the base pink also calculates to 4.10:1, so verify rendered approval labels. These are token calculations, not sampled OS-composited pixels. CLI already adjusts text contrast; extend comparable discipline to chat controls.

- **Low — Surface and icon consistency needs consolidation.** The radius vocabulary is mostly coherent: **8 pt small/medium**, **16 pt cards**, **20 pt bubbles**, **24 pt composer**. Avoid layering all four inside one approval. Use one outer card, a flatter file summary, and a differentiated code surface. Rich code blocks force dark appearance while diff previews follow the surrounding theme; make that distinction intentional and consistent. Message-action glyphs are visually tiny at `.caption`; retain their targets but consider roughly 13–14 pt Mac symbols. Keep separators aligned with text columns rather than alternating full-width and arbitrary insets.

- **Medium — Empty states reveal implementation language.** Screen 2’s “Lifecycle details are in the inspector” explains the framework, not the next useful action. Use “Send a message to start this session,” with relevant host/agent context. Suppress the empty hero while history is loading. Screen 7 is orderly but needs help for someone who does not know their server URL: an organization-provided choice, pairing entry point, or concise setup guidance. Its inactive-window appearance should not be mistaken for broken enabled-state contrast.

- **High — Browser ownership needs a more complete handoff experience.** Screen 4’s ownership strip is a good foundation. Add an acknowledged “Taking control…” state, retain clear “You’re in control / Hand back” language, and identify the owning session when browser titles obscure it. Distinguish reconnecting or stale imagery from live browsing. Letterboxing is expected for a remote viewport; offer Fit/Actual size instead of stretching it. The inspected remote surface exposes a single “Remote page” accessibility element, so accessible page interaction needs a semantic bridge or an explicit alternative workflow.

**3. Performance.** These are source-level risks, ranked by likely impact. They are not measured regressions.

1. **High — Whole-history work on transcript updates.** [ConversationAdapter.swift:24](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/Packages/OmnigentAppUI/Sources/OmnigentAppUI/Adapters/ConversationAdapter.swift:24) maps every stored row into UI state. [TranscriptView.swift:37](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/Packages/OmnigentUI/Sources/OmnigentUIComponents/Transcript/TranscriptView.swift:37) then rebuilds transcript groups and turn segments; CLI adds another traversal. Lazy views do not eliminate these transformations. Cache settled presentation state by revision and update only affected rows/turns.

2. **High — Streaming parsing remains synchronous and repeatedly processes growing text.** [MarkdownView.swift:26](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/Packages/OmnigentUI/Sources/OmnigentUIComponents/Markdown/MarkdownView.swift:26) bypasses caching during streaming. Plain CLI also parses Markdown and rebuilds attributed text in [CLISourceText.swift:155](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/Packages/OmnigentUI/Sources/OmnigentUIComponents/Transcript/CLI/CLISourceText.swift:155). Reprocessing the entire prefix for every small update can approach quadratic cumulative work. Coalesce updates, retain settled blocks, and move parsing off the UI actor where practical.

3. **High — Remote cursor changes can recreate an unchanged JPEG.** [RemoteBrowserView.swift:106](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/Packages/OmnigentRemoteBrowser/Sources/OmnigentRemoteBrowser/View/RemoteBrowserView.swift:106) observes viewport, cursor, and still state together. Every observed change schedules `updateStill()` on the main actor, which creates an image source and CGImage again. Separate cursor/layout observation from still-image changes; cache by still identity and prepare image data away from the UI thread.

4. **Medium — Fresh environment closures can defeat row isolation.** [TranscriptView.swift:96](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/Packages/OmnigentUI/Sources/OmnigentUIComponents/Transcript/TranscriptView.swift:96) injects `ConversationActions` and a new `OpenURLAction`; container updates construct fresh action closures. Profile whether unchanged rows invalidate despite `.equatable()`. The focused-action relay addresses a different publication path. Do not assume that fix stabilizes every environment value.

5. **Medium — Large individual messages remain eager.** [MarkdownView.swift:44](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/Packages/OmnigentUI/Sources/OmnigentUIComponents/Markdown/MarkdownView.swift:44) uses nested `VStack`s and eager table `Grid`s. A lazy transcript still lays out every block inside one enormous visible answer. Diff previews can construct 400 lines. Benchmark large tables and expanded tool output before deciding which blocks need virtualization or bounded expansion.

6. **Medium — Geometry callbacks can multiply work.** [TranscriptView.swift:115](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/Packages/OmnigentUI/Sources/OmnigentUIComponents/Transcript/TranscriptView.swift:115) tracks proximity, content height, and revision, with multiple routes to `scrollTo`. [BoundedScrollView.swift:12](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/Packages/OmnigentUI/Sources/OmnigentUIComponents/DesignSystem/BoundedScrollView.swift:12) feeds measured height back into its frame. Instrument convergence during keyboard changes and split resizing; this is a feedback risk, not proof of another infinite loop.

7. **Low–Medium — Tab costs grow with accumulation.** [TabStripSection.swift:49](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/Packages/OmnigentUI/Sources/OmnigentUIComponents/Tabs/TabStripSection.swift:49) uses an eager `HStack`; [TabItemView.swift:178](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/Packages/OmnigentUI/Sources/OmnigentUIComponents/Tabs/TabItemView.swift:178) constructs favicon images during rendering. Cache images. Running spinners and [Theme.swift:264](/Users/ahirreddy/src/omnigent/.claude/worktrees/apple-native-scaffold/apps/apple/Packages/OmnigentUI/Sources/OmnigentUIComponents/DesignSystem/Theme.swift:264) pulse animations should pause when hidden or inactive, beyond their existing Reduce Motion support.

Keep the existing stable row IDs, lazy outer transcript, bounded parse caches, video path outside SwiftUI observation, and `FocusedActionsRelay`. The `AnyView` environment hook I found belongs to gallery/playground previews; I would not blame it for shipped-app CPU without evidence.

**4. Competitor ideas.** Every observation below is **from memory, unverified**; none asserts current November 2026 behavior.

| Reference | Useful idea for Omnigent |
|---|---|
| **ChatGPT — from memory, unverified** | Reading-first conversations and progressive composer disclosure. Preserve the compact composer; remove surplus header space. |
| **Claude desktop/iOS — from memory, unverified** | Separate sustained reading from task artifacts. Make full-screen review a first-class destination, with easy return to conversation. |
| **Claude Code — from memory, unverified** | Compact tool narration and expandable detail. Preserve semantic activity summaries instead of merely recoloring raw logs. |
| **Codex app — from memory, unverified** | Task-oriented navigation and review context. Surface what needs a decision and what is ready to inspect alongside the transcript. |
| **Cursor — from memory, unverified** | Editor-style preview tabs and change-oriented navigation. Borrow preview opening, pinning, and fast return to changed files. |
| **Warp — from memory, unverified** | Treat terminal output as addressable blocks. Offer copy-output, rerun/open-context where supported, and reliable block navigation. |
| **Zed — from memory, unverified** | Restrained chrome and explicit pane focus. Give keyboard commands one obvious destination without brightening the entire interface. |
| **GitHub mobile / Copilot agents — from memory, unverified** | Notification-to-diff-to-response workflows. Let a phone user finish one review decision without navigating several representations of the same task. |
| **Linear — from memory, unverified** | Dense, consistent rows and predictable triage. Add a compact desktop session density with optional repository metadata. |
| **Raycast — from memory, unverified** | Search with contextual actions and visible shortcuts. Extend the palette into a fast session/tab switcher. |
| **Arc / Dia — from memory, unverified** | Distinguish durable workspace context from disposable browsing. Session-owned tab groups should communicate ownership without making every chat permanent. |
| **Perplexity Comet — from memory, unverified** | Browser-plus-agent interaction emphasizes task context. Keep ownership, task intent, interruption, and handback visible together. |
| **Apple Mail, Notes, Messages, Safari — from memory, unverified** | Borrow list/detail adaptation, readable text, compact input, searchable tab overviews, and reversible split controls. Preserve system behavior before adding custom chrome. |

**5. Ranked recommendations.** I agree with the roadmap’s attention hierarchy, compact composer, and payload-first approvals. I disagree with treating Phases 1–2 as finished acceptance criteria: the screenshots still expose input, sizing, contrast, and review defects. Bring browser handoff reliability forward because that surface already ships. Defer a separate Mission Control canvas until existing lists, tabs, and decisions feel dependable.

**Small fixes, in order:**

1. Remove accidental phone header space and fix focus rejection — `Adaptive/AppShell`, `ReadingPostureFocus`.
2. Correct badge contrast and touch targets — `DesignSystem`, `SessionList`, `Tabs`.
3. Preserve readable model names and filenames — `Composer`, `Decisions`.
4. Reduce redundant action/dock spacing — `MessageActionRow`, `DecisionDock`.
5. Replace implementation-oriented empty copy and test loading transitions — `TranscriptBanners`, `OmnigentAuthUI`.

**Larger improvements, in order:**

1. Separate session lifetime from window-tab lifetime — `OmnigentAppUI/Tabs`.
2. Introduce pane-local adaptation and focused review expansion — `TabSplitView`, `Adaptive`, `OmnigentWorkspaceUI`.
3. Make transcript updates incremental and remote still handling change-driven — adapters, Markdown, `OmnigentRemoteBrowser`.
4. Unify Chat/CLI capabilities beneath their presentation differences — `Composer`, `Transcript/CLI`.
5. Use the gallery for coverage, with real-app verification of safe areas, keyboard behavior, focus, and accessibility. Its simulated device frames cannot certify those behaviors.

**6. Top 10 next changes.**

1. Eliminate the phone’s blank navigation band — **`Adaptive/AppShell.swift`**.
2. Honor the first deliberate composer tap — **`Transcript/ReadingPostureFocus.swift`**.
3. Allow closing primary-chat window tabs without ending sessions — **`OmnigentAppUI/Tabs`**.
4. Adapt gutters and cards to each split pane — **`TabSplitView`, `AdaptiveLayoutWidth`**.
5. Provide 44 pt touch targets for tabs and their actions — **`Tabs`**.
6. Darken light-theme attention text to accessible contrast — **`DesignSystem`, `NeedsYouCapsule`**.
7. Add readable filename summaries and full-screen approval review — **`Decisions`, `OmnigentWorkspaceUI`**.
8. Reduce repeated decision controls and hidden-action whitespace — **`DecisionDock`, `MessageActionRow`**.
9. Cache unchanged remote stills and remove image preparation from cursor updates — **`OmnigentRemoteBrowser`**.
10. Profile and reduce full-history work during streaming — **`ConversationAdapter`, `Transcript`, `Markdown`**.

To verify the next pass, launch with `just apple-run` and `just apple-run-ios`. Open a session and immediately tap Reply; send a short message; inspect keyboard clearance; open ten sessions and close their tabs; review a long-filename diff in iPad portrait and folded Duo. Repeat with larger Dynamic Type and VoiceOver. Profile a long transcript streaming in two panes and a remote browser during cursor movement; record frame hitches, main-thread work, and idle CPU before and after.