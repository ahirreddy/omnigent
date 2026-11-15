#if os(macOS)
  public import AppKit

  /// Waits that end as soon as the main thread has nothing left to do, instead of after a fixed
  /// time. A duration passed to them is only a limit, reached when work keeps coming.
  ///
  /// At rest means a few short run loop turns in a row did no work: no source or event was
  /// handled and the given windows had no layout pending and drew nothing. A turn never sleeps,
  /// so coarse timers (a VM's wake 15 to 90 ms late) don't stretch it. Work still to come at a
  /// later time, a timer or a `Task.sleep`, is not waited for: wait for its effect with
  /// ``waitUntil(timeout:_:)``, or for the time with ``run(for:)`` or `Task.sleep`.
  /// `OMNIGENT_FIXED_WAITS=1` makes every wait take its whole limit again, to tell a flaky wait
  /// from a flaky test.
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
    ///   - windows: The windows whose layout and drawing count, with their sheets and children.
    public static func settle(limit: TimeInterval = 0.1, windows: [NSWindow] = []) {
      let start = CFAbsoluteTimeGetCurrent()
      let deadline = start + limit
      if WaitStats.fixedWaits {
        spin(limit)
        WaitStats.record("settle", since: start, reachedLimit: true)
        return
      }
      var idle = 0
      SettleTrace.begin()
      while idle < idleTurns, CFAbsoluteTimeGetCurrent() < deadline {
        let activity = runTurn(until: deadline, windows: windows)
        SettleTrace.note(activity)
        idle = activity.isEmpty ? idle + 1 : 0
      }
      WaitStats.record("settle", since: start, reachedLimit: idle < idleTurns)
      SettleTrace.end("settle", limit: limit, reachedLimit: idle < idleTurns)
    }

    /// Settles as ``settle(limit:windows:)`` does, suspending between turns so main actor tasks
    /// that are ready run too.
    /// - Parameters:
    ///   - limit: The longest wait.
    ///   - windows: The windows whose layout and drawing count, with their sheets and children.
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
      SettleTrace.begin()
      while idle < idleTurns, CFAbsoluteTimeGetCurrent() < deadline {
        let activity = runTurn(until: deadline, windows: windows)
        await Task.yield()
        SettleTrace.note(activity)
        idle = activity.isEmpty ? idle + 1 : 0
      }
      WaitStats.record("settleTasks", since: start, reachedLimit: idle < idleTurns)
      SettleTrace.end("settleTasks", limit: limit.seconds, reachedLimit: idle < idleTurns)
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
      _ = poll(until: start + seconds)
      WaitStats.record("run(for:)", since: start, reachedLimit: true)
    }

    private static func spin(_ seconds: TimeInterval) {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
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
