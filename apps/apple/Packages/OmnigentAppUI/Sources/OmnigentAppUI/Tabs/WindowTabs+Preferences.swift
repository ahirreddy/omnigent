import Foundation
import OmnigentUIComponents

// Settings › General › Links and Sessions: in-app links and sub-agents in their own window.
extension WindowTabs {
  /// Opens chat links: web pages in an in-app browser tab of `sessionID` when `inApp` and the
  /// window has a browser, everything else with `fallback`.
  /// - Parameters:
  ///   - fallback: The default browser.
  ///   - inApp: Settings asks for in-app links.
  ///   - sessionID: The session whose chat the links are in.
  /// - Returns: The opener.
  func linkOpener(_ fallback: ExternalURLOpener, inApp: Bool, in sessionID: String)
    -> ExternalURLOpener
  {
    guard inApp, browser != nil else { return fallback }
    let tabs = self
    return ExternalURLOpener { url in
      guard Self.opensInApp(url) else { return await fallback.open(url) }
      tabs.openBrowser(url: url, in: sessionID)
      return true
    }
  }

  /// Web pages open in the in-app browser; mail, files and app links do not.
  static func opensInApp(_ url: URL) -> Bool {
    ["http", "https"].contains(url.scheme?.lowercased() ?? "")
  }

  /// The routes for `sessionID`'s conversation; with `subagentsApart`, a sub-agent opens in a
  /// window of its own where the platform has windows (two sessions side by side are two
  /// windows), else in place.
  func routes(for sessionID: String, subagentsApart: Bool) -> ConversationTabRoutes {
    var routes = routes(for: sessionID)
    if subagentsApart, let openInNewWindow {
      routes.openChild = openInNewWindow
    }
    // Settings › Default transcript view: Terminal opens the agent's TUI tab the first time
    // the session's chat shows; after that, and for remembered tabs, the tabs are the user's.
    // It never changes which session the window shows.
    let groups = groups
    routes.applyDefaultView = {
      let group = groups.group(sessionID)
      guard group.transcriptDefaultApplied.insert(sessionID).inserted,
        TranscriptViewDefault.stored() == .terminal
      else { return }
      group.open(.harness(sessionID: sessionID))
    }
    return routes
  }
}
