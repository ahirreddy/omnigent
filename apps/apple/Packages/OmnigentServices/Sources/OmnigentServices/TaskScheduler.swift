public import OmnigentCoreFFI

/// `Scheduler` host implementation on Swift concurrency.
public final class TaskScheduler: Scheduler, Sendable {
  /// Creates a scheduler.
  public init() {}

  /// Sleeps for `delayMs` on the continuous clock. Cancelling the calling task ends the sleep
  /// early: the core cancels a timer by cancelling the task that awaits it.
  public func sleep(delayMs: UInt64) async {
    do {
      try await Task.sleep(for: .milliseconds(delayMs))
    } catch {
      // Cancellation is how the core cancels a timer, and the only way Task.sleep fails.
      assert(error is CancellationError, "Task.sleep threw an unexpected error: \(error)")
    }
  }

  /// Runs `task` in an unstructured background task. The core's jobs are user-visible
  /// (hydration, reconnects), so they run at `.userInitiated` rather than `.background`.
  public func spawn(task: CoreTask) {
    Task(priority: .userInitiated) {
      await task.run()
    }
  }
}
