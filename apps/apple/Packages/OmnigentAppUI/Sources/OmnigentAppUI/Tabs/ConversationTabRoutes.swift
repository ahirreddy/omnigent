import Foundation
import OmnigentUIComponents

/// How a conversation opens its session's other tabs.
struct ConversationTabRoutes {
  /// The agent's TUI.
  var openHarness: @MainActor () -> Void
  /// A terminal by id.
  var openTerminal: @MainActor (String) -> Void
  /// A side question by transcript row id, with the question as its title.
  var openSideChat: @MainActor (String, String?) -> Void
  /// A new side chat with a draft, sent at once when the flag is set; `nil` where side chats
  /// open as plain sessions.
  var openNewSideChat: (@MainActor (String, Bool) -> Void)?
  /// Another session (a sub-agent or the parent): the window shows it with its tabs.
  var openSession: @MainActor (String) -> Void
  /// A sub-agent's chat, when it opens elsewhere than `openSession` (a window of its own).
  var openChild: (@MainActor (String) -> Void)?
  /// Starts a terminal (a declared name, or the default) and opens it in a tab.
  var newTerminal: (@MainActor (String?) -> Void)?
  /// Opens a browser tab; `nil` when the window has no browser.
  var openBrowser: (@MainActor () -> Void)?
  /// A terminal-backed chat showed: opens its terminal the first time, per Settings.
  var applyDefaultView: (@MainActor () -> Void)?
}

extension WindowTabs {
  /// The routes for `sessionID`'s conversation: its tabs open in its own group.
  func routes(for sessionID: String) -> ConversationTabRoutes {
    let groups = groups
    var routes = ConversationTabRoutes(
      openHarness: { groups.open(.harness(sessionID: sessionID)) },
      openTerminal: { groups.open(.terminal(sessionID: sessionID, terminalID: $0)) },
      openSideChat: { groups.open(.sideChat(sessionID: sessionID, rowID: $0), title: $1) },
      openSession: { groups.show(.session($0)) })
    routes.openNewSideChat = { openPendingSideChat(sessionID, draft: $0, sendNow: $1) }
    routes.newTerminal = { name in
      Task { await newTerminal(in: sessionID, named: name, replacing: nil) }
    }
    if browser != nil {
      routes.openBrowser = { openBrowser(in: sessionID) }
    }
    return routes
  }
}
