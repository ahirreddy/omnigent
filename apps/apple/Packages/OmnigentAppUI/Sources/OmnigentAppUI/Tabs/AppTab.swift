public import Foundation
public import OmnigentUIComponents

/// What a tab shows, with the identifiers that are persisted to restore it.
nonisolated public enum AppTabContent: Hashable, Sendable, Codable {
  /// The new-tab page.
  case newTab
  /// The new-session form.
  case newSession
  /// The new-session form adding a nested agent beside `sourceID`.
  case nestedSession(sourceID: String)
  /// The Inbox.
  case inbox
  /// The Canvas.
  case canvas
  /// Automations.
  case automations
  /// Workflows.
  case workflows
  /// Usage.
  case usage
  /// An extension's page, by the extension and the page's route.
  case extensionPage(extensionID: String, route: String)
  /// A project's board, by its folder id.
  case project(folderID: String)
  /// A session's conversation.
  case chat(sessionID: String)
  /// A user shell of a session.
  case terminal(sessionID: String, terminalID: String)
  /// A session harness's own TUI, in tabs saved before the chat showed it; dropped on load.
  case harness(sessionID: String)
  /// A side question from a session's transcript.
  case sideChat(sessionID: String, rowID: String)
  /// A side chat forked from `parentID`, showing only its own turns; `childID` is `nil` until
  /// its first message creates it.
  case sideChatSession(parentID: String, childID: String?)
  /// A sub-agent's whole chat, opened from the session it runs under and shown in that
  /// session's tabs; `parentID` is the session whose tabs it is in.
  case subagent(parentID: String, childID: String)
  /// A web page; the browser host keeps the page under `browserID`.
  case browser(browserID: UUID)
  /// The page an agent drives for a session, read-only.
  case agentBrowser(sessionID: String)
  /// A browser on the agent's machine, streamed as video; `tabID` is the host's tab.
  case remoteBrowser(sessionID: String, tabID: String)

  /// The session the tab belongs to.
  public var sessionID: String? {
    switch self {
    case .chat(let id), .harness(let id), .agentBrowser(let id): id
    case .terminal(let id, _), .sideChat(let id, _), .remoteBrowser(let id, _): id
    case .sideChatSession(let id, _), .subagent(let id, _): id
    case .newTab, .newSession, .nestedSession, .inbox, .canvas, .automations, .workflows, .usage,
      .extensionPage, .project, .browser:
      nil
    }
  }

  /// The session whose conversation the tab shows: a chat's own, a side chat's or a sub-agent's.
  public var conversationID: String? {
    switch self {
    case .chat(let id): id
    case .sideChatSession(_, let childID): childID
    case .subagent(_, let childID): childID
    case .newTab, .newSession, .nestedSession, .inbox, .canvas, .automations, .workflows, .usage,
      .extensionPage, .project, .terminal, .harness, .sideChat, .browser, .agentBrowser,
      .remoteBrowser:
      nil
    }
  }

  /// The session a window of its own can show in place of the tab: a sub-agent's. Every other
  /// tab (a terminal, a page, a side chat) shows only with the session whose tabs it is in.
  public var ownWindowSessionID: String? {
    if case .subagent(_, let childID) = self { return childID }
    return nil
  }

  /// The strip's kind.
  public var kind: TabKind {
    switch self {
    case .newTab: .newTab
    case .newSession, .nestedSession: .newSession
    case .inbox: .inbox
    case .canvas: .canvas
    case .automations: .automations
    case .workflows: .workflows
    case .usage: .usage
    case .extensionPage: .extensionPage
    case .project: .project
    case .chat, .subagent: .chat
    case .terminal: .terminal
    case .harness: .agentTerminal
    case .sideChat, .sideChatSession: .sideChat
    case .browser: .browser
    case .agentBrowser: .agentBrowser
    case .remoteBrowser: .remoteBrowser
    }
  }

  /// Whether opening this content again focuses the tab that already shows it (one chat tab
  /// per session, one tab per terminal) rather than adding a tab.
  public var focusesExisting: Bool {
    switch self {
    case .newTab, .newSession, .nestedSession, .browser: false
    case .inbox, .canvas, .automations, .workflows, .usage, .extensionPage, .project, .chat,
      .terminal, .harness, .sideChat, .subagent, .agentBrowser, .remoteBrowser:
      true
    // Every new side chat is a tab of its own until it has a session.
    case .sideChatSession(_, let childID): childID != nil
    }
  }

  /// The sessions a built tab keeps open: its session's, and a side chat's or sub-agent's own.
  public var openSessionIDs: [String] {
    switch self {
    case .sideChatSession(let parentID, let childID):
      [parentID] + (childID.map { [$0] } ?? [])
    case .subagent(let parentID, let childID):
      [parentID, childID]
    default:
      sessionID.map { [$0] } ?? []
    }
  }

  /// The sidebar row that shows this content, when there is one.
  public var destination: SidebarDestination? {
    switch self {
    case .chat(let id): .session(id)
    case .newSession: .newSession
    case .nestedSession(let sourceID): .nestedSession(sourceID: sourceID)
    case .inbox: .inbox
    case .canvas: .canvas
    case .automations: .automations
    case .workflows: .workflows
    case .usage: .usage
    case .extensionPage(let extensionID, let route):
      .extensionPage(extensionID: extensionID, route: route)
    case .project(let id): .project(id)
    case .newTab, .terminal, .harness, .sideChat, .sideChatSession, .subagent, .browser,
      .agentBrowser, .remoteBrowser:
      nil
    }
  }

  /// The content a sidebar row opens.
  /// - Parameter destination: The row.
  public init(_ destination: SidebarDestination) {
    switch destination {
    case .session(let id): self = .chat(sessionID: id)
    case .newSession: self = .newSession
    case .nestedSession(let sourceID): self = .nestedSession(sourceID: sourceID)
    case .inbox: self = .inbox
    case .canvas: self = .canvas
    case .automations: self = .automations
    case .workflows: self = .workflows
    case .usage: self = .usage
    case .extensionPage(let extensionID, let route):
      self = .extensionPage(extensionID: extensionID, route: route)
    case .project(let id): self = .project(folderID: id)
    }
  }
}

