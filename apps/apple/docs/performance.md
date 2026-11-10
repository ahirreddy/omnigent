# Mac app performance

How to load the app with a lot of data, measure it, and what the last pass found. Numbers are
for the Debug build (what `just apple-build` makes), on an Apple silicon Mac shared with other
builds, so wall-clock times are noisy; main-thread CPU time and sample shares are steadier.

## Seed a large data set

With the local services running (`just apple-services start`, the mock LLM and the `mock-model`
agent, see [verify-real-app.md](verify-real-app.md)):

```sh
just apple-seed-large
# From a worktree whose server runs from another checkout:
just apple-seed-large --runtime <checkout>/.native-lab-server
```

It stores, without model calls, 320 short sessions spread over 60 days in six projects (every
fifth unfiled) and three long transcripts ("Perf long transcript 1-3", 500, 650 and 800 turns)
with code blocks, tables, task lists, KaTeX, Mermaid, reasoning and tool calls. The long ones use
the `mock-model` agent on the online host, so sending a message streams a reply into them. Ids are
fixed: reruns add nothing and the earlier fixtures are left alone. `--sessions`, `--long` and
`--long-turns` change the sizes. Tests: `.venv/bin/python -m pytest apps/apple/Tools/test_seed_large_fixtures.py`.

## Measure scenarios in the app

`just apple-perf` (`Tools/perf/perf.py`) launches the build you name by path (never by bundle
id), injects a main-thread hitch monitor (`hitch-monitor.c`, a background thread that pings the
main queue every 4 ms and logs every wait of 12 ms or more) and needs no Accessibility permission.

```sh
app=apps/apple/build/DerivedData/Build/Products/Debug/Omnigent.app
just apple-perf suite --app "$app" --runs 3   # every scenario below; medians
just apple-perf suite --app "$app" --style cli  # the same with the CLI-style transcript
just apple-perf launch --app "$app" [<session-id>]
just apple-perf open --app "$app" <session-id> [--sample 6]
just apple-perf type --app "$app" [--sample 1]
just apple-perf stream --app "$app" <session-id> --seconds 12 [--sample 1]
just apple-perf drive --app "$app" scroll-transcript [--sample 2]
just apple-perf shot --app "$app" /tmp/window.png
```

- `launch` quits the app, writes a saved-tabs file with one New Tab (so every launch starts the
  same), starts it with `-ApplePersistenceIgnoreState YES` and reports time to the first window,
  time until the main thread is quiet for a second, and main-thread CPU.
- `open` deep-links a session; `suite` opens long transcript 1, then 2, then switches back to 1.
  A deep link costs about 0.2 s of main-thread CPU by itself (activating the app and window), so
  `switch` includes it.
