public import OmnigentCoreFFI

/// What this session and its agents cost, for the session overview and the Agents tab.
extension ConversationStore {
  // `nil` (no such route on the server) differs from empty (nothing priced yet), as the core's.
  // swiftlint:disable discouraged_optional_collection
  /// The cost tags of this session and every agent under it, by session id; agents with no
  /// known cost are left out.
  /// - Returns: The tags, or `nil` when the server has none to read.
  /// - Throws: The core's read error.
  public func agentCostTags() async throws(CoreError) -> [String: String]? {
    do {
      return try await core.agentCostTags(sessionId: sessionID).map { tags in
        Dictionary(tags.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
      }
    } catch {
      throw coreError(error)
    }
  }
  // swiftlint:enable discouraged_optional_collection
}
