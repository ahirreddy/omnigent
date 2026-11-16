# OmnigentViewTesting

Drives SwiftUI and AppKit views in package tests without UI automation: `OffscreenWindow` hosts a
view in a window off every display and sends it real `NSEvent`s; `SystemSideEffects` keeps the
clipboard, Finder, panels and windows away from the person using the Mac; `MainLoop` waits.

## Waiting

A wait's duration is a limit, not a pause. Every wait returns once three short run loop turns
(2 ms each) in a row did no work: no run loop source or event handled, and the watched windows
(an `OffscreenWindow`'s own, with its title bar, sheets and child windows) had no layout pending
and drew nothing. A turn runs run loop passes back to back without sleeping, so a machine's
coarse timers can't stretch it; an idle settle takes about 7 ms.

| Need | Use |
| --- | --- |
| Layout and state after a click or key press | nothing: `click`, `type`, `press` settle |
| A view's own run loop work | `screen.settle()` (limit 0.1 s) |
| A `Task` or `.task {}` a click started | `await screen.settleTasks()` |
| Something that takes as long as it takes | `try await screen.waitUntil { condition }` |
| A condition that costs more than a turn | `screen.waitUntil(idleRecheck: .milliseconds(50)) { ... }` |
| Real elapsed time | `screen.run(for: 0.3)` or `try await Task.sleep(for:)` |
| No window (stores, models) | `MainLoop.settle`, `settleTasks`, `waitUntil`, `run(for:)` |

`settle` runs inside the test's main actor job, so main actor tasks wait for the test to suspend;
`settleTasks` suspends between turns so the ready ones run. Both wait out the views' own timed
pauses (every `Theme.Timing.pause` ending before their limit: the views announce each one in a
test process). Neither waits for other work scheduled for later: a `Task.sleep` in a store, a
future `Timer`, or events from the core's own threads. Wait for their effect with `waitUntil`,
which checks its condition every turn, settles the window once it holds, and costs its timeout
only when it fails.

A titled window: `OffscreenWindow(view, styleMask: [.titled, .fullSizeContentView],
sceneBridging: [.toolbars, .title])` builds it titled from the start.

## Time and motion under test

The test bundle's load sets, for its process only, `OmnigentDisableAnimations`: the views'
animations (`Theme.Motion` in OmnigentUIComponents, `WorkspaceTheme.motion` in
OmnigentWorkspaceUI) resolve to none, and window and scroll animations are off. A test that
needs a real animation sets `Theme.Motion.isEnabled = true` for its duration.

Every timed pause in OmnigentUIComponents (debounces, the transcript's pacing and frame landing,
link settle and flash, notices) passes through `Theme.Timing.pause(_:)`. It is the app's own
length unless a test scales them all for its duration, as the test processes run one test at a
time:

```swift
Theme.Timing.scale = 0  // or 0.1
defer { Theme.Timing.scale = 1 }
```

The gallery exporter takes its settle as `CatalogExportJob.settle`.

## Slow lane

Tests tagged `.slowLane` (the gallery's whole-catalog renders) are disabled where
`OMNIGENT_SKIP_SLOW_TESTS=1`, as the edit loop sets; full and coverage runs keep them.

## Finding slow waits

- `OMNIGENT_WAIT_STATS=1` prints, at exit, each kind of wait's total time, calls and how many
  took their whole limit.
- `OMNIGENT_SETTLE_TRACE=1` prints, for each wait that took its whole limit, what its turns did
  (sources, layout by view, drawing by window, pauses) and how long they took.
- `OMNIGENT_FIXED_WAITS=1` makes every wait take its whole limit again, to tell a wait that
  returns too early from a flaky test.
- `OMNIGENT_WAIT_TURNS=sleep` makes turns sleep in the run loop instead of polling, for
  comparing their cost.
