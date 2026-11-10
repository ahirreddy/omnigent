import Foundation
import OmnigentCoreFFI
import OmnigentRemoteBrowser
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
    var sideChats = SideChatNumbers()
    return TabsState(
      tabs: tabs.tabs.map {
        var entry = item($0, session: session, browser: browser)
        entry.pane = tabs.pane(of: $0.id)
        entry.status = status(entry.status, isUnread: tabs.unread.contains($0.id))
        if case .sideChatSession(let parentID, _) = $0.content {
          entry.title = sideChats.next(parentID)
        }
        return entry
      },
      selectedID: tabs.selectedID,
      recentlyClosed: tabs.closed.reversed().map { item($0, session: session, browser: nil) },
      issue: issue, split: tabs.splitState)
  }

  /// One tab.
  /// - Parameters:
  ///   - tab: The tab.
  ///   - session: The connection and its stores.
  ///   - browser: The browser host.
  /// - Returns: The strip's tab.
  static func item(
    _ tab: AppTab, session: ServerSession, browser: (any BrowserTabHosting)?
  ) -> TabItemState {
    var item = TabItemState(
      id: tab.id, kind: tab.content.kind, title: tab.title ?? "", isPinned: tab.isPinned)
    switch tab.content {
    case .newTab, .newSession, .inbox, .canvas, .automations, .usage:
      item.title = tab.content.kind == .newTab ? "New Tab" : tab.content.kind.label.capitalized
      item.canDuplicate = false
    case .chat, .harness, .agentBrowser, .sideChat, .sideChatSession:
      sessionItem(&item, tab: tab, session: session)
    case .terminal(let sessionID, let terminalID):
      let store = session.terminals(of: sessionID)
      let row = store?.terminals.rows.first { $0.terminal.id == terminalID }
      item.title =
        store?.controllers[terminalID]?.title ?? row?.terminal.displayLabel ?? tab.title
        ?? "Terminal"
      item.subtitle = session.connection.sessionList.sessionWithoutActivity(sessionID)?.title
      item.status = row.map(terminalStatus) ?? .none
      item.canDuplicate = false
    case .remoteBrowser(let sessionID, let tabID):
      remoteItem(&item, tab: tab, session: session, sessionID: sessionID, tabID: tabID)
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
    // A session's tabs follow its primary chat, which only leaves with the session.
    item.groupID = tab.content.sessionID
    item.leadsGroup = tab.content.isPrimaryChat
    item.isClosable = !item.leadsGroup
    if item.leadsGroup { item.canDuplicate = false }
    return item
  }

  /// A remote browser tab: its page title and loading state from its live store.
  private static func remoteItem(
    _ item: inout TabItemState, tab: AppTab, session: ServerSession, sessionID: String,
    tabID: String
  ) {
    item.subtitle = session.connection.sessionList.sessionWithoutActivity(sessionID)?.title
    item.canDuplicate = false
    guard let store = session.remoteBrowsers?.existingStore(sessionID: sessionID, tabID: tabID)
    else {
      item.title = tab.title ?? "Remote Browser"
      return
    }
    let navigation = store.navigation
    let url = URL(string: navigation.url)
    item.title = pageTitle(navigation.title, url: url)
    item.link = url
    if store.isEnded {
      item.status = .exited
    } else if case .failed = store.snapshot.connection {
      item.status = .failed
    } else if navigation.loading {
      item.status = .loading
    }
  }

  /// Chat, agent terminal, agent browser and side chat tabs: titled from their session.
  private static func sessionItem(_ item: inout TabItemState, tab: AppTab, session: ServerSession) {
    let connection = session.connection
    let list = connection.sessionList
    guard let id = tab.content.sessionID else { return }
    let summary = list.sessionWithoutActivity(id)
    let attention = status(list.attention(of: id).state, known: summary != nil)
    switch tab.content {
    case .chat:
      item.title = summary?.title ?? tab.title ?? "Session"
      item.subtitle = summary.flatMap(context)
      item.status = attention
      item.isReadOnly = summary?.isReadOnly ?? false
      item.canRenameSession = summary?.canRename == true
      item.link = SidebarAdapter.webURL(server: connection.connectedServer, sessionID: id)
    case .harness:
      item.title = summary.map { "\($0.title) (agent)" } ?? tab.title ?? "Agent Terminal"
      item.subtitle = summary.flatMap(context)
      item.status = attention
      item.canDuplicate = false
    case .sideChat(_, let rowID):
      let activity = connection.openConversation(id)?.watchRow(rowID).row?.activity
      item.title =
        activity.map { SideChatTabContainer.detail("question", in: $0) ?? $0.summary }
        ?? tab.title ?? "Side Chat"
      item.subtitle = summary?.title
    case .sideChatSession(_, let childID):
      item.title = TabKind.sideChat.label
      item.subtitle = summary?.title
      item.canDuplicate = false
      if let childID, connection.openConversation(childID)?.isRunning == true {
        item.status = .running
      }
    default:
      item.title = "Agent Browser"
      item.subtitle = summary?.title
      item.isReadOnly = true
      item.canDuplicate = false
    }
  }

  /// Reads a chat tab's status line for its tooltip, in the tab's own body: the shell building
  /// the strip's state then does not redraw for the session's header, decisions and sections.
  /// - Parameter session: The connection and its stores.
  /// - Returns: The reader.
  static func statusDetails(_ session: ServerSession) -> TabStatusDetails {
    TabStatusDetails(owner: session) { tabID in
      guard case .chat(let id) = session.tabs.tab(tabID)?.tab.content,
        let conversation = session.connection.openConversation(id)
      else { return nil }
      let summary = session.connection.sessionList.sessionWithoutActivity(id)
      return ConversationAdapter.statusLine(conversation, summary: summary).text
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
    case .newTab, .newSession, .inbox, .canvas, .automations, .usage, .agentBrowser: nil
    case .chat, .terminal, .harness, .sideChat, .sideChatSession, .browser, .remoteBrowser:
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

  /// A session tab's context line: the agent's display name and the project folder, for
  /// example `Claude Code · omnigent`; never the raw agent id.
  static func context(_ summary: OmnigentCoreFFI.SessionSummary) -> String? {
    let parts = [
      agentDisplayName(summary.agentName),
      URL(filePath: summary.workspace).lastPathComponent,
    ]
    let shown = parts.filter { !$0.isEmpty && $0 != "/" }
    return shown.isEmpty ? nil : shown.joined(separator: " \u{00B7} ")
  }

  /// A readable agent name: a known harness's label ("codex-native" is "Codex"), else the name
  /// with its separators as spaces ("tabs_fixture_agent" is "Tabs fixture agent").
  static func agentDisplayName(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    let harness = HarnessAppearance(harness: trimmed)
    if harness.identifier != "fallback" { return harness.label }
    // A name that already reads as words keeps its own capitals.
    guard trimmed.contains(where: { $0 == "_" || $0 == "-" }), !trimmed.contains(" ") else {
      return trimmed
    }
    let words = trimmed.split(whereSeparator: { $0 == "_" || $0 == "-" }).joined(separator: " ")
    return words.prefix(1).uppercased() + words.dropFirst()
  }

  /// A tab's status with the window's unread mark: it shows when nothing more urgent does.
  static func status(_ status: TabStatus, isUnread: Bool) -> TabStatus {
    guard isUnread else { return status }
    return switch status {
    case .none, .exited: .unread
    default: status
    }
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
