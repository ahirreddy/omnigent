import OmnigentCoreFFI

/// What the Tasks tab sends: a task's Run, Continue or Retry, and the plan's controls.
extension ComposerStore {
  /// Sends `message` as the user's next message, leaving the draft alone, as the web's Tasks
  /// tab does (`sendWorkflowMessage`). A message the server refuses shows in ``lastError``.
  /// - Parameter message: The message.
  public func sendTaskMessage(_ message: String) async {
    let row = transcript?.showSending(message)
    do {
      let sent = try await core.sendQueuedMessage(
        sessionId: sessionID, text: message, hold: nil, harness: configuration?.harness, paths: [])
      transcript?.messageAccepted(row, sent)
    } catch {
      transcript?.messageNotSent(row)
      lastError = coreError(error)
    }
  }
}
