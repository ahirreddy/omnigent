import Foundation

extension TabStore {
  /// How many conversations stay built at most, a shown one included. A long conversation's
  /// views cost about a second to build again in Debug, so recently shown chats are kept; the
  /// cap bounds their memory.
  public static let keptAliveLimit = 3

  /// The tabs whose content stays built: the selected tab and the most recently selected chats
  /// and side chats, `limit` conversations at most, in strip order. A selected tab of another
  /// kind takes no conversation's place. A split window keeps only its panes' tabs.
  /// - Parameter limit: The most conversations to keep, a selected one included.
  /// - Returns: The tabs; empty when none is selected.
  public func keptAlive(limit: Int = keptAliveLimit) -> [AppTab] {
    guard let selected, split == nil else { return selected.map { [$0] } ?? [] }
    var places = KeptPlaces(conversations: limit)
    var kept: Set<String> = [selected.id]
    places.take(selected.content)
    for id in recentIDs where !places.isFull && id != selected.id {
      if let tab = tab(id), places.take(tab.content) { kept.insert(id) }
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

/// The places left for tabs that stay built while hidden. Conversations are the kind worth
/// keeping: building a long one again is slow, and the other kinds keep their live content
/// (pages, terminals) in their own stores.
struct KeptPlaces {
  private var conversations: Int

  init(conversations: Int) {
    self.conversations = conversations
  }

  /// No hidden tab can take a place any more.
  var isFull: Bool { conversations <= 0 }

  /// Takes a place for a tab showing `content`.
  /// - Returns: Whether a hidden tab showing it stays built.
  @discardableResult
  mutating func take(_ content: AppTabContent) -> Bool {
    switch content {
    case .chat, .sideChat, .sideChatSession:
      guard conversations > 0 else { return false }
      conversations -= 1
      return true
    case .newTab, .newSession, .inbox, .canvas, .automations, .usage, .terminal, .harness,
      .browser, .agentBrowser, .remoteBrowser:
      return false
    }
  }
}
