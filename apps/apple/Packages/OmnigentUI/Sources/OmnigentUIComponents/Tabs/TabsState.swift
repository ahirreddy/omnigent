public import Foundation
public import SwiftUI

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
  /// The new-session form.
  case newSession
  /// The Inbox.
  case inbox
  /// The Canvas.
  case canvas

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
    case .newSession: "square.and.pencil"
    case .inbox: "tray"
    case .canvas: "square.grid.2x2"
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
    case .newSession: "New session"
    case .inbox: "Inbox"
    case .canvas: "Canvas"
    }
  }
}

/// The one status a tab shows next to its title, most urgent first.
nonisolated public enum TabStatus: Hashable, Sendable {
  /// Nothing to show.
  case none
  /// Pending decisions the user can answer.
  case needsYou
  /// The last turn failed, or the page could not load.
  case failed
  /// A turn is running.
  case running
  /// A page is loading.
  case loading
  /// A terminal is producing output.
  case terminalActivity
  /// Activity the user has not seen.
  case unread
  /// The terminal's program exited.
  case exited

  /// A short label for tooltips and accessibility; `nil` for ``none``.
  public var label: String? {
    switch self {
    case .none: nil
    case .needsYou: "Needs you"
    case .failed: "Failed"
    case .running: "Running"
    case .loading: "Loading"
    case .terminalActivity: "Active"
    case .unread: "Unread"
    case .exited: "Exited"
    }
  }
}

/// One tab in the strip.
nonisolated public struct TabItemState: Identifiable, Hashable, Sendable {
  /// Stable tab id.
  public var id: String
  /// What it shows.
  public var kind: TabKind
  /// The title (session title, terminal name, page title).
  public var title: String
  /// Context under the title in the overview, for example the owning session.
  public var subtitle: String?
  /// Its status.
  public var status: TabStatus
  /// Pinned tabs are icon-only, on the left.
  public var isPinned: Bool
  /// A page is playing audio.
  public var isPlayingAudio: Bool
  /// The content cannot be edited here (an agent's browser, a read-only terminal).
  public var isReadOnly: Bool
  /// Whether Duplicate is offered.
  public var canDuplicate: Bool
  /// What Copy Link copies; `nil` hides it.
  public var link: URL?
  /// A page's favicon (PNG), shown instead of the kind's icon.
  public var favicon: Data?
  /// A browser profile's color, shown as a dot on the icon.
  public var profileColor: Color?
  /// The session's status line for the tooltip, for example `Waiting for you · 2 requests`
  /// (``SessionStatusLine``); `nil` uses the status's own label.
  public var statusDetail: String?

  /// Creates a tab.
  /// - Parameters:
  ///   - id: Tab id.
  ///   - kind: What it shows.
  ///   - title: Title.
  ///   - subtitle: Context line.
  ///   - status: Status.
  ///   - isPinned: Pinned.
  ///   - isPlayingAudio: Playing audio.
  ///   - isReadOnly: Read only.
  ///   - canDuplicate: Offers Duplicate.
  ///   - link: Copy Link target.
  public init(
    id: String, kind: TabKind, title: String, subtitle: String? = nil, status: TabStatus = .none,
    isPinned: Bool = false, isPlayingAudio: Bool = false, isReadOnly: Bool = false,
    canDuplicate: Bool = true, link: URL? = nil
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.subtitle = subtitle
    self.status = status
    self.isPinned = isPinned
    self.isPlayingAudio = isPlayingAudio
    self.isReadOnly = isReadOnly
    self.canDuplicate = canDuplicate
    self.link = link
  }

  /// The title, or the kind's noun when the title is empty.
  public var displayTitle: String { title.isEmpty ? kind.label : title }
}

extension EnvironmentValues {
  /// The window's tab strip sits in the titlebar row (Mac, iPad at regular width), so a screen
  /// leaves its title, status and view-mode controls to the tab and keeps only a compact
  /// trailing cluster in the toolbar.
  @Entry public var tabsInTitlebar = false
}

