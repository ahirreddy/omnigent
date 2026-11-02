public import Foundation
public import OmnigentUIComponents

/// What a tab shows, with the identifiers that are persisted to restore it.
nonisolated public enum AppTabContent: Hashable, Sendable, Codable {
  /// The new-tab page.
  case newTab
  /// The new-session form.
  case newSession
  /// The Inbox.
  case inbox
  /// The Canvas.
  case canvas
  /// A session's conversation.
  case chat(sessionID: String)
  /// A user shell of a session.
  case terminal(sessionID: String, terminalID: String)
  /// A session harness's own TUI.
  case harness(sessionID: String)
  /// A side question from a session's transcript.
  case sideChat(sessionID: String, rowID: String)
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
    case .newTab, .newSession, .inbox, .canvas, .browser: nil
    }
  }

  /// The strip's kind.
  public var kind: TabKind {
    switch self {
    case .newTab: .newTab
    case .newSession: .newSession
    case .inbox: .inbox
    case .canvas: .canvas
    case .chat: .chat
    case .terminal: .terminal
    case .harness: .agentTerminal
    case .sideChat: .sideChat
    case .browser: .browser
    case .agentBrowser: .agentBrowser
    case .remoteBrowser: .remoteBrowser
    }
  }

  /// Whether opening this content again focuses the tab that already shows it (one chat tab
  /// per session, one tab per terminal) rather than adding a tab.
  public var focusesExisting: Bool {
    switch self {
    case .newTab, .newSession, .browser: false
    case .inbox, .canvas, .chat, .terminal, .harness, .sideChat, .agentBrowser, .remoteBrowser:
      true
    }
  }

  /// The sidebar row that shows this content, when there is one.
  public var destination: SidebarDestination? {
    switch self {
    case .chat(let id): .session(id)
    case .newSession: .newSession
    case .inbox: .inbox
    case .canvas: .canvas
    case .newTab, .terminal, .harness, .sideChat, .browser, .agentBrowser, .remoteBrowser: nil
    }
  }

  /// The content a sidebar row opens.
  /// - Parameter destination: The row.
  public init(_ destination: SidebarDestination) {
    switch destination {
    case .session(let id): self = .chat(sessionID: id)
    case .newSession: self = .newSession
    case .inbox: self = .inbox
    case .canvas: self = .canvas
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
