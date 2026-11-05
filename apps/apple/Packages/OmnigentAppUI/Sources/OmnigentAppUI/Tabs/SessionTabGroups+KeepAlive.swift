import Foundation

extension SessionTabGroups {
  /// The tabs whose content stays built: the shown tab and the most recently shown chats and
  /// side chats of the live sessions (``liveSessionIDs``), this session's or another's, up to
  /// `limit`. Under a session-less page they all stay hidden, ready for the way back. A split
  /// session builds only its panes' tabs.
  /// - Parameter limit: The most tabs to keep, the shown one included.
  /// - Returns: The tabs, in a stable order (by session, then strip order).
  public func keptAlive(limit: Int = TabStore.keptAliveLimit) -> [AppTab] {
    var kept: Set<String> = []
    if let current {
      guard let selected = current.selected else { return [] }
      guard current.split == nil else { return [selected] }
      kept.insert(selected.id)
    }
    let live = liveSessionIDs
    for id in recentTabs where kept.count < limit && !kept.contains(id) {
      guard let (sessionID, tab) = tab(id), live.contains(sessionID),
        tab.content.staysBuiltWhileHidden
      else { continue }
      kept.insert(id)
    }
    return groups.keys.sorted().flatMap { sessionID in
      groups[sessionID]?.tabs.filter { kept.contains($0.id) } ?? []
    }
  }
}