/// A window's tabs.
nonisolated public struct TabsState: Hashable, Sendable {
  /// Every tab, pinned first, in strip order.
  public var tabs: [TabItemState]
  /// The selected tab.
  public var selectedID: String?
  /// Recently closed tabs, most recent first, for Reopen Closed Tab and the overview.
  public var recentlyClosed: [TabItemState]
  /// Why the tabs could not be saved or restored, shown in the strip.
  public var issue: String?

  /// Creates the state.
  /// - Parameters:
  ///   - tabs: Tabs in order.
  ///   - selectedID: Selected tab.
  ///   - recentlyClosed: Closed tabs, most recent first.
  ///   - issue: A save or restore problem.
  public init(
    tabs: [TabItemState] = [], selectedID: String? = nil,
    recentlyClosed: [TabItemState] = [], issue: String? = nil
  ) {
    self.tabs = tabs
    self.selectedID = selectedID
    self.recentlyClosed = recentlyClosed
    self.issue = issue
  }

  /// Pinned tabs, in order.
  public var pinned: [TabItemState] { tabs.filter(\.isPinned) }
  /// Unpinned tabs, in order.
  public var unpinned: [TabItemState] { tabs.filter { !$0.isPinned } }
  /// The selected tab.
  public var selected: TabItemState? { tabs.first { $0.id == selectedID } }
}

/// What the tab strip, the overview and the commands can do. The host owns the model; every
/// action names the tab by id.
public struct TabActions {
  /// Select a tab.
  public var select: @MainActor (String) -> Void
  /// Close a tab.
  public var close: @MainActor (String) -> Void
  /// Open a new tab (the new-tab page).
  public var newTab: @MainActor () -> Void
  /// Move a tab to an index in the whole strip; the host keeps pinned tabs first.
  public var move: @MainActor (String, Int) -> Void
  /// Pin or unpin a tab.
  public var setPinned: @MainActor (String, Bool) -> Void
  /// Duplicate a tab.
  public var duplicate: @MainActor (String) -> Void
  /// Close every other unpinned tab.
  public var closeOthers: @MainActor (String) -> Void
  /// Close the unpinned tabs to the right.
  public var closeToRight: @MainActor (String) -> Void
  /// Reopen the most recently closed tab; `nil` when none is closed.
  public var reopenClosed: (@MainActor () -> Void)?
  /// Tear a tab off into a new window; `nil` where the platform has no windows.
  public var moveToNewWindow: (@MainActor (String) -> Void)?

  /// Creates the actions.
  /// - Parameters:
  ///   - select: Select.
  ///   - close: Close.
  ///   - newTab: New tab.
  ///   - move: Reorder.
  ///   - setPinned: Pin or unpin.
  ///   - duplicate: Duplicate.
  ///   - closeOthers: Close others.
  ///   - closeToRight: Close to the right.
  ///   - reopenClosed: Reopen closed.
  ///   - moveToNewWindow: Tear off.
  public init(
    select: @escaping @MainActor (String) -> Void = { _ in },
    close: @escaping @MainActor (String) -> Void = { _ in },
    newTab: @escaping @MainActor () -> Void = {},
    move: @escaping @MainActor (String, Int) -> Void = { _, _ in },
    setPinned: @escaping @MainActor (String, Bool) -> Void = { _, _ in },
    duplicate: @escaping @MainActor (String) -> Void = { _ in },
    closeOthers: @escaping @MainActor (String) -> Void = { _ in },
    closeToRight: @escaping @MainActor (String) -> Void = { _ in },
    reopenClosed: (@MainActor () -> Void)? = nil,
    moveToNewWindow: (@MainActor (String) -> Void)? = nil
  ) {
    self.select = select
    self.close = close
    self.newTab = newTab
    self.move = move
    self.setPinned = setPinned
    self.duplicate = duplicate
    self.closeOthers = closeOthers
    self.closeToRight = closeToRight
    self.reopenClosed = reopenClosed
    self.moveToNewWindow = moveToNewWindow
  }
}
