import OmnigentCoreFFI

/// What the Tasks tab sends: a task's Run, Continue or Retry, and the plan's controls.
extension ComposerStore {
  /// Sends `message` as the user's next message, leaving the draft alone, as the web's Tasks
  /// tab does (`sendWorkflowMessage`). A message the server refuses shows in ``lastError``.
  /// - Parameter message: The message.
  /// - Returns: Whether the server took it.
  @discardableResult
  public func sendTaskMessage(_ message: String) async -> Bool {
    let row = transcript?.showSending(message)
    do {
      let sent = try await core.sendQueuedMessage(
        sessionId: sessionID, text: message, hold: nil, harness: configuration?.harness, paths: [])
      transcript?.messageAccepted(row, sent)
      return true
    } catch {
      transcript?.messageNotSent(row)
      lastError = coreError(error)
      return false
    }
  }

  /// Sends a workflow's request ("/workflow …", "/save-workflow …") as the web's dialogs do,
  /// leaving the draft alone: a skill the server runs goes as one, anything else as a message.
  /// - Returns: Whether the session took it; a failure is in ``lastError``.
  @discardableResult
  public func sendWorkflowMessage(_ message: String) async -> Bool {
    guard let configuration else { return await sendTaskMessage(message) }
    let action = OmnigentCoreFFI.slashAction(
      text: message, hasAttachments: false, configuration: configuration, skills: skills,
      options: commandOptions)
    guard case .runSkill(let name, let arguments) = action else {
      return await sendTaskMessage(message)
    }
    do {
      _ = try await core.runSkill(
        sessionId: sessionID, text: message, name: name, arguments: arguments)
      return true
    } catch {
      lastError = coreError(error)
      return false
    }
  }
}
