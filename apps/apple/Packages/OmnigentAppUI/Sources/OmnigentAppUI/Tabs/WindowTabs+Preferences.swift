import Foundation
import OmnigentUIComponents

// Settings › General › Links and Sessions: in-app links and sub-agents in their own window.
extension WindowTabs {
  /// Opens chat links: web pages in an in-app browser tab of `sessionID` when `inApp` and the
  /// window has a browser, everything else with `fallback`. The page opens beside the chat.
  /// - Parameters:
  ///   - fallback: The default browser.
  ///   - inApp: Settings asks for in-app links.
  ///   - conversationID: The chat the links are in, when it is a side chat or sub-agent shown
  ///     in a tab of `sessionID`.
  ///   - sessionID: The session whose tabs the chat is in.
  /// - Returns: The opener.
  func linkOpener(
    _ fallback: ExternalURLOpener, inApp: Bool, from conversationID: String? = nil,
    in sessionID: String
  ) -> ExternalURLOpener {
    guard inApp, browser != nil else { return fallback }
    let tabs = self
    return ExternalURLOpener { url in
      guard Self.opensInApp(url) else { return await fallback.open(url) }
      tabs.openLinkBeside(url, from: conversationID, in: sessionID)
      return true
    }
  }

  /// Opens a link from a chat beside it: in the pane the chat is not in, splitting the window
  /// when it is one pane. A window that cannot split opens a tab.
  /// - Parameters:
  ///   - url: The page.
  ///   - conversationID: The chat the link is in, when it is not `sessionID`'s own.
  ///   - sessionID: The session whose tabs the chat is in, where the page opens.
  func openLinkBeside(_ url: URL, from conversationID: String? = nil, in sessionID: String) {
    guard supportsSplit, let browser else {
      openBrowser(url: url, in: sessionID)
      return
    }
    let page = browser.makePage(url: url)
    let store = groups.group(sessionID)
    let chat = store.tabs.first { $0.content.conversationID == conversationID ?? sessionID }
    // A chat whose tab is gone leaves the pane that took the click.
    let chatPane = chat.flatMap { store.pane(of: $0.id) } ?? store.split?.focused ?? .leading
    let tab = store.open(.browser(browserID: page.id), select: false, browserState: page.state)
    store.show(tab.id, in: chatPane.other)
    groups.show(.session(sessionID))
  }

  /// Web pages open in the in-app browser; mail, files and app links do not.
  static func opensInApp(_ url: URL) -> Bool {
    ["http", "https"].contains(url.scheme?.lowercased() ?? "")
  }

  /// The routes for `sessionID`'s conversation, shown in `ownerID`'s tabs (its own when `nil`).
  /// A sub-agent opens in a tab of that strip; with `subagentsApart`, in a window of its own
  /// where the platform has windows.
  func routes(for sessionID: String, in ownerID: String? = nil, subagentsApart: Bool)
    -> ConversationTabRoutes
  {
    var routes = routes(
      for: sessionID, in: ownerID, childrenApart: subagentsApart ? openInNewWindow : nil)
    // Settings › Default transcript view: Terminal shows the agent's TUI the first time the
    // session's chat shows in this window; after that the choice is the user's.
    let choice = groups.viewChoice(sessionID)
    routes.applyDefaultView = {
      guard choice.mode == nil else { return }
      choice.mode = TranscriptViewDefault.stored() == .terminal ? .terminal : .chat
    }
    return routes
  }
}
