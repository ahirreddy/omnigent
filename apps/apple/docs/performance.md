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

- **Recent chats stay built** (`KeptAliveTabs`, `TabStore.keptAlive`): the selected tab and the
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

## Where the time still goes

- Opening a long session (about 1 s quiet, 2-3 s under load) is SwiftUI building and laying
  out about 27 transcript segments and their markdown: code blocks' text layout (one typesetter
  pass over each whole block) is the largest single cost, then view and attribute setup and
  the selectable-text overlays (one AppKit view per selectable `Text`, 3-5% of samples). App
  code stays under 2%.
- **Resizing the window** is the worst interaction: each size step re-runs SwiftUI's update
  over the whole window (90% of samples in `NSHostingView.layout`, spread over attribute
  updates, hover updates, the toolbar and the text selection overlays), and single steps take
  up to seconds after the transcript rewraps. Toggling the sidebar or the right panel animates
  the same relayout (480 and 270 ms/s of hitch time). Next levers: a fixed-width transcript
  column during live resize, and fewer selectable `Text` overlays per message.
- While a reply streams, each paced render still costs 10-15 ms in Debug, spread over SwiftUI's
  graph update, the lazy stack's layout and the text overlays.
- A changed session-list row still sends every session through the core twice (filter and
  totals), about 22 ms with 650 sessions. A turn changes its session's row a few times, so it
  was not worth an incremental core API in this pass.
- Markdown parsing and code highlighting still run on the main actor on a cache miss (a
  visible row's first render).
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

- **The conversation's toolbar loop** (fixed in round 3). With a conversation open,
  `ConversationScreen` re-rendered, re-vended its navigation bar items, the bar's hosting
  controllers updated traits and environment, and that re-rendered `ConversationScreen` again
  (`ToolbarBridge.preferencesDidChange` in every sample). The cause was the window's transcript
  controls, a struct the environment saw change on every bar update; `TranscriptWindowControls`
  is now a class compared by identity.
- **Typing** (fixed in the Mac second pass, `ComposerDraft`): SwiftUI read the draft binding
  while updating `ConversationScreen`'s inputs, so each keystroke re-rendered the whole screen.
- Not measured here: rotating the iPad, split widths and keyboard show and hide (no input
  access to the iPad simulator in this pass), and the transcript showing under the dock while
  the iPhone layout settles.
