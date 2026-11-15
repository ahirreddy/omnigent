public import OmnigentCoreFFI

/// What the sandbox status panel asks the server for.
extension ConversationStore {
  /// Asks the server to wake the session's sandbox and start its agent, or to stop the agent.
  /// One request, never retried; the session's next status says what came of it.
  /// - Parameter operation: Wake or stop.
  /// - Returns: What the server did.
  /// - Throws: Why the server refused.
  @discardableResult
  public func performSandboxOperation(
    _ operation: SandboxOperation
  ) async throws(CoreError) -> SandboxOperationOutcome {
    do {
      return try await core.sandboxOperation(sessionId: sessionID, operation: operation)
    } catch {
      throw coreError(error)
    }
  }
}