- `type` makes the open session's composer first responder and types 20 characters, then
  deletes them, one key every 80 ms (`typist.m`, injected with the monitor: on `SIGUSR1` it posts
  key events to the app's own queue, which needs no Accessibility permission).
- `stream` posts a message to the session (the mock model streams its canned reply) and reports
  main-thread CPU, hitches (waits of 33 ms or more), hangs (100 ms or more) and blocked time.
- `--sample` also runs `sample` and prints the main thread's on-CPU share; the report is in
  `$TMPDIR/omnigent-perf`. Sampling suspends the app briefly, so take hitch counts from runs
  without it. Read the main thread's call tree in the report, or `sample <pid> 5` by hand, to
  see where the time goes; `Self._printChanges()` in a view body shows why it re-rendered.

- `--style cli` launches with `-omnigent:transcript-style cli` (a launch argument, so the saved
  setting is left alone); every scenario then runs against the CLI-style transcript.
- `drive` runs a scripted interaction with `driver.m` (injected with the monitor; on `SIGUSR2`
  it reads `$TMPDIR/omnigent-perf/drive.txt`): `scroll-transcript` and `scroll-sidebar` (90
  scroll-wheel steps of 60 pt down, one a frame, then back up), `toggle-sidebar`,
  `toggle-panel` (the right panel), `resize` (the window shrinks by 320 x 160 pt over 30 frames
  and grows back), `palette` (Command-K, then Escape), `search` (Find Session, type "perf",
  delete it), `settings` (Command-comma, then Command-W) and `new-session` (Command-N). The
  suite runs them after `stream`.
- Frames: `driver.m` also runs a display link on the main run loop and logs every frame
  interval of 1.5 periods or more, so every scenario reports frames per second, long frames,
  dropped frames, hitch time per second (time past each frame's deadline; Apple calls up to
  10 ms/s good and over 50 critical) and the worst frame. It counts the frames the main thread
  had time to start; the render server's own misses are not in it. The display may run at 60 or
  120 Hz between runs (ProMotion adapts), so compare hitch time and worst frame, not fps.
- Signposts (`PerformanceSignposts` in OmnigentPlatform) mark the transcript's layout, markdown
  parses and paced row updates; read them in Instruments, or as below (`/usr/bin/log`: zsh has
  a `log` builtin).

```sh
/usr/bin/log show --last 5m --signpost --style compact \
  --predicate 'subsystem == "ai.omnigent.performance"'
```

## Package benchmarks

Hot pure functions on seeded-like data, printed by tests that run only with `OMNIGENT_BENCH=1`:

```sh
cd apps/apple
OMNIGENT_BENCH=1 swift test --package-path Packages/OmnigentUI --filter TranscriptBenchmarks
OMNIGENT_BENCH=1 swift test --package-path Packages/OmnigentAppUI --filter SidebarBenchmarks
OMNIGENT_BENCH=1 swift test --package-path Packages/OmnigentUI --filter StreamingMarkdownTests/benchmark
```

## Results (November 2026)

| Scenario (Debug) | Before | After |
| --- | --- | --- |
| Transcript layout per streamed delta, 400 / 2,000 / 4,000 rows | 2.7 / 14.4 / 39.9 ms | 0.8 / 4.2 / 10.5 ms |
| A session-list server row, 650 sessions (unchanged / changed row) | 41 / 41 ms | 0.4 / 32 ms |
| Sidebar state on a shell redraw, 650 sessions | 57-75 ms | 0.03 ms (memo hit) |
| Hosting views re-measuring the conversation, share of main-thread samples while streaming into a long session | 17-20% | under 1% |
| Markdown parse, 1.8 KB answer, uncached | 3.8-8.7 ms | unchanged |
| Highlight a 100-line Swift block (cached afterwards) | 5 ms tokenize + 4 ms color | unchanged |

App scenarios (`just apple-perf suite --runs 3`, medians; the machine's load average was 500-900,
so differences under about 30% are noise):

| Scenario, two rounds of 3 runs | Before | After |
| --- | --- | --- |
| Launch: first window | 1.3 s / 0.7 s | 1.3 s / 1.0 s |
| Launch: main-thread CPU until quiet | 2.1 s / 1.6 s | 1.9 s / 1.7 s |
| Open a 500-turn transcript: main-thread CPU | 3.3 s / 2.7 s | 3.2 s / 2.7 s |
| Switch back to its tab: main-thread CPU | 1.4 s / 1.3 s | 1.5 s / 1.4 s |
| Stream a reply into it for 12 s: main-thread CPU | 4.8 s / 4.4 s | 4.5 s / 3.7 s |
| Stream: blocked time in waits of 33 ms or more | 4.7 s / 3.0 s | 3.9 s / 2.5 s |

The first "after" round predates the right-panel fix below. Opening and switching are dominated
by SwiftUI and AppKit building the tab's views, which this pass did not change.

What changed:

- The detail column (NavigationSplitView) and the conversation beside the right panel
  (`.inspector`) are each hosted in their own `NSHostingController`, which measured the whole
  conversation for its minimum size after every update. Both roots now answer from a fixed
  minimum (`unmeasuredMinimum`, Mac only), as the window root does with `WindowMinimumSize`.
- `SessionListStore` skips unchanged server rows, calls the core for attention only for changed
  sessions and assigns only changed values, so the sidebar, tab strip, menu bar and Dock no longer
  redraw for every row.
- The window shell keeps the sidebar's state in `SidebarStateMemo`, and the tab strip's tooltip
  reads only what the status line shows, so the shell no longer rebuilds the sidebar for turn
  timer, link or history-paging changes.
- `TranscriptLayoutMemo` reuses the folded turns before the last user message and folds only the
  open turn for each streamed delta.

## Second pass (November 2026)

Two rounds of `suite --runs 3` on an otherwise idle machine (load average about 5; the first
pass ran at 500-900), medians, Debug, main-thread CPU. The baseline is the first pass's build.

| Scenario | Before | After |
| --- | --- | --- |
| Launch | 0.61 / 0.62 s | 0.62 / 0.62 s |
| Open a 500-turn transcript | 0.92 / 0.93 s | 0.97 / 0.93 s |
| Open a 650-turn one as the second tab (the first stays built) | 1.22-1.24 s | 1.43-1.51 s |
| Switch back to the first tab (with the 0.2 s deep link) | 0.67 / 0.66 s | 0.55 / 0.57 s |
| Type 20 characters and delete them | 1.14 / 1.15 s | 0.52 / 0.58 s |
| Stream a reply for 12 s | 1.87 / 1.83 s | 1.70 / 1.65 s |
| Stream: CPU per half second while text arrives | 140-240 ms | 100-210 ms |
| Stream: transcript renders per second | 32 | 19-20 |
| Memory with three long chats open (`footprint`) | 178 MB | 223 MB |

Under heavy load (load average 200-700) the same switch went from 1.35 s to 1.07 s.

What changed:

- **Recent chats stay built** (`KeptAliveTabs`, now `SessionTabGroups.keptAlive`, across the
  three most recently shown sessions, and under a session-less page; their kept views are frozen
  at their last size so a window resize does not lay them out): the selected tab and the
  two most recently shown chats or side chats stay mounted, hidden and inert, so switching back
  shows them as they were, scroll position included. A hidden tab publishes no toolbar,
  commands or right panel, gives up the composer's focus, ignores the window's redraws and stops
  reading rows. Switching no longer builds any transcript row; what is left is the deep link,
  the toolbar swapping its items and the sidebar's selection. The cost: hidden tabs' views stay
  in the window, so opening another long session while two are kept costs up to 0.25 s more,
  and memory grows by about 20 MB per kept long chat.
- **Typing re-renders only the composer.** The draft reaches the composer as `ComposerDraft`
  (accessors) instead of a `Binding`, which reads the text when it is made, so the container
  and screen no longer track the text. The screen hears only when the draft gains or loses
  text. Per keystroke: about 28 ms before, 13 ms after.
- **The streaming transcript updates at most 20 times a second** (`TranscriptRowsPacer`). The
  first change after a quiet spell shows at once and a burst lands together 50 ms later.

## Third pass (November 2026)

The machine was shared with up to eight other builds (load average 15-160 for the first two
rounds, 350-800 for the last two), so each table interleaves the old and new builds round by
round; medians of 6 runs, Debug, main-thread CPU unless a row says otherwise. Hitch time is
time past each frame's deadline per second of the scenario (see the frames note above).

Chat style, quiet rounds (load 15-160):

| Scenario | Before | After |
| --- | --- | --- |
| Open a 500-turn transcript | 1.18 s | 1.08 s |
| Open a 650-turn one as the second tab | 1.67 s | 1.59 s |
| Switch back to the first tab: CPU / hitch time / worst frame | 0.63 s / 840 ms/s / 455 ms | 0.76 s / 208 ms/s / 196 ms |
| Type 20 characters and delete them: CPU / hitch time | 0.48 s / 38 ms/s | 0.48 s / 10 ms/s |
| Stream a reply for 12 s: CPU / hitch time / worst frame | 2.04 s / 120 ms/s / 111 ms | 1.69 s / 78 ms/s / 86 ms |

Chat style, loaded rounds (load 350-800):

| Scenario | Before | After |
| --- | --- | --- |
| Open a 500-turn transcript | 2.16 s | 2.32 s |
| Open a 650-turn one as the second tab | 2.73 s | 2.54 s |
| Switch back to the first tab | 1.33 s | 1.02 s |
| Stream a reply for 12 s: CPU / hitch time | 3.14 s / 133 ms/s | 2.34 s / 93 ms/s |

CLI style (`suite --style cli`, load 30-730):

| Scenario | Before | After |
| --- | --- | --- |
| Open a 500-turn transcript: CPU / hitch time | 1.75 s / 803 ms/s | 1.67 s / 709 ms/s |
| Open a 650-turn one as the second tab: CPU / hitch time | 2.15 s / 780 ms/s | 1.81 s / 570 ms/s |
| Switch back to the first tab: CPU / worst frame | 1.11 s / 780 ms | 0.93 s / 618 ms |
| Type 20 characters and delete them | 0.48 s, 60 ms/s | 0.48 s, 50 ms/s |
| Stream a reply for 12 s: CPU / hitch time / worst frame | 2.15 s / 70 ms/s / 138 ms | 1.62 s / 40 ms/s / 120 ms |
| Scroll the transcript 90 steps down and back: CPU / hitch time | 1.06 s / 167 ms/s | 1.00 s / 144 ms/s |

Package benchmarks (Debug, `OMNIGENT_BENCH=1`):

| Benchmark | Before | After |
| --- | --- | --- |
| CLI blocks per streamed delta, 400 / 2,000 / 4,000 rows | 2.4 / 10.6 / 21.4 ms | 0.5 / 2.5 / 4.2 ms |
| Reading the sessions that need you, 650 sessions (palette, Inbox, each shell redraw) | 5.1 ms | 0.0003 ms |

The other views, chat style, quiet rounds, before the changes (the changes left them within
noise, except toggling the right panel, 0.76 s against 0.96 s in the quiet rounds and level in
the loaded and CLI ones): scrolling the transcript 90 steps down and back 0.9 s CPU, 92 ms/s hitch time, worst
frame 88 ms; the 650-session sidebar 0.43 s, 38 ms/s, 52 ms; toggling the sidebar 0.9 s, 480
ms/s, 122 ms; toggling the right panel 0.8 s, 270 ms/s, 140 ms; opening Settings 0.5 s, 210
ms/s, 290 ms; resizing the window over 60 frames 3.3 s and 520 ms/s with single frames of up to
1.8 s (2-10 s depending on load); the palette, sidebar search and the New Session page cost
under 0.15 s and no hitches.

What changed:

- **The conversation toolbar stays put across tab switches.** The shown conversation hands its
  items (`ConversationToolbarItems`) to the tab host (`KeptAliveTabs.hostsConversationToolbar`),
  which places them in one spot, so a switch updates the items instead of removing one
  conversation's and adding another's. A split pane or a lone screen places its own.
- **The shell no longer redraws for the selected chat's status line.** The tab strip's tooltip
  reads it in the tab's own body (`TabStatusDetails`), so the sidebar and tab strip are not
  rebuilt while a session's header, decisions and sections load.
- **The transcript's row list reads its rows itself** (`TranscriptRowsContent`): a paced row
  update re-renders the list, not `TranscriptView`'s scroll modifiers, overlays and navigator.
- **The CLI style keeps the settled turns' blocks** with the layout memo's folded prefix, so a
  streamed delta lays out and formats only the open turn.
- **`SessionListStore.needsResponse` is kept, not computed per read**: only sessions whose
  attention is Needs you go through the core, once per list change.
- `PerformanceSignposts` (OmnigentPlatform) marks the transcript's layout, markdown parses and
  paced row updates.

Tried and dropped:

- Hidden kept tabs at the size they last showed (a custom layout instead of the `ZStack`, so a
  resize or a new tab would not lay them out again). It did not help: resizing with only one
  long tab open costs about the same as with three kept (9.1 s against 10.7 s in the same
  conditions), so the hidden tabs are not what makes a resize slow, and the suite was slower
  with it. Memory with three long chats open is 162-197 MB before and 171-184 MB after
  (`footprint`, two launches each), so the kept tabs cost less than the 45 MB measured in the
  second pass.
- Passing the composer's `mode` and `fork` as accessors like `ComposerDraft`: typing no longer
  re-renders the screen (it never reads them per keystroke), and every other pass re-renders the
  screen anyway for its closures, so there was nothing to cut.

## Fourth pass: resize and markdown (November 2026)

Two rounds of 3 interleaved runs each (old and new build alternating), Debug, load 300-990, so
the absolute numbers are 2-5 times the quiet ones; medians, main-thread CPU unless a row says
otherwise. Cells give round 1 / round 2. The driver's resize schedules its 60 steps a frame
apart; a slow step lets the overdue ones run back to back, so the resize's "worst frame" is
several steps and its CPU is the number to compare.

| Scenario, chat style | Before | After |
| --- | --- | --- |
| Resize the window over 60 steps | 8.9 s / 16.2 s | 4.8 s / 10.7 s |
| Open a 500-turn transcript: CPU | 2.38 s / 2.54 s | 1.91 s / 2.16 s |
| Open it: settled | 3.8 s / 3.0 s | 2.1 s / 2.6 s |
| Open it: worst frame | 1.10 s / 1.05 s | 0.76 s / 1.01 s |
| Toggle the sidebar: CPU | 1.59 s / 2.42 s | 1.08 s / 2.26 s |
| Toggle the sidebar: hitch time / worst frame | 865 ms/s, 470 ms / 738 ms/s, 605 ms | 740 ms/s, 234 ms / 885 ms/s, 451 ms |
| Toggle the right panel: CPU | 1.21 s / 1.46 s | 1.17 s / 1.57 s |
| Toggle the right panel: hitch time | 538 / 706 ms/s | 613 / 705 ms/s |
| Scroll the transcript 90 steps down and back (round 2) | 1.27 s, 184 ms/s | 1.38 s, 197 ms/s |

CLI style (`--style cli`), same conditions, round 1 / round 2:

| Scenario, CLI style | Before | After |
| --- | --- | --- |
| Resize the window over 60 steps | 7.5 s / 8.4 s | 5.1 s / 4.7 s |
| Open a 500-turn transcript: CPU | 2.15 s / 2.33 s | 2.83 s / 1.84 s |
| Open it: settled / worst frame (round 2) | 3.5 s, 958 ms | 2.7 s, 814 ms |
| Toggle the right panel: CPU (round 1) | 0.97 s | 0.65 s |

The CLI round 1 ran while the machine's load swung (its new build's launch was also 0.3-2.9 s
slower than the old one's in the same runs); round 2 repeats the open with steadier load.

What changed:

- **A resize step no longer re-renders the window.** `AppShell` kept the detail column's width
  in its state for the titlebar's tab strip, so every step re-ran the shell, the sidebar's 650
  rows, the conversation screen and composer. The width now lives in an observable box
  (`TitlebarStripSpace`) that only the strip reads. `TabSplitView` and the transcript's message
  navigator likewise keep whether the width fits, not the width. In samples of a resize, view
  bodies fell from 14% to 5% of each step and the sidebar's outline updates are gone.
- **Markdown parses and code tokenizes off the main actor.** `MarkdownCache` and
  `CodeSpanCache` are thread-safe (a `Mutex` around the bounded cache; a miss parses outside
  the lock). `MarkdownWarmup` hands settled answers to a background task newest first, and a
  conversation's first page of rows waits up to 0.4 s for the newest 12 (the transcript keeps
  saying it is loading meanwhile), so the first frame finds them parsed. A row the warm-up has
  not reached still parses in its body, so nothing shows unformatted and then reflows.
