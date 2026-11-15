#if os(macOS)
  public import AppKit

  extension OffscreenWindow {
    /// Runs the main run loop until the window is at rest, so state changes, layout and drawing
    /// finish; see ``MainLoop``. Main actor tasks wait for the test to suspend: use
    /// ``settleTasks(limit:)`` for them.
    /// - Parameter seconds: The longest wait; reached only while work keeps coming.
    public func settle(_ seconds: TimeInterval = 0.1) {
      host.layoutSubtreeIfNeeded()
      MainLoop.settle(limit: seconds, windows: [window])
      host.layoutSubtreeIfNeeded()
    }

    /// Settles as ``settle(_:)`` does, suspending between turns so main actor tasks that are
    /// ready run too. A task's later `Task.sleep` is not waited for.
    /// - Parameter limit: The longest wait; reached only while work keeps coming.
    public func settleTasks(limit: Duration = .milliseconds(100)) async {
      host.layoutSubtreeIfNeeded()
      await MainLoop.settleTasks(limit: limit, windows: [window])
      host.layoutSubtreeIfNeeded()
    }

    /// Runs the loop and suspends until `condition` holds, checking after every short turn.
    /// - Parameters:
    ///   - timeout: How long the condition may take; only a failing wait takes it all.
    ///   - condition: What to wait for.
    /// - Returns: Whether the condition held within `timeout`.
    public func waitUntil(
      timeout: Duration = .seconds(10), _ condition: () throws -> Bool
    ) async rethrows -> Bool {
      try await MainLoop.waitUntil(timeout: timeout, condition)
    }

    /// Runs the main run loop for all of `seconds`, for what needs real time to pass.
    /// - Parameter seconds: How long to run.
    public func run(for seconds: TimeInterval) {
      host.layoutSubtreeIfNeeded()
      MainLoop.run(for: seconds)
      host.layoutSubtreeIfNeeded()
    }
  }
#endif
