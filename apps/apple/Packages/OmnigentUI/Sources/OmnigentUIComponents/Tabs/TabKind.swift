import Foundation

/// What a tab shows. Picks its icon and its accessibility label.
nonisolated public enum TabKind: String, Hashable, Sendable, CaseIterable {
  /// The new-tab page (New session, Terminal, Browser).
  case newTab
  /// A session's conversation.
  case chat
  /// A user shell of a session.
  case terminal
  /// The session harness's own TUI (Claude Code, Codex and other native harnesses).
  case agentTerminal
  /// A side question and its answer, from the transcript.
  case sideChat
  /// A web page.
  case browser
  /// The page an agent is driving, read-only.
  case agentBrowser
  /// A browser running on the agent's machine, streamed as video.
  case remoteBrowser
  /// The new-session form.
  case newSession
  /// The Inbox.
  case inbox
  /// The Canvas.
  case canvas
  /// Automations.
  case automations
  /// Usage.
  case usage

  /// The SF Symbol.
  public var systemImage: String {
    switch self {
    case .newTab: "plus.square.on.square"
    case .chat: "bubble.left.and.text.bubble.right"
    case .terminal: "terminal"
    case .agentTerminal: "sparkles.rectangle.stack"
    case .sideChat: "bubble.left.and.bubble.right"
    case .browser: "globe"
    case .agentBrowser: "globe.badge.chevron.backward"
    case .remoteBrowser: "network"
    case .newSession: "square.and.pencil"
    case .inbox: "tray"
    case .canvas: "square.grid.2x2"
    case .automations: "clock"
    case .usage: "creditcard"
    }
  }

  /// A short noun for accessibility and the tab overview.
  public var label: String {
    switch self {
    case .newTab: "New tab"
    case .chat: "Chat"
    case .terminal: "Terminal"
    case .agentTerminal: "Agent terminal"
    case .sideChat: "Side chat"
    case .browser: "Browser"
    case .agentBrowser: "Agent browser"
    case .remoteBrowser: "Remote browser"
    case .newSession: "New session"
    case .inbox: "Inbox"
    case .canvas: "Canvas"
    case .automations: "Automations"
    case .usage: "Usage"
    }
  }
}
