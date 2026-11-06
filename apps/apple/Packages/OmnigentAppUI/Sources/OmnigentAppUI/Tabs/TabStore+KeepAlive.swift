import Foundation

extension TabStore {
  /// How many tabs stay built at most, the shown one included. A long conversation's views cost
  /// about a second to build again in Debug, so recently shown chats are kept; the cap bounds
  /// their memory.
  public static let keptAliveLimit = 3

  /// The tabs whose content stays built: the selected tab and the most recently selected chats
  /// and side chats, up to `limit`, in strip order. A split window keeps only its panes' tabs.
  /// - Parameter limit: The most tabs to keep, the selected one included.
  /// - Returns: The tabs; empty when none is selected.
  public func keptAlive(limit: Int = keptAliveLimit) -> [AppTab] {
    guard let selectedID, split == nil else { return selected.map { [$0] } ?? [] }
    var kept: Set<String> = [selectedID]
    for id in recentIDs where kept.count < limit && id != selectedID {
      if let tab = tab(id), tab.content.staysBuiltWhileHidden { kept.insert(id) }
    }
    return tabs.filter { kept.contains($0.id) }
  }

  /// Puts `id` first in ``recentIDs``.
  func noteShown(_ id: String) {
    recentIDs.removeAll { $0 == id }
    recentIDs.insert(id, at: 0)
    // Closed tabs drop out here instead of on every close.
    if recentIDs.count > Self.recentLimit {
      let open = Set(tabs.map(\.id))
      recentIDs = Array(recentIDs.filter(open.contains).prefix(Self.recentLimit))
    }
  }

  private static let recentLimit = 16
}

extension AppTabContent {
  /// Conversations are worth keeping built while hidden: rebuilding a long one is slow, and the
  /// other kinds keep their live content (pages, terminals) in their own stores.
  var staysBuiltWhileHidden: Bool {
    switch self {
    case .chat, .sideChat, .sideChatSession: true
    case .newTab, .newSession, .inbox, .canvas, .automations, .usage, .terminal, .harness,
      .browser, .agentBrowser, .remoteBrowser:
      false
    }
  }
}
