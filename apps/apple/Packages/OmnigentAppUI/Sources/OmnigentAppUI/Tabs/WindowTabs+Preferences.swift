import Foundation
import OmnigentUIComponents

// Settings › General › Links and Sessions: in-app links and sub-agents beside the chat.
extension WindowTabs {
  /// Opens chat links: web pages in an in-app browser tab when `inApp` and the window has a
  /// browser, everything else with `fallback`.
  /// - Parameters:
  ///   - fallback: The default browser.
  ///   - inApp: Settings asks for in-app links.
  /// - Returns: The opener.
  func linkOpener(_ fallback: ExternalURLOpener, inApp: Bool) -> ExternalURLOpener {
    guard inApp, browser != nil else { return fallback }
    let tabs = self
    return ExternalURLOpener { url in
      guard Self.opensInApp(url) else { return await fallback.open(url) }
      tabs.openBrowser(url: url)
      return true
    }
  }

  /// Web pages open in the in-app browser; mail, files and app links do not.
  static func opensInApp(_ url: URL) -> Bool {
    ["http", "https"].contains(url.scheme?.lowercased() ?? "")
  }

  /// The routes for `sessionID`'s conversation; with `subagentsBeside`, a sub-agent opens in
  /// the other pane of a split window.
  func routes(for sessionID: String, subagentsBeside: Bool) -> ConversationTabRoutes {
    var routes = routes(for: sessionID)
    if subagentsBeside, supportsSplit {
      let store = store
      routes.openChild = { store.openBeside(.chat(sessionID: $0)) }
    }
    return routes
  }
}

extension TabStore {
  /// Shows `content` in the pane beside the selected tab, splitting the window when it is not.
  /// - Parameter content: What to show.
  func openBeside(_ content: AppTabContent) {
    let current = selected.flatMap { pane(of: $0.id) } ?? .leading
    let tab = open(content, select: false)
    show(tab.id, in: current == .leading ? .trailing : .leading)
  }
}
