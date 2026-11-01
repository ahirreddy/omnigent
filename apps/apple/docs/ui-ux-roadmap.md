# Native app UI/UX roadmap (from competitor research)

Synthesis of two independent reviews written on 2026-11-01, both based on the same screenshots of the
current app:
- [Claude](ux-research/2026-11-01-claude-ux-review.md): it did the web research, with 40 competitors
  cited.
- [Astra / gpt-6-astra](ux-research/2026-11-01-astra-ux-review.md): it wrote its review independently,
  then revised it against the verified competitor table only.

## Where both reviews agree

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
