# Native app UI/UX roadmap (from competitor research)

Review 3 (2026-11-02) comes first: three independent reviews of the app after Phases 1–2. The
sections after it are review 2, a synthesis of two independent reviews written on 2026-11-01, both
based on the same screenshots of the then-current app:
- [Claude](ux-research/2026-11-01-claude-ux-review.md): it did the web research, with 40 competitors
  cited.
- [Astra / gpt-6-astra](ux-research/2026-11-01-astra-ux-review.md): it wrote its review independently,
  then revised it against the verified competitor table only.

## Review 3 (2026-11-02)

Three independent reviews of the app as it stands after Phases 1–2 (titlebar tab strip and split
view, CLI style, hover actions and fork, compact iPhone composer, emphasis discipline, gallery,
remote browser tab, iOS Appearance settings):
- [Claude](ux-research/2026-11-02-claude-ux-review-3.md): real-app captures on iPhone 17 Pro, iPad
  Pro 13 and the folded iPhone Duo simulators and the Mac, the gallery export, measured contrast,
  and `xctrace` profiles. It also did the web research for the shared competitor table.
- [Astra / gpt-6-astra](ux-research/2026-11-02-astra-ux-review-3.md): 16 screenshots and the
  repository, blind; then revised against the verified competitor table only (it can't browse).
- [Fable](ux-research/2026-11-02-fable-ux-review-3.md): the captures, the gallery export, the
  code, and its own web research.

None of the three read another's conclusions before writing. The visual direction holds. What is
left is **finish** (rhythm, type scale, contrast, touch targets, duplicated surfaces), **phone
geometry**, and **the cost of a running session**.

### Where all three agree

1. **The Mac transcript's rhythm is too loose.** A hidden 28 pt action row is reserved under every
   message, on top of the 24 pt turn gap, so an answer and the next question sit about 55–60 pt
   apart. Overlay the actions; target ≤ 32 pt.
2. **Heading spacing needs asymmetry, and the scale must be relative to body.** Claude and Fable
   both found Mac `###` at 13 pt and `####` at 11 pt under 15 pt prose; all three want more space
   above a heading than below it.
3. **A decision shows twice.** The inline card and the dock show the same request with the same
   buttons at once (iPhone, folded Duo, iPad split). When the inline card is on screen, the dock
   collapses to a one-line summary; when it scrolls away, the dock expands.
4. **The iPhone conversation wastes its top.** There is a 110–200 pt empty band between the bar
   and the content, and the large title lands mid-screen. Claude suspects the bottom scroll anchor
   (`defaultScrollAnchor(.bottom)`) in short transcripts; `follow-ups.md` suspects
   `TitlebarBackdrop`. Fix it before adding anything to the bar.
5. **Approval payloads are hard to read on narrow widths.** 16 pt monospace on iPhone clips diffs
   after about 25 characters and truncates paths from the front. Use basename first, smaller code
   (about 13 pt), scroll or wrap with a visible affordance, and a full-screen review.
6. **Touch targets.** The iPad tab close button is 16 × 16 pt in a 34 pt tab. Astra adds the 22 ×
   26 pt overview button and the 9 pt split-divider grip.
7. **Light-theme accessibility.** Measured: white text on the pale-pink selected sidebar row
   (1.34:1, Claude), the "Needs you" capsule text (3.35:1, Claude and Astra), and pink-on-pink for a
   selected needs-you row (Fable). Fable also found system blue leaking into light mode.
8. **Empty states speak implementation.** "Lifecycle details are in the inspector" and three
   different Otto headings in one split window. One heading; the second line says what to do next.
9. **The transcript does avoidable work per update.** The segments are recomputed in `body` on
   every revision. A fresh `OpenURLAction` and a closure-valued `ConversationActions` sit in the
   environment, which is the `FocusedActionsRelay` problem one level down. Favicons decode in
   `TabItemView.body`.
10. **Off-grid literals and mixed radii.** Enforce the 4 pt grid and a radius set (concentric
    inner radii in cards) with a lint.
11. **Transcript detail should be a user setting** (Claude desktop Normal / Thinking / Verbose,
    Cursor Compact / Balanced / Detailed, Copilot's collapsed sub-agent HUD). This is separate from
    Plain / Styled / Rich.
12. **The remote browser needs finishing.** Claude and Fable want the host viewport resized to the
    pane (today it letterboxes); Astra accepts letterboxing with a Fit / Actual size choice. All
    three want clear take-over and hand-back states and human-readable host errors.

### Where two agree

- **Streaming re-parses the whole message per delta** (Astra, Fable): `MarkdownView` bypasses its
  cache while streaming, and `CLISourceText` re-tints the whole text. That is quadratic over a
  reply. Parse the stable prefix once and only the tail per delta.
- **Primary-chat tabs can't be closed, so the strip fills up** (Astra High; Claude in "tab strip
  v2"). Separate the session's lifetime from its tab: closable views, explicit pinning, maybe
  preview tabs.
- **The iPhone composer** (Claude, Astra): the model chip is capped at 96 pt ("Sam…lanced") beside
  free space, and the new-session composer floats about 60 pt above the keyboard.
- **Phone supervision and host reliability** (Claude, Astra): actionable notifications routed to the
  exact request, QR pairing, and visible host status with reconnect. Fable notes that the server
  model avoids "the host must stay awake", but a local runner still lives on a machine that sleeps.
- **The CLI composer lacks the chat composer's host chip and agent switch** (Claude, Astra; a known
  follow-up). A presentation setting must not remove capabilities.
- **The iPhone Tabs list shows raw agent ids** ("tabs_fixture_agent") and no state (Claude, Fable).
- **Persistent copy icons on touch** float orphaned under the bar or at mismatched heights (Claude,
  Fable). Keep them in the long-press menu.
- **Inline code reads too large** (Claude, Fable). It is SF Mono at full body size, larger than the
  12 pt code blocks on the Mac.
- **Two review-1 leftovers** (Claude, Fable): the dashed "Message content" placeholder, and the
  Working / Interrupted / Responding states at three indents with three glyphs.
- **Fork is now a differentiator** (Claude, Astra): Claude's merged app removed branching from an
  earlier point. Make Fork discoverable and keep the way back to the source.
- **Pause looping animations when hidden or inactive** (Astra, Claude). Fable says the mascot
  shouldn't be the working indicator.

### Notable single-reviewer ideas

- **Claude (measured):** a working session costs **13–15% of a core while idle** on the Mac (Debug),
  all of it SwiftUI redrawing the looping indicators every frame (Otto's bob, the typing dots, the
  live dot, the rotating tool symbol). Fable expected Otto's offset bob to be cheap; the profile
  shows the combined per-frame display-list and constraint updates aren't.
- **Claude:** the 3,000-row transcript spends about 11% of its first layout in `TurnSegment ==`,
  because `.equatable()` compares whole row arrays.
- **Claude:** the Mac Connect window ignores the theme, lists `127.0.0.1:port` twice, and opened
  two identical windows. `-OmnigentDemo` lands on Connect on the Mac and the Duo.
- **Claude:** the iPhone has no visible way to Settings or Appearance (they are in the server menu).
  Mail and Notes on iOS 26 put New and search at the bottom.
- **Astra:** honor the first deliberate composer tap (`ReadingPostureFocus` drops focus for 1 s),
  and adapt gutters per split pane by measured width, not size class.
- **Astra:** separate cursor updates from still-image decoding in `RemoteBrowserView`, and give the
  remote page an accessibility bridge.
- **Astra:** compare a 640–680 pt reading column against today's 720 pt.
- **Fable:** an unread dot that clears on focus (Warp). Dimming the inactive split pane (Claude
  Code) was tried and dropped: both panes look the same.
- **Fable:** elapsed time on the live turn in both styles ("Working · 12s"), and "Worked for 3s"
  under chat answers as CLI already shows.
- **Fable:** one banner grammar for failure, connection and delivery errors; humanize raw host
  errors such as the x264 message.
- **Fable:** a chat text-size setting next to the CLI one; Standard / Comfortable line-height
  presets (Zed).
- **Fable:** a single scroll-to-bottom path per delta; key `MarkdownCache` by row id, not the full
  text.

### Fit-and-finish fixes (small, high impact), ranked

1. **iOS selection and section-header contrast:** stop the system's white selected label over the
   theme's pale fill (1.34:1), and use `.secondary` for "Pinned"/"Sessions" (1.7:1 today).
   `SessionList/SidebarSelection.swift`, `SidebarView.swift`.
2. **Top-anchor short iPhone transcripts and remove the empty band under the bar.**
   `Transcript/TranscriptView.swift`, `Transcript/CLI/TranscriptAppearance.swift`
   (`TitlebarBackdrop`), `Adaptive/AppShell.swift`.
3. **Overlay the Mac message actions** (no reserved 28 pt row; answer to next bubble ≤ 32 pt).
   `Transcript/MessageActionRow.swift`, `Theme.Spacing.row`.
4. **One decision surface at a time.** `Transcript/ConversationScreen.swift`, `Decisions/` (dock).
5. **Heading scale relative to body (1.5 / 1.25 / 1.1 / 1.0×), 24 pt above and 8 below;
   inline code at 0.9 × body.** `Markdown/MarkdownView.swift`, `Markdown/MarkdownDocument.swift`.
6. **Darker light-theme "needs you" foreground** (about `#B8236A`, 4.9:1 on the capsule) and no
   system blue. `DesignSystem/ThemeColor.swift`, `NeedsYouCapsule`, `OmnigentAuthUI/Views/AuthBannerView.swift`,
   `Inspector/WorkspaceInspector.swift`.
7. **44 pt touch targets** for the tab close, the overview button and the split divider.
   `Tabs/TabItemView.swift`, `Tabs/TabOverview.swift`, `Tabs/TabSplitView.swift`.
8. **Compact-width code and diffs:** 13 pt mono, basename first, scroll with an edge fade or wrap.
   `DesignSystem/Theme.swift` (`Typography.code`), `Decisions/DecisionCardParts.swift`,
   `OmnigentWorkspaceUI/Views/DiffRows.swift`, `Transcript/CLI/CLIStyledMarkdown.swift`.
9. **iPhone composer:** let the model chip take the free width; pin the new-session composer to the
   keyboard; honor the first tap; a read-only session shows no field.
   `Composer/ComposerCompactBar.swift`, `NewSession/NewSessionPage.swift`,
   `Transcript/ReadingPostureFocus.swift`.
10. **One empty-state heading and one banner grammar.** `NewSession/NewSessionPage.swift`,
    `Transcript/TranscriptBanners.swift`, `Composer/ComposerParts.swift`.
11. **Remove persistent copy icons on touch;** fix the "Message content" placeholder and the three
    status indents. `Transcript/MessageActionRow.swift`, `Transcript/MessageViews.swift`,
    `Transcript/TurnViews.swift`.
12. **iPhone Tabs list:** display names, state dots, separate + and Done. `Tabs/TabOverview.swift`.
13. **Mac Connect window:** theme canvas, "This Mac" for loopback, one window.
    `OmnigentAuthUI`, `Apps/Omnigent-macOS`.
14. **Server name next to its status dot** (`frame(maxWidth:)` centres it today).
    `SessionList/SidebarParts.swift:51`.

### Bigger improvements, ranked

1. **Phone supervision (start of Phase 3):** actionable notifications that open the exact request
   (Approve / Deny / Reply, grouped by session), QR pairing, and visible host status with reconnect
   and preserved drafts. Then an "Agents" Live Activity scoped to the most actionable work.
   *Claude, Astra.* `Apps/Omnigent-iOS`, `OmnigentAppUI`, `ConnectionStore`, server APNs.
2. **A streaming-first transcript pipeline:** folding, markdown parsing and diff detection move
   into the adapter, keyed by revision, producing immutable segments with pre-parsed blocks and a
   stable environment. *All three.* `OmnigentAppUI/Adapters/ConversationAdapter.swift`,
   `Transcript/`, `Markdown/`.
3. **A measured design system:** a type ramp from one base size per platform, a 4 pt spacing
   scale, concentric radii, named text roles, and a lint that fails on literals; the gallery's
   Type entry becomes the spec. *Claude, Fable.* `DesignSystem/`, `Gallery/Catalog/CatalogDesignSystem.swift`.
4. **Transcript detail and text size:** Normal / Thinking / Verbose (⌃O) with a collapsed
   sub-agent HUD, plus a chat text size. *All three.* `Transcript/CLI/TranscriptAppearance.swift`,
   `TranscriptSettings.swift`, `Transcript/ToolViews.swift`, `SubagentGroupView.swift`.
5. **Tabs and splits v2:** closable primary chats with pinning, pane-local layout by measured
   width, focus dimming, an unread dot that clears on focus, a 140 pt minimum width with a hover
   card, and Option-click to open in split. *Astra, Fable, Claude.* `OmnigentAppUI/Tabs/TabStore.swift`,
   `Tabs/`, `Adaptive/AdaptiveLayoutWidth.swift`.
6. **A review destination:** full-screen review on narrow layouts, explicit scope (Last turn / All
   changes), "Send review" with acknowledgement, and a way back to the originating request. Builds
   on roadmap item 20. *Astra, Claude.* `Decisions/`, `OmnigentWorkspaceUI`.
7. **Own "the agent is browsing":** the host viewport resized to the pane, acknowledged take-over
   and hand-back, a pulsing frame and agent cursor, Allow once / Always / Deny per site, credentials
   typed during take-over kept from the model. *All three.* `OmnigentRemoteBrowser`, `browser-host/`.
8. **Queue v2:** queued items listed under the running turn, drag to reorder, Edit / Send now /
   Remove (Cursor). Astra would improve discoverability of the existing controls first. *Claude.*
   `Composer/QueueStrip.swift`.

Deferred again: the Mission Control canvas (Astra: make lists, tabs and decisions dependable first).

### Performance findings

Measured (Debug builds, on a loaded machine; the shape matters more than the absolute numbers):

| Scenario | Result |
|---|---|
| iPhone 17 Pro / iPad Pro 13 simulators, demo, approval-blocked conversation, idle | 0.0% CPU; 336 / 314 MB RSS |
| iPhone, sending a message | 24–29% for ~2 s, then 0.0% |
| Mac, 3,000-row transcript (playground), first layout | Main thread busy ≈ 1.8 s, one 254 ms microhang, then 0.0%; `TurnSegment ==` ≈ 11% and `segments(for:)` ≈ 5% of main-thread samples |
| Mac, Streaming Turn with nothing arriving | **13–15% CPU sustained**: SwiftUI display-list and `NSHostingView` constraint updates every frame for the looping indicators |

Hotspots in the code, merged and ranked:
1. Looping indicators: `OttoView.swift:43`, `TypingIndicator` and `LiveIndicator` in
   `Theme.swift`, `CLILines.swift:49`, `.symbolEffect(.rotate)` in `ActivityRowViews.swift:199`, and
   a mini `ProgressView` per running row and tab (`SessionRow.swift:88`, `TabItemView.swift:226`).
   One indicator per visible turn, render-server effects, paused when the window isn't active.
2. Unstable environment values: `OpenURLAction` built in `TranscriptView.body` and
   `conversationActions` (closures). Use the `FocusedActionsRelay` pattern.
3. Per-revision work in `TranscriptView.body`: segments, decorations, `lastAnswerID`, and deep
   `TurnSegment` equality. Memoize on revision and compare by identity plus revision.
4. Streaming parse of the whole message per delta in `MarkdownView` and `CLISourceText`.
5. Two scroll-to-bottom paths per delta (`onScrollGeometryChange` and `onChange(of: revision)`).
6. `MarkdownCache` keyed by full text with O(n) FIFO eviction; offset-keyed markdown block
   `ForEach`es that lose identity when a streamed paragraph splits.
7. Remote browser: cursor changes re-create the unchanged still on the main actor.
8. Favicon decode in `TabItemView.body`; per-layout `frame(in: .global)` writes in `TabStrip`.

Already fixed or fine: the focused-value loop (`FocusedActionsRelay`), the cached CLI palette, lazy
rows with stable ids, the `TimelineView`s at 30 s and 60 s. `Theme.relativeDate` is dead code.

### Roadmap items already done

| Item | Status after review 3 |
|---|---|
| 1. One "needs you" signal | Done. Gap: the iPhone Tabs list shows no state. |
| 2. Emphasis discipline | Done. Gaps: system blue in light mode; light pink below 4.5:1. |
| 3. Approval-mode chip | Done ("Ask first / Auto-edit / Full access", ⇧Tab). |
| 4. Agent-first configuration | Partly: the iPhone chip truncates to 96 pt; CLI has no agent switch. |
| 5. Execution context row | Done. The iPhone new-session page shows the host twice. |
| 6. Label ambiguous controls | Partly: inspector tabs are still icon-only; the fork glyph reads as "Y". |
| 7. Approval card v2 | Done. Narrow-width readability is open. |
| 8. Dock compact/expanded | Done. It duplicates the visible inline card. |
| 9. Inbox triage | Done (J/K/E, arrows). |
| 10. Queue / steer / stop | Done. |
| 11. Live sub-agent groups | Done. |
| 12. iPhone reading posture | Partly: short transcripts float, and the first tap is dropped for 1 s. |
| 13. ⌘K and ⌘/ | Done. |
| 14. Workspace and terminal navigation | Done (terminals are tabs). |
| 15. Real-app parity | Done, with the gaps above. |
| 16–18. Notifications, Live Activity, widgets, continuity | Not started (no `ActivityKit`, `UNNotificationAction`, `AppIntents`, `CoreSpotlight`, `NSUserActivity` or `WidgetKit`; no iOS notifications at all). |
| 19–21. Mission Control, review mode, goals | Not started. |
| 22. Trusted agent browsing | Started: the remote browser tab with "Agent is browsing · Take Over". |

### Top 10 changes to do next

Each is sized for one implementation agent. Owner areas are paths under
`apps/apple/Packages/OmnigentUI/Sources/OmnigentUIComponents/` unless they say otherwise.

| # | Change | Done when | Owner area |
|---|---|---|---|
| 1 | **iPhone conversation geometry:** top-anchor short transcripts, no empty band under the bar, the large title under the toolbar, the first composer tap honored | A one-message conversation starts directly under the bar; tapping Reply right after opening focuses it | `Transcript/TranscriptView.swift`, `Transcript/CLI/TranscriptAppearance.swift` (`TitlebarBackdrop`), `Adaptive/AppShell.swift`, `Transcript/ReadingPostureFocus.swift` |
| 2 | **Light-theme accessibility:** selected sidebar row, section headers, a darker "needs you" foreground, no system blue | Every text role ≥ 4.5:1 in the gallery contrast check, light and dark | `SessionList/SidebarSelection.swift`, `SessionList/SidebarView.swift`, `DesignSystem/ThemeColor.swift`, `NeedsYouCapsule`, `OmnigentAuthUI/Views/AuthBannerView.swift`, `Inspector/WorkspaceInspector.swift` |
| 3 | **Transcript rhythm and type:** overlaid Mac actions, prose-relative heading scale with asymmetric spacing, inline code at 0.9 × body | Answer-to-next-bubble ≤ 32 pt on Mac; no heading smaller than body | `Transcript/MessageActionRow.swift`, `Markdown/MarkdownView.swift`, `Markdown/MarkdownDocument.swift`, `DesignSystem/Theme.swift` |
| 4 | **One decision surface, readable on narrow widths:** the dock collapses while the inline card is visible; basename-first paths; 13 pt code with scroll/wrap; full-screen review | One Approve on screen at a time on iPhone and the folded Duo; a 60-character diff line is reachable | `Transcript/ConversationScreen.swift`, `Decisions/`, `OmnigentWorkspaceUI/Views/DiffRows.swift` |
| 5 | **Running-session CPU:** one render-server working indicator per visible turn, paused when the window is inactive; a static glyph for running rows and tabs | A Mac with a working but silent session idles under 2% (Release) | `DesignSystem/OttoView.swift`, `DesignSystem/Theme.swift` (indicators), `Transcript/TurnViews.swift`, `Transcript/ActivityRowViews.swift`, `Transcript/CLI/CLILines.swift`, `SessionList/SessionRow.swift`, `Tabs/TabItemView.swift` |
| 6 | **Transcript update cost:** stable `openURL` and `ConversationActions` (relay), memoized segments with identity-plus-revision equality, one scroll path, incremental streaming parse | `MarkdownView.body` evaluations per delta stay constant as the reply grows; `TurnSegment ==` gone from the 3,000-row profile | `Transcript/TranscriptView.swift`, `Transcript/MessageViews.swift`, `Transcript/TurnLayout.swift`, `Markdown/`, `Transcript/CLI/CLISourceText.swift`, `OmnigentAppUI/Screens/ConversationContainer.swift` |
| 7 | **Touch and tabs:** 44 pt tab close, overview and divider targets; closable primary-chat tabs with pinning; display names and state in the iPhone Tabs list | Ten sessions opened and closed leave the strip as it was; no touch target under 44 pt | `Tabs/TabItemView.swift`, `Tabs/TabOverview.swift`, `Tabs/TabSplitView.swift`, `OmnigentAppUI/Tabs/TabStore.swift` |
| 8 | **iPhone composer and new session:** model chip uses the free width; composer pinned to the keyboard; read-only sessions show no field; no orphan copy icons on touch | "Sample Codex · Balanced" fits on an iPhone 17 Pro; 8–12 pt above the keyboard | `Composer/ComposerCompactBar.swift`, `Composer/ConfigurationMenu.swift`, `NewSession/NewSessionPage.swift`, `Composer/ComposerView.swift`, `Transcript/MessageActionRow.swift` |
| 9 | **States and copy:** one empty-state heading, one banner grammar, elapsed time on the live turn in both styles, humanized remote-browser errors, the "Message content" placeholder and status indents fixed | No implementation language on any empty or error state in the gallery | `NewSession/NewSessionPage.swift`, `Transcript/TranscriptBanners.swift`, `Transcript/TurnViews.swift`, `Transcript/CLI/CLIActivityViews.swift`, `Transcript/MessageViews.swift`, `Composer/ComposerParts.swift`, `OmnigentRemoteBrowser/View` |
| 10 | **Phone supervision, first slice:** actionable iPhone notifications (Approve / Deny / Reply, grouped per session, opening the exact request) and QR pairing from Mac Settings | Approving a pending request from the Lock Screen works end to end on a physical iPhone | `Apps/Omnigent-iOS`, `OmnigentAppUI`, `OmnigentStores` (attention), server APNs |

Next after these: the design-system lint (bigger improvement 3), transcript detail modes (4), and
remote browser viewport resize with take-over states (7).

### Where the reviewers disagree

- **Letterboxing in the remote browser:** resize the host viewport (Claude, Fable) or keep it and
  offer Fit / Actual size (Astra). Resizing matches every competitor that streams a browser.
- **Live Activities:** Claude ranks an "Agents" Live Activity high; Fable warns that Cursor's
  eight-activity cap is a limit, not a goal; Astra scopes it to the most actionable work. Start
  with notifications.
- **Reading column:** Astra suggests testing 640–680 pt against today's 720 pt; Claude and Fable
  keep 720.

### Bars: glass decision

Claude, Astra and Fable agreed (2026-11-02), with "be like a normal iOS app first":

- **System bars.** The Mac titlebar row and the iOS navigation bar are the system's: no themed
  backdrop, background visibility automatic, inline titles. Content scrolls under them with the
  soft scroll edge effect; themes come through the content canvas and restrained accents.
- **Bottom bar.** The dock and composer are a `safeAreaBar` with a soft bottom edge. The composer
  card is Liquid Glass (`Glass.regular`, never `.clear` over transcripts, no nested glass); the
  decision dock and detailed payloads stay opaque cards. The bar's gaps take clicks so nothing
  clicks through.
- **Fallbacks.** If dense text competes with the Mac tab labels, use `.hard` for the Mac top edge
  before restoring a solid backdrop; `.hard` on iPhone only if the subtitle reads faint over code.
- **Accessibility.** Custom glass goes solid under Reduce Transparency and gains a border and a
  near-opaque tint under Increase Contrast; system bars handle both themselves.

---

The sections below are from review 2 (2026-11-01).

## Review 2: where both reviews agree

The visual direction works: ChatGPT-calm reading, pink accent, purple-black canvas, Otto used
sparingly. The gap is **attention**. Omnigent's users run several long-lived agents and need to see
at a glance:
- what each agent is doing
- what needs them
- what is ready to review

Competitors have converged on this:
- Claude Code agent view: Needs input / Working / Completed.
- Codex: Activity view and phone Tasks / Approve / Review.
- Cursor iOS: Live Activities for up to 8 agents.
- GitHub: Mission Control.
- Warp: tab state badges.

Omnigent already has the parts (Inbox, Running, Needs response, decision dock, menu bar extra, Dock
badge), but they don't yet add up to one signal. The iPhone app also has none of the system surfaces
where a phone-based agent supervisor is useful.

Both reviews independently recommend:
- one consistent "needs you" state everywhere
- less pink
- agent-first configuration
- approvals that show the payload and can be redirected
- Inbox as a triage tool
- live sub-agent groups
- ⌘K
- phone reading posture
- actionable notifications and a Live Activity
- a review loop
- a multi-session "Now / Mission Control" board
- trusted agent browsing with visible control and takeover

## Phase 1: clarity quick wins (small effort, high impact)

1. **One "needs you" signal.**
   - Use one state order (Needs you > Failed > Working > Unread) in the session row, Inbox, sidebar
     counts, Dock badge, menu bar and notifications.
   - Counts must agree. Today the approvals capture shows 7, 1, 3 and 4 for the same thing.
   - A session blocked on a decision must not show a running spinner.
   - Add a single header status line, for example `Running · Testing auth changes`,
     `Waiting for you · 2 requests` or `Finished · 3 files changed`.
2. **Emphasis discipline.**
   - Brand pink is only for "needs you" and the single primary action.
   - Share becomes a normal toolbar item.
   - Error and warning states keep their labelled semantic treatments.
3. **Approval-mode chip.**
   - "Approve for me" reads like a button that approves the pending request. Rename the modes, for
     example "Ask first" / "Auto-edit" / "Full access".
   - Give it a shield symbol and risk tint, ⇧Tab cycling with a short HUD, and keep it visibly
     separate from sandbox scope.
4. **Agent-first configuration.**
   - Order the controls Agent → Model → Effort, offering only valid choices.
   - Never show a bare "Default"; show what it resolves to. This is the meta-harness
     differentiator.
5. **Execution context row.**
   - A compact `Codex · Mac Studio · omnigent / auth-refresh` in the composer and on the new-session
     page, with details on demand.
   - Use the server's display name, not `127.0.0.1`.
6. **Label every ambiguous control:** host, context ring, expand, queue and the inspector tabs. Make
   sure every essential action is reachable without hover, for VoiceOver and touch.

## Phase 2: core flows (medium effort)

7. **Approval card v2.**
   - Payload first: the command, the files with +/− counts, or the plan.
   - One primary action, **Approve** (⌘↵).
   - **Reject**.
   - **Tell the agent instead**.
   - **More approval options…** for permission widening, which keeps its confirmation.
8. **Decision dock with compact and expanded states.** Show one-line summaries plus a selectable
   request list instead of arrows only. Substantial phone forms open in a native sheet.
9. **Inbox as triage.** Show the exact question and how long it has waited, resolve in place, then
   advance to the next item. Add J/K/E keys on Mac and swipe actions on iPhone. Keep unread and
   unresolved separate.
10. **Queue, steer and stop made explicit.** Label each choice ("Queued · after this turn" vs "Send
    now · steer"). Queued items get Edit, Send now and Remove. Stop is always available.
11. **Live sub-agent groups.** Show `2 agents · 1 running · 1 ready`, expandable to goals and
    decisions. A blocked child must be answerable from the parent.
12. **iPhone reading posture.**
    - Existing runs open with the keyboard hidden.
    - Drafts are preserved.
    - Jump to latest.
    - Incoming output never moves the user's reading position.
    - Primary actions sit in the thumb zone.
13. **⌘K palette and ⌘/ shortcuts sheet.** Start small: Find session, New session, Next request
    needing response, Open Changes, Switch server, Focus composer.
14. **Workspace and terminal navigation.** Terminals become real tabs, agent-owned terminals are
    distinguished from user terminals, and terminal or file work can expand into the main pane.
15. **Real-app parity.** Bring the shipped Mac and iPhone apps up to the playground: the context
    tray, mode chip, header actions and titlebar material. Add a "verify in the real app" step to
    every polish pass.

## Phase 3: platform integration (larger effort; partly needs server work)

16. **Actionable notifications.**
    - Approve (requires authentication), Deny and Reply.
    - Grouped per session, with child sessions rolled into the parent.
    - Per-type toggles.
    - Re-check that a request is still current before acting on it.
17. **"Agents" Live Activity and widgets.**
    - Show `3 working · 1 needs you` on the Lock Screen and in the Dynamic Island.
    - On macOS Tahoe it also appears in the Mac menu bar.
    - Show titles only; no commands or paths.
    - Add a "Needs you" widget and a Control Center control for a new session.
    - Needs server-side APNs; NativeLab's server branch has a starting point.
18. **Continuity.**
    - Handoff per session.
    - Spotlight indexing of sessions.
    - App Intents ("What needs me?", "Start session in repo…").
    - QR pairing from Mac Settings to the phone.

## Phase 4: bigger bets

19. **"Now" / Mission Control.** Canvas becomes a state board (Needs you / Working / Ready for review
    / Done) with peek-to-answer, a dense list mode, and stable positions. It is a separate window on
    Mac and the home screen on iPad.
20. **Review mode and the end-of-task review package.**
    - A full-window review per session with Last-turn scope, a split or unified diff, comments sent
      to the agent with delivery acknowledgement, checks, and Merge or "Watch and fix".
    - Each finished task produces a review package: summary, revision, test evidence and artifacts.
21. **Goals and checkpoints across harnesses.** Show the objective, plan, checkpoints and remaining
    work instead of a perpetual spinner. Only show controls the selected harness supports.
22. **Trusted agent browsing.**
    - A visible agent cursor and an "Agent is browsing · Take over" banner.
    - A tab group and clean profile per session.
    - Per-site consent.
    - Pause for the human at login and CAPTCHA pages.

## What not to copy (both reviews)

- Approvals that require attaching to a session to answer.
- Diff comments held until the next message.
- Phone features that assume a laptop stays awake.
- Read-only sub-agent views.
- Floating mascot or "pet" status UI.
- In-window toast stacks.
- Surface sprawl. Merge Inbox, Canvas and the filters before adding more.
- Marketing model names and a bare "Default".
- Sensitive text or rich controls in Live Activities.
- An agent browser running in the user's real profile.
- One-click permission widening.
- Web idioms: hover-only actions, dashed placeholders, custom segmented controls, filled toolbar
  pills.

## How we'll validate

Astra's usability protocol (details in its review):
- five-second state test
- approval comprehension
- queue/steer
- phone reading
- review feedback
- Inbox triage
- remote and concurrent actions
- notifications on a physical iPhone
- adaptive and accessibility checks

Each phase ships with the relevant checks plus the existing UI tests.
