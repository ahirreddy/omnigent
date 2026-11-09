/// Waits for `duration`, or returns early when the task is cancelled, the only way the sleep fails.
/// - Parameter duration: How long to wait.
func sleepUnlessCancelled(for duration: Duration) async {
  do {
    try await Task.sleep(for: duration)
  } catch {
    assert(error is CancellationError, "Task.sleep threw an unexpected error: \(error)")
  }
}
