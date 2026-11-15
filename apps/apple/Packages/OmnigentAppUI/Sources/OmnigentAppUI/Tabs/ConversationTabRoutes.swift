import Foundation
import OmnigentUIComponents
import OmnigentWorkspaceUI

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
  /// The right panel of the window, where the window shows its session's beside every tab;
  /// `nil` where the chat shows a panel of its own.
  var windowPanel: WindowPanelRoute?
}

/// The right panel a window shows for its session, as a conversation in one of its tabs
/// reaches it.
struct WindowPanelRoute {
  /// The session's toolbar and right-panel state.
  let chrome: SessionChromeState
  /// The conversation is the session's own chat, whose panel data the window loads.
  let isSessionChat: Bool
  /// Shows the panel on a tab, setting aside any open file or diff.
  let show: @MainActor (InspectorTab) -> Void
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
    if SessionChromeState.isWindowHosted {
      routes.windowPanel = windowPanel(of: ownerID, isSessionChat: sessionID == ownerID)
    }
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

extension WindowTabs {
  /// The right panel the window shows for `sessionID`.
  /// - Parameters:
  ///   - sessionID: The session whose tabs the window shows.
  ///   - isSessionChat: The asking conversation is that session's own chat.
  /// - Returns: The route.
  func windowPanel(of sessionID: String, isSessionChat: Bool) -> WindowPanelRoute {
    let chrome = groups.chrome(sessionID)
    let session = session
    return WindowPanelRoute(chrome: chrome, isSessionChat: isSessionChat) { tab in
      session.workspace(of: sessionID)?.hideDocument()
      chrome.show(tab)
    }
  }
}
