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
just apple-perf suite --app "$app" --runs 3   # launch, open, switch, type, stream; medians
just apple-perf launch --app "$app" [<session-id>]
just apple-perf open --app "$app" <session-id> [--sample 6]
just apple-perf type --app "$app" [--sample 1]
just apple-perf stream --app "$app" <session-id> --seconds 12 [--sample 1]
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

Scrolling and opening the right panel need synthetic input from another process, which needs
Accessibility permission; they are covered by the package benchmarks below instead.

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

## Where the time still goes

- Opening a long session (about 0.9 s here, 2-3 s under load) is SwiftUI building and laying
  out about 27 transcript segments and their markdown: code blocks' text layout (one typesetter
  pass over each whole block) is the largest single cost, then view and attribute setup and
  the selectable-text overlays (one AppKit view per selectable `Text`, 3-5% of samples). App
  code stays under 2%. The window re-renders the conversation 20-30 times while a session loads
  (header, history pages, configuration, agent info, pull requests); `ConnectedServerView`
  reads every chat's status line for the tab tooltip, so each section change rebuilds the shell.
  Moving that read into the tab item would cut those passes.
- Switching tabs still spends about 0.3 s on the toolbar, the sidebar selection and window
  layout. Hoisting the conversation's toolbar out of the tab would keep its items stable.
- While a reply streams, each paced render still costs 10-15 ms in Debug, spread over SwiftUI's
  graph update, the lazy stack's layout and the text overlays; the whole transcript body
  (scroll modifiers, overlays, the row list) is re-evaluated each time. Reading the rows inside
  the scroll view's content instead of in `TranscriptView` would leave its chrome untouched.
- A changed session-list row still sends every session through the core twice (filter and
  totals), about 30 ms with 650 sessions. A turn changes its session's row a few times, so it
  was not worth an incremental core API in this pass.
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

- **The conversation's toolbar loop (P0).** With a conversation open, `ConversationScreen`
  re-renders, re-vends its navigation bar items, the bar's hosting controllers update traits
  and environment, and that re-renders `ConversationScreen` again
  (`ToolbarBridge.preferencesDidChange` in every sample). The screen's `draft`, `mode` and
  `fork` closure bindings make every pass count as a change. Reading `transcriptTitleMenu` as
  `@Entry` values or not at all, or passing key-path bindings, did not stop it; removing the
  navigation title, title menu and toolbar items did.
- **Typing** (fixed in the Mac second pass, `ComposerDraft`): SwiftUI read the draft binding
  while updating `ConversationScreen`'s inputs, so each keystroke re-rendered the whole screen.
- Not measured here: rotating the iPad, split widths and keyboard show and hide (no input
  access to the iPad simulator in this pass), and the transcript showing under the dock while
  the iPhone layout settles.