- **Coloring code spans is linear** (`CodeHighlighting.attributed`): it appends the plain and
  colored pieces in order instead of mapping each span's offsets from the start of the text.

Tried and left out:

- The open's worst frame (0.75-1 s) is still laying out the first screen of rows; parsing was
  the smaller part of it.
- Toggling the right panel animates the detail column, and each animation frame is a resize
  step; it moved within noise. The sidebar toggle gained from the shell no longer re-rendering.
- One selectable text view per message instead of one overlay per `Text` (3-5% of samples)
  needs a TextKit view in place of SwiftUI `Text`, a larger change than this pass.

## Fifth pass: switching tabs (November 2026)

Measured in a view test, not the app: the connected window in an offscreen titled window (a
300-row chat, a side chat, a terminal, a browser and a New Tab page in one session, 153
sessions in the sidebar), thread CPU from selecting a tab through the layout pass that shows
it. Debug with coverage instrumentation, so several times a Release build's cost, and within
about 50% between runs; the render and view counts are exact.

| Switch | Before | After |
| --- | --- | --- |
| Chat to side chat, either way | 250-285 ms | 65-69 ms |
| Chat to terminal | 210-280 ms | 64-72 ms |
| Terminal to chat | 300 ms | 86-92 ms |
| Chat to New Tab | 190-250 ms | 56 ms |
| New Tab to chat | 280 ms | 84-94 ms |
| Chat to browser | 155-180 ms | 55-67 ms |
| Browser to terminal | 113-128 ms | 51-66 ms |
| AppKit views made and dropped per switch between kept chats | 30 | 5 (focus rings) |
| Renders of each kept conversation (screen, transcript, rows) per switch | 3 | 1, the one that shows |

What changed:

