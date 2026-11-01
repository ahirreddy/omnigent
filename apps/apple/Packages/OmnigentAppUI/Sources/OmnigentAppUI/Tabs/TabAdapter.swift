import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTerminalStores
import OmnigentTerminalUI
import OmnigentUIComponents

/// Builds the strip's state from the window's tabs and the stores behind them: session titles
/// and attention from the session list, terminal names and activity from the terminal stores,
/// page titles and loading from the browser host.
enum TabAdapter {
  /// The strip's state.
  /// - Parameters:
  ///   - tabs: The window's tabs.
  ///   - session: The connection and its stores.
  ///   - browser: The browser host, if this build has one.
  ///   - issue: A save or restore problem.
  /// - Returns: The state.
  static func state(
    _ tabs: TabStore, session: ServerSession, browser: (any BrowserTabHosting)?, issue: String?
  ) -> TabsState {
    TabsState(
      tabs: tabs.tabs.map {
        item($0, session: session, browser: browser, isSelected: $0.id == tabs.selectedID)
      },
      selectedID: tabs.selectedID,
      recentlyClosed: tabs.closed.reversed().map { item($0, session: session, browser: nil) },
      issue: issue)
  }

  /// One tab.
  /// - Parameters:
  ///   - tab: The tab.
  ///   - session: The connection and its stores.
  ///   - browser: The browser host.
  ///   - isSelected: The selected tab, whose tooltip carries its session's status line.
  /// - Returns: The strip's tab.
  static func item(
    _ tab: AppTab, session: ServerSession, browser: (any BrowserTabHosting)?,
    isSelected: Bool = false
  ) -> TabItemState {
    var item = TabItemState(
      id: tab.id, kind: tab.content.kind, title: tab.title ?? "", isPinned: tab.isPinned)
    switch tab.content {
    case .newTab, .newSession, .inbox, .canvas:
      item.title = tab.content.kind == .newTab ? "New Tab" : tab.content.kind.label.capitalized
      item.canDuplicate = false
    case .chat, .harness, .agentBrowser, .sideChat:
      sessionItem(&item, tab: tab, session: session, isSelected: isSelected)
    case .terminal(let sessionID, let terminalID):
      let store = session.terminalStores[sessionID]
      let row = store?.terminals.rows.first { $0.terminal.id == terminalID }
      item.title =
        store?.controllers[terminalID]?.title ?? row?.terminal.displayLabel ?? tab.title
        ?? "Terminal"
      item.subtitle = session.connection.sessionList.session(sessionID)?.title
      item.status = row.map(terminalStatus) ?? .none
      item.canDuplicate = false
    case .browser(let browserID):
      if let status = browser?.status(of: browserID) {
        item.title = pageTitle(status.title, url: status.url)
        item.link = status.url
        item.isPlayingAudio = status.isAudible
        item.favicon = status.favicon
        item.profileColor = status.profileColor
        item.status = status.hasError ? .failed : (status.isLoading ? .loading : .none)
      } else {
        item.title = tab.title ?? "Browser"
      }
    }
    return item
  }

  /// Chat, agent terminal, agent browser and side chat tabs: titled from their session.
  private static func sessionItem(
    _ item: inout TabItemState, tab: AppTab, session: ServerSession, isSelected: Bool
  ) {
    let connection = session.connection
    let list = connection.sessionList
    guard let id = tab.content.sessionID else { return }
    let summary = list.session(id)
    let attention = status(list.attention(of: id).state, known: summary != nil)
    switch tab.content {
    case .chat:
      item.title = summary?.title ?? tab.title ?? "Session"
      item.subtitle = summary?.agentName
      item.status = attention
      item.isReadOnly = summary?.isReadOnly ?? false
      item.link = SidebarAdapter.webURL(server: connection.connectedServer, sessionID: id)
      // The titlebar has no status line of its own; the selected chat's tooltip carries it.
      if isSelected, let conversation = connection.conversations[id] {
        item.statusDetail =
          SessionStatusLine(ConversationAdapter.state(conversation, summary: summary)).text
      }
    case .harness:
      item.title = summary.map { "\($0.title) (agent)" } ?? tab.title ?? "Agent Terminal"
      item.subtitle = summary?.agentName
      item.status = attention
      item.canDuplicate = false
    case .sideChat(_, let rowID):
      let activity = connection.conversations[id]?.rows.first { $0.id == rowID }?.activity
      item.title =
        activity.map { SideChatTabContainer.detail("question", in: $0) ?? $0.summary }
        ?? tab.title ?? "Side Chat"
      item.subtitle = summary?.title
    default:
      item.title = "Agent Browser"
      item.subtitle = summary?.title
      item.isReadOnly = true
      item.canDuplicate = false
    }
  }

  /// The title worth saving for a tab, so a restored strip shows it before content loads.
  /// - Parameters:
  ///   - tab: The tab.
  ///   - session: The stores.
  ///   - browser: The browser host.
  /// - Returns: The title, or `nil` when there is nothing better than the kind's name.
  static func cachedTitle(
    _ tab: AppTab, session: ServerSession, browser: (any BrowserTabHosting)?
  ) -> String? {
    switch tab.content {
    case .newTab, .newSession, .inbox, .canvas, .agentBrowser: nil
    case .chat, .terminal, .harness, .sideChat, .browser:
      item(tab, session: session, browser: browser).title
    }
  }

  /// A page's title, else its host (without `www.`), else "Browser"; never blank.
  /// - Parameters:
  ///   - title: The page's reported title.
  ///   - url: The page's URL.
  /// - Returns: The title to show.
  static func pageTitle(_ title: String, url: URL?) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    guard var host = url?.host(percentEncoded: false), !host.isEmpty else { return "Browser" }
    if host.hasPrefix("www.") { host.removeFirst(4) }
    return host
  }

  static func status(_ state: OmnigentCoreFFI.AttentionState, known: Bool) -> TabStatus {
    guard known else { return .none }
    return switch OmnigentUIComponents.SessionAttentionState(state) {
    case .needsYou: .needsYou
    case .failed: .failed
    case .working: .running
    case .unread: .unread
    case .idle: .none
    }
  }

  static func terminalStatus(_ row: TerminalRow) -> TabStatus {
    switch row.status {
    case .active: .terminalActivity
    case .exited: .exited
    case .idle, .unknown: .none
    }
  }
}
