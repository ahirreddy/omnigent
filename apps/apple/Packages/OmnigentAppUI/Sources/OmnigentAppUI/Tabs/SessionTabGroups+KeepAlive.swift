import Foundation

extension SessionTabGroups {
  /// The tabs whose content stays built: the shown tab and the most recently shown chats and
  /// side chats of the live sessions (``liveSessionIDs``), this session's or another's, `limit`
  /// conversations at most. A split session shows two tabs, one in each pane. A shown tab of
  /// another kind takes no conversation's place, and under a session-less page they all stay
  /// hidden, ready for the way back.
  /// - Parameter limit: The most conversations to keep, a shown one included.
  /// - Returns: The tabs, in a stable order (by session, then strip order).
  public func keptAlive(limit: Int = TabStore.keptAliveLimit) -> [AppTab] {
    var places = KeptPlaces(conversations: limit)
    var kept: Set<String> = []
    for tab in current?.shownTabs ?? [] {
      kept.insert(tab.id)
      places.take(tab.content)
    }
    let live = liveSessionIDs
    for id in recentTabs where !places.isFull && !kept.contains(id) {
      guard let (sessionID, tab) = tab(id), live.contains(sessionID), places.take(tab.content)
      else { continue }
      kept.insert(id)
    }
    return groups.keys.sorted().flatMap { sessionID in
      groups[sessionID]?.tabs.filter { kept.contains($0.id) } ?? []
    }
  }
}
