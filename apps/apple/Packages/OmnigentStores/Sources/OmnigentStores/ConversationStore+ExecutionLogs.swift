public import OmnigentCoreFFI

/// Execution logs: the raw items of this session or one of its sub-agents.
extension ConversationStore {
  /// A page of `sessionID`'s items as raw JSON, oldest first, after `cursor`.
  /// - Parameters:
  ///   - sessionID: This session or one of its sub-agents.
  ///   - cursor: Where the page starts; `nil` for the first.
  /// - Returns: The page.
  /// - Throws: The core's error.
  public func executionLogPage(of sessionID: String, after cursor: String?)
    async throws(CoreError) -> RawSessionItemsPage
  {
    do {
      return try await core.rawSessionItems(sessionId: sessionID, after: cursor)
    } catch {
      throw coreError(error)
    }
  }

  /// The events kept from `sessionID`'s open stream (the last 500 since it was opened), those
  /// after the `after` index only.
  /// - Parameters:
  ///   - sessionID: This session or one of its sub-agents.
  ///   - after: The last index already shown; `nil` for all.
  /// - Returns: The events, oldest first.
  public func streamLog(of sessionID: String, after: UInt64?) -> [StreamLogEvent] {
    core.sessionStreamLog(sessionId: sessionID, after: after)
  }
}
