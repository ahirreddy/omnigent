import Foundation
import OmnigentUIComponents

/// How a conversation opens its session's other tabs.
struct ConversationTabRoutes {
  /// The agent's TUI: the chat's Terminal view.
  var openHarness: @MainActor () -> Void
  /// A terminal by id.
  var openTerminal: @MainActor (String) -> Void
  /// A side question by transcript row id, with the question as its title.
  var openSideChat: @MainActor (String, String?) -> Void
  /// A new side chat with a draft, sent at once when the flag is set; `nil` where side chats
  /// open as plain sessions.
  var openNewSideChat: (@MainActor (String, Bool) -> Void)?
  /// Another session. One that runs under this chat's session opens as ``openChild`` does, that
  /// session itself shows its chat, and any other (a parent, a fork) shows with its own tabs.
  var openSession: @MainActor (String) -> Void
  /// A sub-agent's or forked side chat's chat: a tab of this chat's session, or a window of
  /// its own (Settings).
  var openChild: (@MainActor (String) -> Void)?
  /// A typed `/side` is going to an agent that forks the side chat itself: the fork opens in a
  /// tab when the session reports it. Returns what withdraws the wait when it was not sent.
  var awaitForkedSideChat: (@MainActor () -> ForkedSideChats.Withdraw?)?
  /// Starts a terminal (a declared name, or the default) and opens it in a tab.
  var newTerminal: (@MainActor (String?) -> Void)?
  /// Opens a browser tab; `nil` when the window has no browser.
  var openBrowser: (@MainActor () -> Void)?
  /// A terminal-backed chat showed: shows its terminal the first time, per Settings.
  var applyDefaultView: (@MainActor () -> Void)?
  /// The chat's Chat or Terminal choice, kept by the window; `nil` keeps it in the chat's view.
  var viewChoice: SessionViewChoice?
}

extension WindowTabs {
  /// The routes for `sessionID`'s conversation. Its tabs open in `ownerID`'s group: its own, or
  /// for a side chat or sub-agent shown in a tab, the session whose strip that tab is in.
  /// - Parameters:
  ///   - sessionID: The conversation's session.
  ///   - ownerID: The session whose tabs it shows in; its own when `nil`.
  ///   - childrenApart: Opens a sub-agent in a window of its own instead of a tab.
  /// - Returns: The routes.
  func routes(
    for sessionID: String, in ownerID: String? = nil,
    childrenApart: (@MainActor (String) -> Void)? = nil
  ) -> ConversationTabRoutes {
    let groups = groups
    let ownerID = ownerID ?? sessionID
    let openChildTab: @MainActor (String) -> Void = {
      openChild($0, from: sessionID, in: ownerID, apart: childrenApart)
    }
    var routes = ConversationTabRoutes(
      openHarness: { groups.setViewMode(.terminal, for: sessionID) },
      openTerminal: { open(.terminal(sessionID: sessionID, terminalID: $0), in: ownerID) },
      openSideChat: { open(.sideChat(sessionID: sessionID, rowID: $0), in: ownerID, title: $1) },
      openSession: { openSession($0, from: sessionID, in: ownerID, openChild: openChildTab) })
    routes.openChild = openChildTab
    let forks = session.forkedSideChats
    routes.awaitForkedSideChat = {
      guard let wait = awaitForkedSideChat(of: sessionID, in: ownerID) else { return nil }
      let withdraw: ForkedSideChats.Withdraw = { forks.cancel(wait, of: sessionID) }
      return withdraw
    }
    routes.viewChoice = groups.viewChoice(sessionID)
    routes.openNewSideChat = { openPendingSideChat(sessionID, draft: $0, sendNow: $1) }
    routes.newTerminal = { name in
      Task { await newTerminal(in: sessionID, named: name, replacing: nil, shownIn: ownerID) }
    }
    if browser != nil {
      routes.openBrowser = { openBrowser(in: ownerID) }
    }
    return routes
  }
}