/// One tab of a window: what it shows, whether it is pinned, and what is needed to show it
/// again after a relaunch before its content is built (lazy restore).
nonisolated public struct AppTab: Hashable, Sendable, Codable, Identifiable {
  /// Stable id, kept across relaunches and windows.
  public var id: String
  /// What it shows.
  public var content: AppTabContent
  /// Pinned tabs come first and are icon-only.
  public var isPinned: Bool
  /// The last title shown, for the strip before the content is built.
  public var title: String?
  /// The browser host's opaque restore state for browser tabs; a remote browser tab's
  /// `RemoteBrowserTabRecord` (last URL and profile).
  public var browserState: Data?

  /// Creates a tab.
  /// - Parameters:
  ///   - id: Tab id; a fresh one by default.
  ///   - content: What it shows.
  ///   - isPinned: Pinned.
  ///   - title: Last title.
  ///   - browserState: Browser restore state.
  public init(
    id: String = UUID().uuidString, content: AppTabContent, isPinned: Bool = false,
    title: String? = nil, browserState: Data? = nil
  ) {
    self.id = id
    self.content = content
    self.isPinned = isPinned
    self.title = title
    self.browserState = browserState
  }
}

/// A window's tabs as they are saved: order, pinning, selection, the closed-tab stack and the
/// split view.
nonisolated public struct TabWindowSnapshot: Hashable, Sendable, Codable {
  /// Tabs in strip order, pinned first.
  public var tabs: [AppTab]
  /// The selected tab (the focused pane's, when split).
  public var selectedID: String?
  /// Closed tabs, oldest first; Reopen Closed Tab takes the last.
  public var closed: [AppTab]
  /// The split view, when the window has two panes.
  public var split: TabSplitSnapshot?

  /// Creates a snapshot.
  /// - Parameters:
  ///   - tabs: Tabs.
  ///   - selectedID: Selected tab.
  ///   - closed: Closed tabs.
  ///   - split: The split view.
  public init(
    tabs: [AppTab] = [], selectedID: String? = nil, closed: [AppTab] = [],
    split: TabSplitSnapshot? = nil
  ) {
    self.tabs = tabs
    self.selectedID = selectedID
    self.closed = closed
    self.split = split
  }
}