- **A hidden tab is one layer** (`HiddenTabContent`'s `compositingGroup`). Hiding a tab turns
  off its hit testing, and SwiftUI answered by taking every AppKit view in both tabs (text
  overlays, scroll views, the composer's glass) out of the window and putting it back: 30 views
  made and dropped and about 47 kinds of superview moves per switch. This was the largest cost.
- **The conversation that hides does not render.** `HeldWhileHidden` compared the tab as it was
  with the tab as it is now, so the switch itself (shown before, hidden now) passed the window's
  new closures to the tab that was leaving; it now holds whenever the tab is hidden now. The
  screen and the row list also read whether their tab is hidden in their own bodies, so both
  conversations re-rendered for the flag. Small views read it instead
  (`ConversationTabVisibility`, `PacedWhileShown`, `WorkspaceInspectorPresentation`).
- **A tab with other toolbar items no longer renders the window twice.** A terminal, browser or
  New Tab page reports no trailing toolbar items and a conversation reports its count, which
  `AppShell` kept in its state, so each switch between the two kinds rendered the shell, the
  sidebar and the shown tab a second time. The count sits with the detail width in
  `TitlebarStripSpace`, which only the strip reads.
- **The conversation that shows renders once, not twice.** `ConnectedServerView` read the
  selected tab and the kept list inside the closure it gives `TabSplitView`, so the split view
  followed the selection too and built the kept tabs again after the window had. It reads them
  before making the split view.

Each has a counting test (`KeptAliveTabsSwitchTests`, `AdaptiveShellTests`,
`ConnectedWindowTabsTests`); `RenderTally` (Debug) gives a test the renders one change caused,
by `countsRenders` name.

Left as it is:

- One render of the shell, the sidebar, the tab strip and the conversation that shows, most
  of what is left: `ConnectedServerView` and `AppShell` read the selected tab in their
  bodies, so a switch re-runs both and hands the sidebar and the shown tab new closures.
  (The seventh pass took the shell and the sidebar out of a switch.)
- The flip itself, about 55 ms spread over SwiftUI's graph update, the toolbar and the display
  list, with no single symbol standing out.
- Terminals, browsers and the New Tab page are not kept: each selection builds the page again,
  a terminal tab asks the server for its terminals and the New Tab page for the session's
  agent. That is a request after the switch, not time in its frame.
- A chat left in Terminal mode lets go of its terminal surface while its tab is hidden, so
  coming back builds the surface again: 100-165 ms, the slowest switch. Its transcript stays
  built. Going from Terminal back to Chat builds the composer again (about 250 ms over the
  following frames), since the composer is removed under the terminal.
- The kept tabs' order (`zIndex`) changes on a switch, about 10 ms, so the shown tab's
  overlays are never under a hidden one's.

Ruled out: tab persistence (debounced, off the switch), tab thumbnails, the opacity change and
hiding from accessibility.

## Sixth pass: what one session's change renders (November 2026)

Measured in a scratch test package against a Release build of the packages
(`swift test -c release -Xswiftc -enable-testing`), not the app: the connected window in an
offscreen window with 250 sessions in the sidebar, a 600-row chat, a terminal, a browser and
a side chat in one session. Each number is the main thread's CPU time
(`CLOCK_THREAD_CPUTIME_ID`) for one step through the layout pass that follows it, the median
of 30-60 steps; before and after ran back to back, twice. It counts view bodies and layout,
little of the drawing, and other builds were running, so differences under about 20% are
noise.

| One step | Before | After |
| --- | --- | --- |
| Another session's row changes (status, preview or time) | 57-72 ms | 19-26 ms |
| A row that is filtered out of the sidebar changes | 57 ms | 19-24 ms |
| The session of a hidden, kept tab changes | 60-64 ms | 32-41 ms |
| The shown session's own row changes | 57-58 ms | 44-50 ms |
| Six terminals that never had the keyboard, 4 s idle | 61.8 ms | 6.3 ms |

The row changes compare the tree before and after the first two changes below; the terminals
were measured on their own (whole-process CPU).

No measurable change, either way: a key in the composer (7-15 ms, see below), a streamed
delta (10-12 ms), a scroll step (5-7 ms, a tenth of them 20-30 ms), switching sessions
(127-136 ms), opening another session (220-350 ms), a window resize step (58-84 ms), a
sidebar resize step (70-118 ms), the first frame (650-860 ms) and idle with the four tabs open
(about 10 ms of main thread a second, most of it the test's own polling).

What changed:

- **The window's root no longer follows the session list or the tabs' titles.**
  `ConnectedServerView.body` built the sidebar's state and the tab strip's state and passed
  both to `AppShell` as values, so every row the server sent and every tab title rendered the
  root, the shell, the toolbar and each open tab. `AppShell` now takes them as closures and
  calls each inside an `ObservationScope`, a small view whose body is the only reader. The
  root's tab commands, busy-tab report and tab overview read the tabs in view modifiers of
  their own (`WindowTabsModifiers.swift`), and each kept tab is built in its own scope.
- **Next and Previous Session ask one question.** The open chats read the whole visible list to
  know whether there were two sessions; `SessionListStore.hasSeveralVisible` changes only when
  that answer does.
- **A view that reads one session hears about that session.** `SessionListStore.session(_:)`
  registered its reader on the whole list, so each open chat rendered for every row.
- **A terminal that has not had the keyboard does not draw every display refresh.** Ghostty
  starts a surface focused, with a blinking cursor and a render loop; the app now tells it the
  surface is unfocused until it gets the keyboard. Its cursor is hollow until then.

Each has a counting test: `WindowRenderBudgetTests` and `AdaptiveShellTests` (which
scope renders for a row, a kept tab's session, the shown session and a title),
`SessionListNotificationTests` (which readers a change tells) and
`IdleSurfaceRenderingTests`.

State that changes on an interaction has to be read by one scope on any chain of ancestors. A
scope around the detail column as well rendered the shown chat twice on a tab switch, because
the root reads the selected tab too; the detail is built in the shell's body as before. (The
seventh pass moved the root's read out and gave the detail its scope.)

Left as it is:

- The remaining 19-26 ms for another session's row is the sidebar: the store's two passes
  through the core, the sidebar state built again and the list of 250 rows compared.
- The shown session's own row still renders its whole conversation screen and its side chat,
  and a hidden tab's session renders that tab: `ConversationContainer` takes the session's
  summary as one value, so a new preview or time is a new input to the screen.
- A tab switch still renders the shell and the sidebar once (the fifth pass's first item).
- A key in the composer costs either about 7 ms or about 15 ms for a whole run of the same
  binary; the cause was not found.

The seventh pass did the last three.

## Seventh pass: one change renders the views that show it (November 2026)

The aim of this pass was that each change renders only the views that draw it, with a test
for each way that goes wrong: a view that stops updating because its read was narrowed too
far, and a broad read put back at a root later.

Measured as the sixth pass (Release, offscreen, 250 sessions, a 600-row chat with a terminal,
a browser and a side chat; median main-thread CPU per step through its layout pass). Before
is the tree this pass started from with the transcript width-change fix merged; before and
after ran back to back, twice. Differences under about 20% are noise.

| One step | Before | After |
| --- | --- | --- |
| The shown session's own row changes | 45-46 ms | 23 ms |
| The session of a hidden, kept tab changes | 33 ms | 23 ms |
| Another session's row changes (status; preview) | 26; 22-23 ms | 26; 23 ms |
| A tab switch to a chat | 100 ms | 81-82 ms |
| A tab switch to a terminal | 259-265 ms | 220-223 ms |
| A switch between two open sessions | 126-127 ms | 115 ms |
| Opening another session, first pass (to settled) | 214-218 (445-449) ms | 153-165 (392-398) ms |
| A page without a session, or back (with the frames after) | 696-710 (966-985) ms | 159-176 (341-360) ms |
| A character of sidebar search (the slowest tenth) | 45-46 (97-101) ms | 27-28 (79-80) ms |
| A write to the defaults that no view shows | 35 ms | 1.4 ms |
| A key in the composer | 15-16 ms | 16 ms |
| A streamed delta | 11-12 ms | 11 ms |
| A scroll step (the slowest tenth) | 6-7 (19-24) ms | 6 (21) ms |
| A window resize step (the slowest tenth) | 55-56 (114-116) ms | 53-54 (111-116) ms |
| A sidebar divider step | 30-32 ms | 29 ms |
| A tab's title | 0.3 ms | 0.25 ms |
| The first frame | 612-633 ms | 598-599 ms |
| A 600-row transcript arrives, first pass (to settled) | 49-50 (243) ms | 48-55 (244-270) ms |

One of the two runs after had the main thread at its faster level throughout (a key 5.7 ms, a
delta 7.8, a scroll step 3.9, a session switch 90); those four rows give the other run. Three
more runs of the session switch alone gave 122-127 ms before and 110-113 after. Another
session's row and the rows from "A key in the composer" down did not change. The sixth
pass's 70-118 ms for a sidebar divider step was the test laying the split out twice; a step
is about 30 ms.

What changed, with the renders counted in the mounted window:

- **A message in an open tab's session renders the sidebar and nothing else.** The strip,
  the tab's chat and its menus read the session's whole summary, so each new preview or time
  rendered the strip, the tab, the screen, the transcript and the composer, also for a tab
  kept behind. `SessionListStore.sessionWithoutActivity(_:)` is observed under its own key
  and told only when something other than the preview and the time changed; the sidebar row
  still reads the whole summary.
- **A tab switch renders the detail, the tab that shows and the strip.** The root read the
  shown tab to build the detail and to tell the core which chat is on screen. The detail
  reads it in an `ObservationScope` of its own and the report is a modifier
  (`ViewedSessionReport`). No window, shell, sidebar or session rows.
- **A session switch renders the window once**, where a switch from the palette, a deep
  link, a notification or Next and Previous Session rendered it twice. The root reads the
  host's selection and nothing of the tab model; the page the tab model moves to by itself
  is handed to the host by a modifier (`ShownPageReport`).
- **A page without a session renders the window once, and so does the way back.** Whether
  there is a strip follows the host's selection, which the root reads already, where it
  followed the tab model's page and rendered the window a second time. On the way back the
  strip renders twice in the one layout pass, empty and then with the session's tabs. Not
  timed again: the table's 159-176 ms is with the second render.
- **A session opening or closing behind the window renders nothing.** The open chats,
  terminals, workspaces and panels are read per session
  (`ConnectionStore.openConversation(_:)`, `ServerSession.terminals(of:)`, `workspace(of:)`,
  `panel(of:)`), each observed under a key for that session.
- **Search text renders the sidebar, its rows and the search field.** Making the search
  binding in the root read its text, so each character rendered the window. The shell takes
  the binding as a closure the sidebar calls. A binding made in a body never compares equal
  to the last one, so the field's modifier then ran with every sidebar render (5 ms a row
  change, for the commits in between); `SidebarSearchField` keeps the latest binding in a
  relay and its inner modifier takes the text, so it runs when the text changes.
- **A draft's first character renders the composer and the sidebar's draft pencil.** The
  screen kept "the draft has text" in its state to decide who answers Command-Return; the
  flag is now in a small observable (`DraftPresence`) read by the three places that use it.
- **A write to the defaults no longer renders every open chat.** `@AppStorage` renders its
  view on every write to the store when its key has a dot in it, and the chat read
  `composer.submitWithCommandReturn`: showing the right panel, a sidebar option or a
  remembered window frame rendered each open conversation from its container down.
  `ComposerPreferencesReader` holds the two composer settings and writes the screen's copy
  only when one changes.
- **A chat kept behind a page is not built again.** `TitlelessToolbar` chose between two
  branches over the whole detail column by whether the tab strip shows. A branch gives what
  is under it a new identity, so going to Usage, Inbox or Automations and back tore down
  and rebuilt every kept chat, both ways. It passes the choice as a value to one
  `toolbar(removing:)`. A chat's view state now survives the visit.

Two stale views were found on the way and fixed, each with a test that failed first:

- The sidebar's Load more row did not follow the page that was loading: the sidebar state is
  reused while its sessions are unchanged, and the reused state carried the paging it was
  built with. It takes the paging afresh.
- A turn rail tick kept calling the jump it was built with. `TurnTick` compares its turn,
  hover and active state, not its action, and the transcript's jump captures Reduce Motion
  and the message focus. The ticks call through the rail's latest jump
  (`TurnRailClickTests`).

### The render budgets

`WindowRenderBudgetTests` (OmnigentAppUI) mounts the connected window with four sessions,
one shown and one in a kept tab behind it, and runs one interaction per row of
`WindowInteraction.all`
(`WindowRenderBudgetTable.swift`, `WindowRenderBudgetLayout.swift`). A row names the most
each scope may render and then reads what it changed from what the window draws:

```swift
WindowInteraction(
  name: "a hidden tab's session's title",
  budget: ["session row": 5, "sidebar": 1, "tab": 1, "screen": 1, …],
  perform: { try $0.change(BudgetWindow.hidden) { $0.title = "Beta renamed" } },
  verify: { window in /* the new title in the sidebar's row, and in the tab once it shows */ })
```

A scope that a row does not list may not render at all, so a broad read put back at a root
fails the rows it now renders in, by name, and a new scope starts at none everywhere. Adding
a scope is one `.countsRenders("name")` (or an `ObservationScope("name")`) and one entry in
the rows that may render it. The scopes today: window, shell, sidebar, session row, search
field, strip, tab controls, tab switcher, detail, tab, screen, transcript, rows, row,
markdown, composer, sidechat.

A count depends on nothing outside its window. The window keeps its preferences in a store
of its own (`scratchDefaults()`): every `swift test` process shares one defaults domain, and
another run's write there renders each scope that reads `@AppStorage`. Before the count and
before `verify`, the test waits until the window has rendered nothing and asked its server
nothing for 300 ms and 20 run loop passes (`settleUntilQuiet`), and fails after 10 s naming
what still rendered. A row over its budget prints the scopes over, the whole tally and the
budget.

| Interaction | May render |
| --- | --- |
| Another session's row (title and time) | sidebar 1, session row 5 |
| The shown session's preview and time | sidebar 1, session row 4 |
| A hidden tab's session's preview and time | sidebar 1, session row 4 |
| The shown session's title | sidebar 1, session row 5, strip 1, tab controls 1, tab 2, screen 2, transcript 2, rows 2, composer 2 |
| A hidden tab's session's title | sidebar 1, session row 5, tab 1, screen 1, transcript 1, rows 1, composer 1 |
| A session that needs the user; a session marked unread | sidebar 1, session row 5 and 4 |
| A streamed delta | nothing counted (the streaming row's text only) |
| A composer keystroke | composer 1 |
| A draft's first keystroke; its last character deleted | composer 1, sidebar 1, session row 4 |
| A tab switch | detail 1, tab 1, screen 1, transcript 1, rows 1, composer 2, strip 1, tab controls 1 |
| A session switch | window 1, shell 1, sidebar 1, session row 4, detail 2, tab 2, screen 3, transcript 3, rows 3, composer 4, strip 2, tab controls 2 |
| A session chosen in the sidebar; one the window shows by itself; back to a kept one | as a session switch, with screen, transcript and rows 2 |
| Back to a session that closed | as a session switch, with tab 3 |
| Another session opening or closing behind the window | nothing |
| A page without a session; one chosen in the sidebar; one the tab model shows by itself | window 1, shell 1, sidebar 1, session row 4, detail 2, tab 2, screen 2, transcript 2, rows 2, composer 2, 1 and 1; no strip, no row, no markdown, and the chats' scroll views are the same objects |
| Back from a page without a session | window 1, shell 1, sidebar 1, session row 4, detail 2, tab 2, screen 3, transcript 3, rows 3, composer 1, strip 2, tab controls 1; no row, no markdown, and the chats' scroll views are the same objects |
| A session chosen in the sidebar over a page; one the tab model shows by itself over a page | as back from a page, with composer 2, strip 1 and tab 3: 2, or 3 when SwiftUI runs the leaving page's body once more (see "Left as it is") |
| Sidebar search text set; typed into the field; cleared | sidebar 1-2, session row 2-6, search field 1-2 |
| A sidebar filter; a page of sessions loaded; an empty last page | sidebar 1, session row 2-4 |
| A window resize step; a sidebar divider step | strip 1 |
| The right panel shown | screen 1, transcript 1, rows 1, composer 1 |
| A preference no view reads, over a chat and over the new session page | nothing |
| The Command-Return setting | screen 2, transcript 2, rows 2, composer 2 |

A terminal's output is covered by `IdleSurfaceRenderingTests` rather than this table.

### What reads what

Reads of observable state at or above a screen's root. "Scope" is the view whose body the
read invalidates.

| Scope | Reads | Invalidated by | Verdict |
| --- | --- | --- | --- |
| Window root (`ConnectedServerView.body`) | the host's selection | a session or page switch | fine: the switch renders the window once (budget), and a selection without a session takes the strip away in that render |
| | `connection.connectedServer?.baseUrl` | connecting to another server | fine |
| | `sidebar.fork`, `projectSettings`, `archiveRequest`, `renamingFromTab`, `renameText`, `sessionList.editError` (read when their sheet and alert bindings are made) | opening one of those sheets or alerts | fine: each presents over the window |
| | `tabFailure`, `showsTabOverview` (view state), size class, two `@AppStorage` keys without a dot | a failed tab action, the overview, a compact width, those two settings | fine |
| Root modifiers, each its own scope | `TabCommandsPublishing`: the tabs' commands. `BusyTabsReport`: busy tab ids. `WindowTabOverview`: the strip's state. `ViewedSessionReport`: the viewed session, window focus. `ShownPageReport`: the tab model's page. `TabRestoration`: server URL, live session ids. `CloseShellConfirmation`: the shown tabs, the closing shell. `NewTabOptionsLoading`: the shown session id. `PaletteAdapter`: built only while the palette shows | tab, session and title changes | fine: none renders content, each runs a closure |
| | `SessionTabsLifecycle`: every session's archived flag, the open session ids | every session row | fine for now: a dictionary of 250 flags per row, no view under it; an incremental core API would remove it |
| Shell (`AppShell.body`) | column visibility, size class, whether there are tabs | the sidebar toggle, a compact width, a page without tabs | fine |
| "sidebar" | the sidebar state: the session list, display options, offered pages, the search binding | every session row, search text, filters, paging | fine: it is what draws them. Every row on screen runs its body for each change (the budgets' "session row 4" is all four rows of the test's sidebar), under 2 ms of the 20: see "Left as it is" |
| "search field" | the search text, through the relay | search text | fine (budget) |
| "tab controls", "tab switcher", "strip" | the shown session's tabs and titles; the strip also the detail's width | a tab's title, a tab switch, a resize step | fine: a resize step renders the strip once and nothing else |
| "detail" | the shown tab group, its selected tab, its split, the kept list, the page, the connection's issues | a tab or session switch, a split, a connection issue | fine |
| "tab" (one per kept tab) | its session's open conversation, `sessionWithoutActivity(id)`, its terminals, workspace and panel, `changedFilesRevision`, the connected server, declared terminal names, offered pages | its own session's title, status or stores; a file change in any session (`changedFilesRevision`) | fine; `changedFilesRevision` is one counter for the connection, so a file change renders every kept tab's container (rare, not narrowed) |
| `ConversationContainer` | its `ConversationStore`, panel route, composer preferences copy, fork and share flows | its conversation's state other than the transcript, the right panel, the two composer settings | fine (budget: right panel, Command-Return) |
| `ConversationScreen` ("screen") | the conversation's header and mode, not the draft and not "has a draft" | title, status, mode | fine: a keystroke renders the composer only |
| "transcript", "rows" | the transcript state; streamed text is read by the streaming row | a new row, a page of history | fine: a delta renders no counted scope |

Views compared with `==`. SwiftUI uses a view's `Equatable` conformance for a view that
holds anything but plain data even without `.equatable()`, so each of these skips its body
when `==` says so, and a field `==` leaves out is a stale view waiting.

| View | `==` compares | Body also uses | Verdict |
| --- | --- | --- | --- |
| `TurnSegmentView`, `CLIBlockView` (`.equatable()`) | every stored value (synthesized) | environment | fine |
| `MessageRowView`, `CLIUserBand`, `CLIAssistantBlock` | row, decoration | environment (actions, palette, width), focus state | fine: no stored input is left out |
| `ActivityRowView`, `CLIActivityLine` | row | environment, expansion state | fine |
| `ToolGroupView`, `CLIToolLines` | entries | expansion state | fine |
| `CLIWorkGroup` | id, items, live, decorations | collapse state | fine |
| `TurnTick` | turn, hover, active | its action closure | fixed: the action reaches the latest jump through the rail (`TurnRailClickTests`) |
| `HeldWhileHidden` (`KeptAliveTabs`) | only whether the tab is hidden now | the tab's whole content, closures included | fine by design: a hidden tab ignores new inputs and takes the latest when it shows, because the tab that shows is never equal. A shown tab cannot be skipped: its content holds closures that cannot be compared |
| `SidebarSearchFieldContent` (no `==` of its own) | the text and the relay's identity, by SwiftUI | the binding, through the relay | fine (budget: three search rows) |
| `TabStatusDetails`, `PickerVisibilitySource`, `WorkspaceMarkdownRenderer`, the presenter-identity environment values, `TranscriptWindowControls` | an owner or presenter identity, or an id | closures of that same owner | fine: one owner per window or server, and the closures do not capture view state |

`@AppStorage` renders its view for every write to the defaults when its key contains a dot
(any key, any writer); a key without one renders it for that key only. Keys with a dot that
views still read: `composer.submitWithCommandReturn` (`InboxRow`, `KeyboardShortcutsSheet`,
the settings pane), `omnigent.inbox.filter` (`InboxView`), `workspace.fileViewMode` and
`workspace.showsComments` (`FileViewerView`), `omnigent.serverURL` (`ConnectView`,
`SettingsView`). The inbox and the file viewer are the two worth moving behind a reader like
`ComposerPreferencesReader`, each inbox row and each open file renders for any write; the
chat no longer does. All other keys use a colon.

### Rules this pass relied on

- State that changes on an interaction is read by one scope on any chain of ancestors.
- A read made in a closure counts for the body that calls the closure, and
  `Binding(get:set:)` calls `get` when it is made: a binding built in a root reads its value
  there.
- A binding made in a body never equals the last one, so whatever takes it runs with every
  render of its parent. Keep the latest in a reference (`SearchTextRelay`,
  `FocusedActionsRelay`) and pass the value.
- A view holding closures runs whenever its parent does. Only values, or a reference that
  stays the same, let SwiftUI skip it.
- An `if` over `content` in a modifier, or any branch above a subtree, rebuilds the subtree
  when the condition changes. Pass the condition down as a value.
- A view's `==` must compare everything its body uses, or route what it leaves out through
  a reference that is always current.
- `Self._printChanges()` reports a functional binding as changed on every pass and does not
  name every trigger; "@identity changed" with every state name means the view was built
  again, not updated.

### Left as it is

- **Another session's row, about 20 ms with 250 sessions.** Where it goes (one sample): the
  store's two passes through the core 3 ms, the sidebar state 1.7 ms, the hosting view's
  layout 10 ms (the outline's row diff 1.4-1.8 ms of it, the visible rows' bodies under
  2 ms), the commit 1.6 ms. Skipping unchanged rows with `==` would save 15-20% at most and
  is unsafe while rows take fresh closures and the current time; it needs the sidebar's
  actions behind a stable reference first. The filter needs an incremental core API.
- **A page without tabs renders each kept chat's container once**, and the window once. No
  rows are built.
- **A session chosen in the sidebar over a page without tabs sometimes renders the page that
  leaves once more** (7 of 25 choices in the mounted window, about 14 ms in a Debug build).
  The choice sets the host's selection and the tab model's page together, so the page's tab
  leaves in the pass that renders the window, and in some of those passes SwiftUI runs the
  leaving tab's body again with its old content. A session the tab model shows by itself
  over a page does the same (4 of 25). Both have a budget with tab 3 as its ceiling, so a
  second window render there still fails. A switch that reaches the window as the host's
  selection alone never did (75 of 75); its budget is tab 2.
- **A session switch** still builds the new session's tabs and renders the window once; the
  first pass of opening another session is 150-170 ms, most of it the new chat's first
  layout.
- **A tab switch to a terminal** (190-240 ms) builds the terminal again; no app symbol
  stands out in a sample (view layout 22%, SwiftUI's render 18%, hosting layout 18%, the
  attribute graph 15%, the commit 9%, the toolbar 4%).
- **A resize step** renders only the strip. A window step is 72% layout: the toolbar's
  bridge about 24% of the step and the transcript's lazy stack about 20%, app code under 3%.
- **A key in the composer** renders the composer once. Its cost levels (about 6, 10 and
  15 ms, each for a whole run of the same binary) go with the state of the processor core
  the main thread is given: a fixed loop of arithmetic timed beside the keys changes level
  with them. Nothing the app renders differs between the levels.
- **One window resize step in 40 costs 440-580 ms** in Release once the chats behind have
  been scrolled and switched, before this pass and after it. The full run before hides it:
  its page visit builds every chat again first. The cause is known and it is not fixed; see
  "The slow resize step" below.
- **A widening window step costs twice a narrowing one** at the same widths (57 against
  28 ms in Release, where no row changes width). In one sampled step, 25 of 45 samples are
  `NSToolbarView layout` adding an item's view again and the SwiftUI toolbar item updating
  for it; a narrowing step spends an eighth of its time there. Not looked into further.
- `LoopProbe.record` costs 170-360 ns a call in Release and its detail is an autoclosure;
  the busiest probe changes 55-85 times over 40 resize steps, under 0.02% of the main
  thread.

### The slow resize step

A reader at the end of a long chat whose last row is very tall (a streamed answer of
2056 pt here) resizes the window through the widths where the rows change width (a pane
under 768 pt). One step of the first pass over those widths takes 440-580 ms; the same step
of the next pass 155-210 ms; the steps around it 60-145 ms. It is the second step of the
rows narrowing in one build (443-543 ms in five runs) and the last step of their widening
in another (579 and 580 ms in two runs).

It is one layout of the shown transcript's lazy stack: `NSWindow _setFrameCommon`,
`NSHostingView.layout`, one `LazySubviewPlacements` update, `LazyStack.place` (330 of 416
samples), which builds and measures 152 rows in that pass. The kept chats behind are not
it: with one chat fewer the step is 540 ms.

A new row width sends the transcript to its top, where the rows take the width, and a
reader who was at the end is then returned to the bottom marker by id
(`TranscriptScrollState.endPassage`). The lazy stack estimates its length as the average
height of the rows it has measured times the row count. After a landing at the end it has
measured the first few rows and the last few, so with a very tall last row the estimate is
two to three times the real length (155732 pt for about 62000). In most steps the estimate
has fallen back to the top rows' average by the time of the return, and the stack lands on
the last rows directly (9 rows built or fewer). In the slow step it has not: the stack
picks its first row by the inflated average, places it by the top rows' average and builds
every row from there to the viewport. It goes with the composer's dock changing height with
the width, on that step or the one after. A chat without a very tall last row has no such
step.

To see it without the app: 150 turns and a very tall last row in a transcript with a bottom
bar whose height changes with the width, the reader at the end, the pane going from 900 pt
down 12 pt a step and back. One step of the first pass builds 211 rows (305 ms in Debug
against 22-88 ms for the others).

What was tried, in a copy of the package, and why none of it is in:

- Returning with `ScrollPosition.scrollTo(edge: .bottom)` in place of the marker's id lands
  without the walk (5-6 rows built; the slowest step 167-191 ms in Release). SwiftUI then
  does not run the scroll geometry actions for where the scroll view comes to rest, so the
  transcript takes itself to be away from the end: every later step repeats its return
  scroll eight times (the steps that change row width go from 68-100 to 105-167 ms, two
  passes from 5142 to 5551-5656 ms) and following stays off after a resize.
- Keeping the scroll view pinned to its bottom edge rests the transcript 24 pt lower.
- Scrolling to the last row, scrolling twice and scrolling one pass later build the same
  rows.

What is left: finding the end without the geometry action, so the return can go by edge;
holding the row width through a live resize and taking it once at its end, which the user
would see; a stack laid out from its bottom.

### Not checked in a real window

These tests mount the window offscreen. What only a key window on a display shows was not
checked: the titlebar's title and strip as a session gives way to a page and back, and a
kept chat's scroll position after that visit; typing in the real search field (marked text,
the clear button, Command-F); Command-Return sending or approving as a draft gains and
loses its text; the composer following Settings live; a real divider drag and window
resize; a turn rail jump after Reduce Motion changes.

## Where the time still goes

- **Switching tabs** renders the detail and the tab that shows once, 80 ms in Release to a
  600-row chat; a terminal, browser or New Tab page is built again on each selection, 220 ms
  for a terminal (see the fifth and seventh passes).
- **Any session's activity** (preview, time, status) renders the sidebar, 22-26 ms in Release
  with 250 sessions, whether it is the shown session's, a kept tab's or another's. Most of it
  is the sidebar's layout, not the rows (see the seventh pass).
- **Switching sessions** is 115 ms between two open ones and 150-165 ms for the first pass of
  one not yet open; a page without a session and back is 160-175 ms each way.
- Opening a long session (about 1 s quiet, 2-3 s under load) is SwiftUI building and laying
  out about 27 transcript segments and their markdown: code blocks' text layout (one typesetter
  pass over each whole block) is the largest single cost, then view and attribute setup and
  the selectable-text overlays (one AppKit view per selectable `Text`, 3-5% of samples). App
  code stays under 2%.
- **Resizing the window** is still the worst interaction, though no longer re-rendering view
  bodies: each size step is SwiftUI's attribute-graph and layout pass over the whole window
  (`NSHostingView.layout`, with the titlebar's toolbar layout about a tenth of it), 50-80 ms per
  step in Debug under load. Toggling the sidebar or the right panel animates the same relayout.
  Text measuring is under 1% of a resize, so a fixed-width transcript column would not help.
  With a long chat that ends in a very tall row, one step of a resize through the widths
  where rows change width takes about half a second (see "The slow resize step").
- While a reply streams, each paced render still costs 10-15 ms in Debug, spread over SwiftUI's
  graph update, the lazy stack's layout and the text overlays.
- A changed session-list row still sends every session through the core twice (filter and
  totals), about 22 ms with 650 sessions. A turn changes its session's row a few times, so it
  was not worth an incremental core API in this pass.
- Markdown parsing and code highlighting run on the main actor only on a warm-up miss: a row
  scrolled to before the background task reached it, or a streaming row's open block.
- Debug is several times slower than Release for this generic SwiftUI and value-type code;
  measure a Release build (`xcodebuild -configuration Release`) before chasing a Debug-only
  cost.

## iOS and iPadOS

Measured on the iPhone 17 and iPad Air 11-inch (M4) simulators (iOS 27.2) with Release
(`-configuration Release`) and Debug builds against the large seed (about 650 sessions) while the
machine's load average was 300-900, so treat single numbers as rough.

### How to measure

- Process CPU over a window: `ps -o cputime= -p <pid>` before and after (no sampling overhead);
  the app's pid is `pgrep -f "<udid>.*Omnigent.app/Omnigent"`.
- Where the main thread goes: `sample <pid> 5`. Sampling during launch makes dyld wait on the
  sampler, so sample from a second or two after launch.
- Open a session at launch without input: write the app's saved tabs file
  (`Library/Application Support/<bundle id>/Tabs/*.json` in the app's data container, see
  `TabPersistence`) with one chat tab selected, then `xcrun simctl launch`.
- Time the connect: point `omnigent.lastServer` at a logging TCP proxy in front of
  `127.0.0.1:6767` and read the request times.
- Why a view re-rendered: `let _ = Self._printChanges()` in its body and
  `xcrun simctl launch --console-pty`.

### Results (November 2026)

| Scenario | Device, build | Result |
| --- | --- | --- |
| Cold launch, New Tab restored: first request / signed in, list shown | iPhone Release | 3.5 s / 3.5-4.2 s |
| Same, fresh install | iPad Debug and Release | 3.6 s / 4.6-5 s |
| Connect itself (`/.well-known` through `/v1/me`, list and updates socket) | both | under 0.2 s |
| Cold launch, a conversation tab restored | iPhone Release | main thread at 100% indefinitely; the screen stays on "Connecting…" because frames stop committing |
| Same | iPad Debug | 1.3-1.5 CPU s per second for 10-30 s; follow-up requests (agent, pull requests, skills) leave 10-30 s late |
| Idle on the session list | both | 0.0% |
| A reply streaming in another session, list shown | iPhone Release | 2.4% CPU, 3 shell redraws |
| Streaming into a 160-item transcript, then idle | iPhone Release* | 9-14% CPU, then 0.0-0.2% |
| Sidebar state rebuild, 650 sessions (`SidebarBenchmarks`) | Mac Debug | 78 ms → 21 ms |
| Typing 20 characters | iPhone Release* | the conversation container and screen re-render about 14 times |

\* With the navigation bar items removed locally, to get past the loop below.

The first 3.5 s of a launch is the simulator loading the app (dyld) before any app code runs;
the connect is fast. The slow sign-in seen on iPad mini and the folded Duo ("about 50 s") is
the conversation re-render loop starving the main actor while a restored chat tab builds, not
the network.

What changed for iOS:

- `SessionListStore`, `ConnectionStore` and `ConversationStore` set observable properties only
  when the value changes (connection phase, updates link, unread set, link and hydration
  state), so a resent server row or status redraws nothing.
- The sidebar no longer counts All and Archived through two `filterSessions` calls over every
  session on each rebuild; nothing showed those counts.

### Where the time still goes

- **The conversation's toolbar loop** (fixed in rounds 3 and 4). With a conversation open,
  `ConversationScreen` re-rendered, re-vended its navigation bar items, the bar's hosting
  controllers updated traits and environment, and that re-rendered `ConversationScreen` again
  (`ToolbarBridge.preferencesDidChange` in every sample). Round 3 made `TranscriptWindowControls`
  a class compared by identity; round 4 replaced the screen's `mode` and `fork` closure bindings,
  which still counted as changed on every pass, with key-path bindings (see below).
- **Typing** (fixed in the Mac second pass, `ComposerDraft`): SwiftUI read the draft binding
  while updating `ConversationScreen`'s inputs, so each keystroke re-rendered the whole screen.
- Not measured here: rotating the iPad, split widths and keyboard show and hide (no input
  access to the iPad simulator in this pass), and the transcript showing under the dock while
  the iPhone layout settles.

## iPhone and iPad, frames and scenarios (round 4)

Instruments, xctrace and XCUITests don't run on the build machine, so Debug builds carry their
own frame monitor and a driver for the motion a user would make.

### Tools

- **Frame monitor** (`OmnigentPlatform/FrameMonitor.swift`, shared with macOS through
  `NSScreen.displayLink`). Launched with `-OmnigentFrameMonitor YES`, a display link logs
  `FrameStats` once a second and over an interval marked by the Darwin notifications
  `ai.omnigent.perf.begin` and `ai.omnigent.perf.end`: frames per second, the hitch-time ratio
  (milliseconds a frame arrived later than one refresh, per second), dropped refreshes, frames
  over 8.3, 16.7 and 33 ms, the worst frame, and how often the conversation screen and
  transcript rendered. It also logs MetricKit payloads (devices only). Read the lines with
  `xcrun simctl spawn <udid> log stream --predicate 'subsystem == "ai.omnigent.perf"'`.
  `simctl spawn notifyutil` can take tens of seconds on a loaded machine, so the app also polls
  `tmp/perf-command` in its data container every 50 ms: appending a `<sequence> <name>` line
  there posts `ai.omnigent.perf.<name>` inside the app at once.
- **Perf driver** (`Apps/Omnigent-iOS/Sources/PerfDriver.swift`), `-OmnigentPerfDriver YES`:
  Darwin notifications (`xcrun simctl spawn <udid> notifyutil -p ai.omnigent.perf.<name>`)
  scroll the view under the window's center (`scroll`) or iPad's sidebar (`scroll.leading`) at
  2,400 pt/s for 3 s up and 3 s back, type 20 characters into the composer (`type`) or the
  palette's field (`type.top`) and delete them, show and hide the keyboard (`keyboard`), rotate
  (`rotate`, iPhone only) and hide or show iPad's sidebar (`sidebar`). Debug-only hooks open a
  session without the system's "Open in" prompt (`open`, reading the id from `tmp/perf-link.txt`
  in the app's container), New Session (`newsession`), the session list (`list`), a Settings page
  (`settings.<page>`, `settings.usage`, `settings.close`), the palette (`palette`) and the right
  panel's tabs (`panel.<tab>`, `panel.close`, `browser`).
- **`Tools/perf/ios_perf.py`** runs the scenarios on a simulator with the build installed and
  prints main-thread CPU (`ps -M`), time until the main thread is quiet, and the interval's
  frame stats, with medians over runs:

```sh
python3 apps/apple/Tools/perf/ios_perf.py launch --udid <udid> --runs 3
python3 apps/apple/Tools/perf/ios_perf.py suite --udid <udid> --runs 3 [--style cli] [--ipad]
python3 apps/apple/Tools/perf/ios_perf.py run open scroll stream --udid <udid> [--sample]
```

`--style cli` launches with `-omnigent:transcript-style cli`; `--ipad` adds rotate, sidebar and
panel and scrolls the sidebar. iPad runs use long transcripts 2 and 3 and iPhone runs 1 and 2
(`--transcript`), so two simulators can stream at once.

Caveats: the simulator draws at 60 Hz on the Mac's GPU, and the monitor sees main-thread
(commit) hitches, not the render server's, so frame rates are not a device's; ProMotion's 8.3 ms
budget shows only as a count. The lower-end simulators (iPhone 17e, iPad A16) run on the same
Mac CPU as the others: they differ in screen size, not speed. Rotation is refused on iPad
("the current windowing mode does not allow programmatic changes"), and dragging a split-view
divider or a window edge needs input the simulator does not take from a script, so iPad
rotation and resizing are measured through the sidebar's show and hide, which changes the
detail's width the same way.

### Results (November 2026)

Debug builds, iOS 27.2 simulators, against the large seed; medians of 3 runs (`ios_perf.py
suite`). Each cell is main-thread CPU, frames per second, hitch-time ratio (ms/s) and the worst
frame over the scenario's interval. "Before" is the round-3 build with the tools added; its CLI
runs and most iPad scenarios could not finish, because opening a transcript started the loop
below and the main thread stayed busy past the script's three-minute limit. The machine's load
average was 90-330 for the iPhone "before" runs and 300-1,000 for the rest (other agents'
builds), so differences under about 50% between before and after are noise; the loops are not.

| Scenario | iPhone chat before | iPhone chat after | iPhone CLI after | iPad chat before | iPad chat after | iPad CLI after |
| --- | --- | --- | --- | --- | --- | --- |
| Scroll the session list (650 sessions), 6 s | 0.44 s, 60 fps, 0, 17 ms | 0.48 s, 60 fps, 3, 33 ms | 0.44 s, 58 fps, 34, 77 ms | 0.58 s, 59 fps, 11, 229 ms | 0.46 s, 60 fps, 3, 33 ms | 0.47 s, 60 fps, 3, 33 ms |
| Search: open the palette, type 20 characters, delete, close | 1.98 s, 46 fps, 221, 750 ms | 1.18 s, 47 fps, 220, 830 ms | 1.00 s, 49 fps, 179, 764 ms | 2.49 s, 54 fps, 95, 1750 ms | 1.94 s, 43 fps, 282, 800 ms | 1.14 s, 48 fps, 204, 817 ms |
| Settings sheet, push Appearance, close | 0.92 s, 54 fps, 102, 386 ms | 0.96 s, 52 fps, 141, 415 ms | 0.72 s, 54 fps, 102, 327 ms | 2.72 s, 48 fps, 201, 22077 ms | 1.27 s, 50 fps, 174, 502 ms | 1.28 s, 49 fps, 187, 492 ms |
| Usage page | 0.32 s, 55 fps, 89, 219 ms | 0.29 s, 45 fps, 178, 210 ms | 0.26 s, 49 fps, 184, 212 ms | 1.39 s, 53 fps, 114, 6542 ms | 0.23 s, 51 fps, 155, 218 ms | 0.34 s, 46 fps, 235, 325 ms |
| Open a long transcript | 19.79 s, 9 fps, 847, 19033 ms (loop: 842 renders) | 2.04 s, 16 fps, 738, 1179 ms | 1.52 s, 22 fps, 641, 605 ms | 46.62 s, 35 fps, 409, 44471 ms (loop: 1202 renders) | 2.23 s, 20 fps, 672, 898 ms | 2.32 s, 19 fps, 685, 1000 ms |
| Open a second one (first kept alive) | 1.73 s, 40 fps, 340, 390 ms | 1.17 s, 29 fps, 510, 458 ms | 1.08 s, 28 fps, 534, 389 ms | - | 1.75 s, 30 fps, 505, 907 ms | 1.49 s, 27 fps, 552, 858 ms |
| Switch back to the first | 0.73 s, 45 fps, 241, 617 ms | 0.84 s, 32 fps, 468, 671 ms | 0.32 s, 46 fps, 230, 316 ms | - | 0.63 s, 40 fps, 328, 500 ms | 0.44 s, 41 fps, 318, 429 ms |
| Fling the transcript up and back, 6 s | 1.18 s, 58 fps, 32, 142 ms | 1.48 s, 52 fps, 138, 301 ms | 0.63 s, 59 fps, 12, 43 ms | - | 1.61 s, 49 fps, 183, 305 ms | 0.78 s, 58 fps, 36, 124 ms |
| Type 20 characters in the composer, delete them | 0.94 s, 54 fps, 98, 172 ms | 1.26 s, 48 fps, 201, 235 ms | 0.84 s, 53 fps, 113, 140 ms | - | 1.43 s, 44 fps, 256, 357 ms | 1.11 s, 50 fps, 172, 246 ms |
| Keyboard show and hide | 0.40 s, 56 fps, 68, 102 ms | 0.41 s, 55 fps, 76, 163 ms | 0.24 s, 57 fps, 50, 93 ms | - | 0.86 s, 47 fps, 220, 327 ms | 0.68 s, 50 fps, 166, 168 ms |
| Stream a reply, 12 s (transcript renders/s) | 1.58 s, 56 fps, 64, 175 ms, 8/s | 1.94 s, 54 fps, 92, 243 ms, 5/s | 1.69 s, 55 fps, 76, 178 ms, 8/s | - | 2.96 s, 49 fps, 172, 471 ms, 8/s | 2.64 s, 51 fps, 147, 501 ms, 9/s |
| iPad: hide and show the sidebar (resize) | - | - | - | - | 1.55 s, 27 fps, 546, 549 ms | 1.40 s, 42 fps, 305, 434 ms |
| iPad: right panel Files, Changes, PRs, close | - | - | - | - | 1.16 s, 52 fps, 136, 300 ms | 0.93 s, 54 fps, 96, 198 ms |

Also on iPhone (chat, after): rotating with a long transcript open and back costs 2.6 s, 27 fps,
553 ms/s and a 1.2 s frame (the transcript re-lays out at each width); New Session from the list
0.65 s, 37 fps, 551 ms worst; a browser tab from a conversation 0.49 s, 41 fps, 412 ms worst.

Launch to the idle session list (no saved tabs, frame monitor off): main thread busy for 3.3-4.5 s
of CPU before and 1.3-5.3 s after (the load swung too much to compare), then 5-9% idle CPU on
both, from other sessions' server events. Lower-end simulators (iPhone 17e, iPad A16): not
measured this round; CoreSimulator stopped answering `simctl install` on the loaded machine, and
they run on the same Mac CPU as the others, so they would only differ in screen size. Rotation:
iPhone rotates (`rotate`); iPad refuses programmatic rotation in its windowing mode, so the
sidebar row stands in for rotating and resizing. Side chats open as chat tabs, so "open a second
one" and "switch back" cover them. A second iPad window (`-OmnigentOpenWindow <session>`) builds
the same views as a tab.

What changed:

- **Bindings that compare equal (the P0 loop).** SwiftUI treats a `Binding` made from closures,
  from `Bindable` or from `.constant` as changed on every update. The window's navigation bar and
  trait updates re-delivered the environment, each pass re-rendered every view holding such a
  binding, and those views re-vended bar items or menus, which updated the bar again. On
  iPhone that held the main thread for 10-45 s (300-1,200 renders) whenever a long session
  opened; on iPad a second chat kept the main thread at 100% indefinitely after a reply.
  The conversation's Chat/Terminal mode (`ConversationModeRoute`), fork sheet
  (`ForkFlow.sheet`) and composer draft (`ComposerTextSource`, `ComposerDraft(binding:)`) are
  now key-path projections of `@State` objects, and a hidden tab's right panel gets a stored
  `false`. Opening a long session now renders the screen 16-20 times.
- **The palette's state is made only while it shows.** The window root sorted every session into
  a palette entry on each render and read the session list to do it, so each list change from
  the server re-rendered the root; the palette also ran its search three or four times per
  keystroke.

Gaps from the code review, measured: the iOS composer is a single glass surface without a
shadow (the glass-plus-shadow stack is the Mac's pill only), and while a reply streams the
transcript's bottom-follow `scrollTo` did not appear in 883 main-thread samples, so neither was
changed here. The Mac app does not start the frame monitor yet: calling
`FrameMonitor.startIfRequested()` at launch is all it needs.

### Where the time still goes (iPhone and iPad)

- **Opening a long session** costs 1.5-2.3 s of main-thread time in Debug, nearly all SwiftUI
  building the visible rows' markdown and code blocks, with one 0.6-1.2 s frame while the
  transcript first lays out. Switching back to a kept tab costs 0.3-0.8 s.
- **Fast scrolling a long chat transcript** drops to 49-52 fps with frames up to 0.3 s as rows
  with code blocks and tables materialize (markdown layout, the Mac performance stream's area);
  the CLI transcript holds 58-59 fps.
- **Keyboard show and hide** cost 0.35-0.45 s each on iPad, mostly UIKit's own input-view
  machinery; the sidebar's collection view also updates.
- **Hiding or showing iPad's sidebar** (the proxy for rotation and split resizing) re-lays out
  the transcript at the new width: about 1.5 s and frames of 0.5 s.
- **Idle CPU is not zero** while other sessions on the server change: each session event
  updates `SessionListStore` and the sidebar (3-7% here, with other agents' sessions busy).
- iPhone apps may draw above 60 Hz on ProMotion devices only with
  `CADisableMinimumFrameDurationOnPhone` in Info.plist; without it SwiftUI animations there
  are capped at 60 Hz (UIKit scrolling is not). Not changed: the simulator can't measure it.

## iPhone and iPad, motion (round 5)

Instruments (`xcrun xctrace record --template 'Time Profiler' --device <udid> --attach <pid>`)
and iOS XCUITests now run on the build machine; the SwiftUI and Animation Hitches templates do
not (the simulator does not support hitch recording).

### Tools

- The frame monitor's interval line also reports the main thread's CPU time (`cpu=`), read from
  `thread_info`, so a step measured from a UI test needs no `ps`.
- **`Tests/OmnigentUITests/PerfMotionUITests.swift`** drives the motion `PerfDriver` could not:
  the keyboard through the composer and an interactive swipe, iPad's split view (opens a second
  long session, splits, drags the divider ±15%, rotates through `XCUIDevice`) and the sidebar
  button. Each step posts `ai.omnigent.perf.begin`/`.end`, attaches a screenshot and fails if
  no transcript shows rows afterwards. Run it with the large seed and read the stats lines:

```sh
xcrun simctl spawn <udid> log stream --style compact --predicate 'subsystem == "ai.omnigent.perf"' &
TEST_RUNNER_OMNIGENT_LONG=1 TEST_RUNNER_OMNIGENT_STYLE=cli xcodebuild test -workspace apps/apple/Omnigent.xcworkspace \
  -scheme Omnigent -destination 'platform=iOS Simulator,id=<udid>' \
  -only-testing:OmnigentUITests/PerfMotionUITests/testPadSplitWithLongTranscripts
```

  `XCUIDevice` orientation changes did not reach the iPhone app on these simulators, so the
  iPhone rotation step posts `ai.omnigent.perf.rotate` to the perf driver instead.

### Results (November 2026)

Debug builds, iOS 27.2 simulators, large seed, long transcript 2 open; medians of 3 runs.
Each cell is main-thread CPU, frames per second, hitch-time ratio (ms/s) and the worst frame.
"Before" is `apple-native-scaffold` at a63e29785. The machine's load average swung between 15
and 960 during these runs, so only differences well over 50% mean anything.

| Scenario | Before | After |
| --- | --- | --- |
| iPhone 18 Pro Max, chat: rotate once | 1.51 s, 27 fps, 550, 1157 ms | 0.64 s, 45 fps, 247, 316 ms |
| iPhone 18 Pro Max, CLI: rotate once | 1.53 s, 19 fps, 684, 1215 ms | 0.41 s, 51 fps, 153, 399 ms |
| iPhone 17e, chat: rotate once | 0.94 s, 38 fps, 373, 948 ms | 0.71 s, 44 fps, 271, 284 ms |
| iPhone 17e, CLI: rotate once | 0.42 s, 51 fps, 150, 391 ms | 0.41 s, 49 fps, 189, 496 ms |
| iPhone 18 Pro Max, chat: keyboard show and hide | 1.26 s, 32 fps, 472, 845 ms | 1.32 s, 36 fps, 399, 783 ms |
| iPhone 18 Pro Max, CLI: keyboard show and hide | 0.85 s, 43 fps, 274, 453 ms | 0.72 s, 46 fps, 242, 465 ms |
| iPhone 17e, chat: keyboard show and hide | 1.07 s, 37 fps, 387, 774 ms | 1.30 s, 38 fps, 363, 700 ms |
| iPhone 17e, CLI: keyboard show and hide | 0.73 s, 48 fps, 207, 393 ms | 0.80 s, 38 fps, 374, 706 ms |
| iPad Pro 11, chat: stream a reply beside a side-chat tab, 12 s (side-chat renders) | every row change (read `rows`) | 1.90 s, 37 fps, 388, 2112 ms (4 renders, transcript 17) |
| iPad Pro 11, chat: drag the split divider 15% (UI test) | - | 2.76 s, 15 fps, 748, 3851 ms |
| iPad Pro 11, chat: rotate the split to portrait (UI test) | - | 3.00 s, 27 fps, 557, 2984 ms |
| iPad Pro 11, CLI: drag the split divider 15% (UI test, 1 run) | - | 2.26 s, 25 fps, 583, 996 ms |
| iPad (A16), chat: drag the split divider 15% (UI test, 1 run) | - | 3.50 s, 21 fps, 643, 1969 ms |
| iPad (A16), chat: rotate the split to portrait (UI test, 1 run) | - | 2.84 s, 30 fps, 493, 2597 ms |
| iPhone 18 Pro Max, chat: rotate once (UI test, 1 run, 4 rotations) | - | 0.50-0.99 s, 40-60 fps, worst 441-970 ms |

What changed:

- **Rotating a large iPhone rebuilt the conversation.** Landscape on the Pro Max sizes is
  regular width, so the split view expanded from a stack into columns and `InspectorColumn` and
  the tab container switched branches: the conversation screen and its transcript were
  destroyed and built again (render counters showed both views leave and appear). Short windows
  (compact vertical size class) now lay out at compact width like every other iPhone
  (`shortWindowsStayCompact()`), and `InspectorColumn` and the tab container keep one structure
  for both size classes (also for iPad windows resized across them). What remains is the
  transcript laying out at the new width.
- **The side-chat tab read its parent's `rows`.** It now reads one `RowWatch`
  (`ConversationStore.watchRow`), updated only when a delta touches that row, so the parent's
  streamed deltas no longer invalidate it; it still renders when its container does (4 times
  in 12 s against the transcript's 17).

### Where the time still goes (round 5)

- **Width changes on iPad** (divider drag, rotation, sidebar) re-lay out every visible row of
  both panes at the new width; each costs 2-4 s of main-thread CPU on this loaded machine, with
  frames over a second. Dragging the divider re-lays out on every drag event.
- **Keyboard show and hide** stay at 0.7-1.3 s of main-thread CPU on iPhone, unchanged: UIKit's
  input-view machinery and the safe-area change re-laying out the visible rows. Driven by the UI
  test (a real tap, then an interactive drag into the keyboard) each costs 1.8-2.8 s on the
  loaded machine.
- **Cold launch with a deep link** signs in once (`.well-known`, `/v1/info` twice, `/v1/me`,
  the list, updates), then resolves the link with a second `.well-known` and `/v1/info` 0.4 s
  later and fetches the session's header three times; no second sign-in was seen. Launch to the
  first request took 7-15 s on the loaded simulator.
- iPad's transcripts going blank during a turn did not reproduce (opening and switching long
  transcripts while a reply streams; divider drags and rotation in a
  split); after a rotation back to landscape the transcript can come back scrolled away from
  the bottom.
