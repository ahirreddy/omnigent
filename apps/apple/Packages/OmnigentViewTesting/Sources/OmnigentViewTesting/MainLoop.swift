#if os(macOS)
  public import AppKit

  /// Waits that end as soon as the main thread has nothing left to do, instead of after a fixed
  /// time. A duration passed to them is only a limit, reached when work keeps coming.
  ///
  /// At rest means, for a few short run loop turns in a row: no source or event was handled, no
  /// shown window has layout or drawing pending, no run loop timer is due before the limit and,
  /// for the async waits, no `Task.sleep` ends before it. `OMNIGENT_FIXED_WAITS=1` makes every
  /// wait take its whole limit again, to tell a flaky wait from a flaky test.
  @MainActor
  public enum MainLoop {
    /// One turn: short, so a wait ends within a few milliseconds of the work running out.
    static let turn: TimeInterval = 0.002
    /// Idle turns in a row that count as at rest.
    static let idleTurns = 3

    /// Runs the main run loop until it is at rest, or until `limit` passes.
    ///
    /// It runs inside the caller's main actor job, so main actor tasks wait for the caller to
    /// suspend; ``settleTasks(limit:windows:)`` lets them run too.
    /// - Parameters:
    ///   - limit: The longest wait, in seconds.
    ///   - windows: Windows never shown whose layout counts too, as every shown window's does.
    public static func settle(limit: TimeInterval = 0.1, windows: [NSWindow] = []) {
      let start = CFAbsoluteTimeGetCurrent()
      let deadline = start + limit
      if WaitStats.fixedWaits {
        spin(limit)
        WaitStats.record("settle", since: start, reachedLimit: true)
        return
      }
      var idle = 0
      while idle < idleTurns, CFAbsoluteTimeGetCurrent() < deadline {
        idle = runTurn(until: deadline, windows: windows) ? 0 : idle + 1
      }
      WaitStats.record("settle", since: start, reachedLimit: idle < idleTurns)
    }

    /// Settles as ``settle(limit:windows:)`` does, suspending between turns so main actor tasks,
    /// and what they wait for, run too. A `Task.sleep` ending before `limit` is waited for.
    /// - Parameters:
    ///   - limit: The longest wait.
    ///   - windows: Windows never shown whose layout counts too, as every shown window's does.
    public static func settleTasks(
      limit: Duration = .milliseconds(100), windows: [NSWindow] = []
    ) async {
      let start = CFAbsoluteTimeGetCurrent()
      let deadline = start + limit.seconds
      if WaitStats.fixedWaits {
        try? await Task.sleep(for: limit)
        spin(0.02)
        WaitStats.record("settleTasks", since: start, reachedLimit: true)
        return
      }
      var idle = 0
      while idle < idleTurns, CFAbsoluteTimeGetCurrent() < deadline {
        let busy = runTurn(until: deadline, windows: windows)
        await Task.yield()
        let sleeping = SleepTracker.hasSleep(endingBefore: deadline)
        idle = busy || sleeping ? 0 : idle + 1
      }
      WaitStats.record("settleTasks", since: start, reachedLimit: idle < idleTurns)
    }

    /// Runs the loop and suspends until `condition` holds, checking it after every turn.
    /// - Parameters:
    ///   - timeout: How long the condition may take; only a failing wait takes it all.
    ///   - condition: What to wait for.
    /// - Returns: Whether the condition held within `timeout`.
    public static func waitUntil(
      timeout: Duration = .seconds(10), _ condition: () throws -> Bool
    ) async rethrows -> Bool {
      let start = CFAbsoluteTimeGetCurrent()
      let deadline = start + timeout.seconds
      while CFAbsoluteTimeGetCurrent() < deadline {
        if try condition() {
          WaitStats.record("waitUntil", since: start, reachedLimit: false)
          return true
        }
        _ = runTurn(until: deadline, windows: [])
        await Task.yield()
      }
      WaitStats.record("waitUntil", since: start, reachedLimit: true)
      return try condition()
    }

    /// Runs the loop until `condition` holds, without suspending: main actor tasks don't run.
    /// - Parameters:
    ///   - condition: What to wait for.
    ///   - timeout: How long the condition may take, in seconds.
    /// - Returns: Whether the condition held within `timeout`.
    public static func settle(
      until condition: () throws -> Bool, timeout: TimeInterval = 10
    ) rethrows -> Bool {
      let start = CFAbsoluteTimeGetCurrent()
      let deadline = start + timeout
      while CFAbsoluteTimeGetCurrent() < deadline {
        if try condition() {
          WaitStats.record("settleUntil", since: start, reachedLimit: false)
          return true
        }
        _ = runTurn(until: deadline, windows: [])
      }
      WaitStats.record("settleUntil", since: start, reachedLimit: true)
      return try condition()
    }

    /// Runs the loop for all of `seconds`, for what needs real time to pass, such as a timer.
    /// - Parameter seconds: How long to run.
    public static func run(for seconds: TimeInterval) {
      let start = CFAbsoluteTimeGetCurrent()
      spin(seconds)
      WaitStats.record("run(for:)", since: start, reachedLimit: true)
    }

    private static func spin(_ seconds: TimeInterval) {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// Runs one turn of the loop, then finishes the windows' pending layout and drawing.
    /// - Parameters:
    ///   - deadline: The wait's end, as an absolute time.
    ///   - windows: Windows to check besides every shown one.
    /// - Returns: Whether anything happened or is still due before `deadline`.
    static func runTurn(until deadline: CFAbsoluteTime, windows: [NSWindow]) -> Bool {
      let slice = min(turn, max(0, deadline - CFAbsoluteTimeGetCurrent()))
      var busy = CFRunLoopRunInMode(.defaultMode, slice, true) == .handledSource
      // Zero means no timer is scheduled.
      let nextTimer = CFRunLoopGetNextTimerFireDate(CFRunLoopGetMain(), .defaultMode)
      if nextTimer > 0, nextTimer < deadline { busy = true }
      let shown = NSApp.windows.filter(\.isVisible)
      for window in shown + windows.filter({ !$0.isVisible }) where finishPendingWork(window) {
        busy = true
      }
      return busy
    }

    /// Lays out and draws what a window has pending.
    /// - Parameter window: The window.
    /// - Returns: Whether it had anything pending.
    static func finishPendingWork(_ window: NSWindow) -> Bool {
      guard let content = window.contentView else { return false }
      // A window never shown never draws, so its drawing flag never clears.
      let needsDrawing = window.isVisible && window.viewsNeedDisplay
      guard needsDrawing || hasPendingLayout(content) else { return false }
      content.updateConstraintsForSubtreeIfNeeded()
      content.layoutSubtreeIfNeeded()
      if window.isVisible { window.displayIfNeeded() }
      return true
    }

    /// Whether a view, or a shown one under it, needs its constraints updated or a layout.
    /// - Parameter root: The view.
    /// - Returns: Whether any of them does.
    static func hasPendingLayout(_ root: NSView) -> Bool {
      var pending: [NSView] = [root]
      while let view = pending.popLast() {
        if view.isHidden { continue }
        if view.needsLayout || view.needsUpdateConstraints { return true }
        pending.append(contentsOf: view.subviews)
      }
      return false
    }
  }

  extension Duration {
    /// The duration in seconds.
    var seconds: TimeInterval {
      let (seconds, attoseconds) = components
      return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
  }
#endif
