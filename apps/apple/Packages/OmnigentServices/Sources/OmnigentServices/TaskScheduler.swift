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
    } catch is CancellationError {
      // Cancellation is how the core cancels a timer, so returning at once is the contract.
      return
    } catch {
      // Task.sleep documents CancellationError as its only failure; anything else is a bug.
      preconditionFailure("Task.sleep threw an unexpected error: \(error)")
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
