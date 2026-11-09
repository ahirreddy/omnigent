public import OmnigentCoreFFI

extension CreationStore {
  /// Creates a session running the unsaved custom agent `draft` (uploaded with the session, as
  /// the web does), starts it on `selection`'s host, then sends `firstMessage`. A start that
  /// failed leaves the session created with that error and the message unsent.
  /// - Parameters:
  ///   - draft: The agent form.
  ///   - selection: Host, workspace and worktree; its agent is not used.
  ///   - firstMessage: Sent once the session runs; may be empty.
  public func create(
    agent draft: AgentDraft, _ selection: CreationSelection, firstMessage: String
  ) async {
    await createThenSend(firstMessage: firstMessage) { core in
      let created = try await core.createSessionWithAgent(
        draft: draft, selection: selection, title: "")
      if case .failed(let error) = created.launch {
        return (created.receipt.sessionId, error)
      }
      return (created.receipt.sessionId, nil)
    }
  }
}
