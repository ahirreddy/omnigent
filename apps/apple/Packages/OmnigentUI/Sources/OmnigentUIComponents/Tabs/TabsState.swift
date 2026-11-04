public import Foundation
public import SwiftUI

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

  /// Work is in progress: a turn runs, a page loads or a terminal prints. A tab whose work
  /// settles while it is out of view becomes unread.
  public var isBusy: Bool {
    switch self {
    case .running, .loading, .terminalActivity: true
    case .none, .needsYou, .failed, .unread, .exited: false
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
  /// Whether the tab can be closed, torn off or replaced. A session's primary chat cannot: it
  /// leaves only with its session.
  public var isClosable = true
  /// The tabs that belong together (a session's); the group's leader stays first among them.
  public var groupID: String?
  /// The tab leads its group (a session's primary chat).
  public var leadsGroup = false
  /// The pane showing the tab while the window is split; `nil` when it is not.
  public var pane: TabPane?
  /// A session's primary chat the viewer may rename: its menu offers Rename Session.
  public var canRenameSession = false

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
  /// The two panes, when the window is split; ``selectedID`` is the focused pane's tab.
  public var split: TabSplitState?

  /// Creates the state.
  /// - Parameters:
  ///   - tabs: Tabs in order.
  ///   - selectedID: Selected tab.
  ///   - recentlyClosed: Closed tabs, most recent first.
  ///   - issue: A save or restore problem.
  ///   - split: The panes, when split.
  public init(
    tabs: [TabItemState] = [], selectedID: String? = nil,
    recentlyClosed: [TabItemState] = [], issue: String? = nil, split: TabSplitState? = nil
  ) {
    self.tabs = tabs
    self.selectedID = selectedID
    self.recentlyClosed = recentlyClosed
    self.issue = issue
    self.split = split
  }

  /// Pinned tabs, in order.
  public var pinned: [TabItemState] { tabs.filter(\.isPinned) }
  /// Unpinned tabs, in order.
  public var unpinned: [TabItemState] { tabs.filter { !$0.isPinned } }
  /// The selected tab.
  public var selected: TabItemState? { tabs.first { $0.id == selectedID } }
  /// Tabs whose work is in progress (``TabStatus/isBusy``).
  public var busyIDs: Set<String> { Set(tabs.filter(\.status.isBusy).map(\.id)) }

  /// The tabs of one pane, in order; every tab when the window is not split.
  /// - Parameter pane: The pane.
  /// - Returns: Its tabs.
  public func tabs(in pane: TabPane) -> [TabItemState] {
    guard split != nil else { return tabs }
    return tabs.filter { ($0.pane ?? .leading) == pane }
  }
}

/// One of a split window's two panes.
nonisolated public enum TabPane: String, Hashable, Sendable, Codable, CaseIterable {
  /// The left pane (the window's only pane when it is not split).
  case leading
  /// The right pane.
  case trailing

  /// The other pane.
  public var other: Self { self == .leading ? .trailing : .leading }

  /// "Left" or "Right", for menus and accessibility.
  public var label: String { self == .leading ? "Left" : "Right" }
}

/// A split window: each pane's tab, which pane has focus, and the left pane's share of the width.
nonisolated public struct TabSplitState: Hashable, Sendable {
  /// The narrowest a pane may get; narrower windows show only the focused pane.
  public static let minimumPaneWidth: CGFloat = 320
  /// The left pane's share is kept within this range.
  public static let fractionRange: ClosedRange<Double> = 0.2...0.8

  /// The tab the left pane shows.
  public var leadingID: String?
  /// The tab the right pane shows.
  public var trailingID: String?
  /// The pane with keyboard focus; the menus act on its tab.
  public var focused: TabPane
  /// The left pane's share of the width.
  public var fraction: Double

  /// Creates the state.
  /// - Parameters:
  ///   - leadingID: The left pane's tab.
  ///   - trailingID: The right pane's tab.
  ///   - focused: The focused pane.
  ///   - fraction: The left pane's share.
  public init(
    leadingID: String?, trailingID: String?, focused: TabPane = .leading, fraction: Double = 0.5
  ) {
    self.leadingID = leadingID
    self.trailingID = trailingID
    self.focused = focused
    self.fraction = Self.clamp(fraction)
  }

  /// The tab a pane shows.
  /// - Parameter pane: The pane.
  /// - Returns: Its tab id.
  public func activeID(_ pane: TabPane) -> String? {
    pane == .leading ? leadingID : trailingID
  }

  /// A share kept within ``fractionRange``.
  /// - Parameter fraction: The requested share.
  /// - Returns: The share to use.
  public static func clamp(_ fraction: Double) -> Double {
    guard fraction.isFinite else { return 0.5 }
    return min(fractionRange.upperBound, max(fractionRange.lowerBound, fraction))
  }

  /// Whether `width` points fit both panes at their minimum.
  /// - Parameter width: The content width.
  /// - Returns: `true` when both panes fit.
  public static func fits(width: CGFloat) -> Bool {
    width >= minimumPaneWidth * 2 + TabSplitMetrics.divider
  }
}

/// Split view sizes.
nonisolated enum TabSplitMetrics {
  /// The divider's visible width.
  static let divider: CGFloat = 1
  /// The divider's draggable width: a 44 pt target on touch.
  #if os(macOS)
    static let handle: CGFloat = 9
  #else
    static let handle: CGFloat = 44
  #endif
}

extension EnvironmentValues {
  /// The view is in the focused pane of a split window (or the only pane), so it publishes its
  /// menu commands. The other pane's views stay quiet.
  @Entry public var isActiveTabPane = true
  /// The tab offers its session's terminal view (the Chat/Terminal mode and Option-Command-\\):
  /// only a session's primary chat does.
  @Entry public var offersTerminalView = true
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
  /// Show a tab in a pane, splitting the window when it is not; `nil` where the window cannot
  /// split (compact widths).
  public var showInPane: (@MainActor (String, TabPane) -> Void)?
  /// Focus a pane of a split window.
  public var focusPane: (@MainActor (TabPane) -> Void)?
  /// Set the left pane's share of the width.
  public var setSplitFraction: (@MainActor (Double) -> Void)?
  /// Go back to one pane.
  public var closeSplit: (@MainActor () -> Void)?
  /// Open a remote browser tab in a profile (the + button's menu); `nil` hides it.
  public var newRemoteBrowser: (@MainActor (String) -> Void)?
  /// The remote browser profiles the + button's menu offers.
  public var remoteBrowserProfiles: [String] = []
  /// Rename the session of a chat tab (``TabItemState/canRenameSession``); `nil` hides it.
  public var renameSession: (@MainActor (String) -> Void)?

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
