public import Foundation
public import Observation
public import OmnigentUIComponents

/// One window's tabs, like a browser's: open or focus, close and reopen, pin, duplicate,
/// reorder, select by position or cycle, tear off into another window, and split into two panes.
///
/// Tabs are per window and span sessions. A session's primary chat (``AppTabContent/chat``)
/// cannot be closed, torn off, replaced or duplicated: it leaves the window only with its
/// session (``removeSessions(_:)``, when the session is archived or deleted) or with the window.
/// It is selected and moved like any other tab, but it stays first among its session's tabs in
/// the same pane and pin group, and moving it carries them along.
///
/// Pinned tabs always come first. In a split window each pane has its own tabs (the left pane's
/// first in ``tabs``) and its own selected tab; ``selectedID`` is the focused pane's. A tab's
/// content is built the first time it is shown (``materialized``), so a restored window costs
/// nothing until its tabs are shown. Every change calls ``onChange`` so the window can save.
@Observable
public final class TabStore {
  /// Where a new tab goes.
  public enum Placement: Sendable {
    /// Right after the selected tab (after the pinned tabs when a pinned tab is selected).
    case afterSelected
    /// At the end of the strip (of the focused pane, when split).
    case end
  }

  /// How many closed tabs Reopen Closed Tab remembers.
  public static let closedLimit = 25

  /// Tabs in strip order: per pane (left first), pinned first.
  public internal(set) var tabs: [AppTab]
  /// The selected tab: the focused pane's, when split.
  public internal(set) var selectedID: String? {
    didSet { if let selectedID, selectedID != oldValue { noteShown(selectedID) } }
  }
  /// Tabs in the order they were last selected, the most recent first.
  @ObservationIgnored public internal(set) var recentIDs: [String] = []
  /// Closed tabs, oldest first.
  public internal(set) var closed: [AppTab]
  /// Tabs whose content has been built: shown at least once since launch or restore.
  public internal(set) var materialized: Set<String> = []
  /// The split view, when the window has two panes.
  public internal(set) var split: Split?
  /// Tabs whose work settled while they were out of view, as Warp's unread dot; showing a tab
  /// clears it. Not saved: a restored window starts read.
  public private(set) var unread: Set<String> = []
  /// A shell tab whose close waits for "Close shell?": closing it ends the shell.
  public var closingShell: String?
  /// Sessions whose chat has shown in this window, so the default transcript view applies once.
  @ObservationIgnored var transcriptDefaultApplied: Set<String> = []
  /// The tabs that were busy at the last ``noteBusy(_:)``.
  @ObservationIgnored private var busy: Set<String> = []

  /// A split window: which tabs are in the right pane, the other pane's tab and the divider.
  public struct Split: Hashable, Sendable {
    /// The right pane's tabs; every other tab is in the left pane.
    public var trailing: Set<String>
    /// The focused pane, whose tab is ``TabStore/selectedID``.
    public var focused: TabPane
    /// The tab the other pane shows.
    public var otherSelectedID: String?
    /// The left pane's share of the width.
    public var fraction: Double
  }

  /// Called after every change to the tabs, the selection, the split or the closed stack.
  @ObservationIgnored public var onChange: (@MainActor () -> Void)?
  /// Called with each tab that leaves the window (closed or replaced, not torn off), so its live
  /// content (a browser page) can be released. Returns the tab to remember for Reopen Closed
  /// Tab, for example with the page's final restore state.
  @ObservationIgnored public var willClose: (@MainActor (AppTab) -> AppTab)?

  /// Creates a store.
  /// - Parameter snapshot: Restored tabs; nothing is built until selected.
  public init(_ snapshot: TabWindowSnapshot = TabWindowSnapshot()) {
    tabs = []
    closed = []
    load(snapshot)
  }

  /// The selected tab.
  public var selected: AppTab? { tabs.first { $0.id == selectedID } }

  /// The tabs on screen: the selected one and, when split, the other pane's.
  public var visibleIDs: Set<String> {
    Set([selectedID, split?.otherSelectedID].compactMap(\.self))
  }

  /// The window's state to save.
  public var snapshot: TabWindowSnapshot {
    TabWindowSnapshot(
      tabs: tabs, selectedID: selectedID, closed: closed,
      split: split.map {
        TabSplitSnapshot(
          trailingIDs: tabs.map(\.id).filter($0.trailing.contains), focused: $0.focused,
          otherSelectedID: $0.otherSelectedID, fraction: $0.fraction)
      })
  }

  /// The split view's state for the strip and the panes.
  public var splitState: TabSplitState? {
    guard let split else { return nil }
    let leading = split.focused == .leading ? selectedID : split.otherSelectedID
    let trailing = split.focused == .trailing ? selectedID : split.otherSelectedID
    return TabSplitState(
      leadingID: leading, trailingID: trailing, focused: split.focused, fraction: split.fraction)
  }

  /// Sessions that a built tab needs open (their conversation, terminals and workspace).
  public var liveSessionIDs: Set<String> {
    Set(tabs.filter { materialized.contains($0.id) }.flatMap(\.content.openSessionIDs))
  }

  /// The tab with `id`.
  /// - Parameter id: Tab id.
  /// - Returns: The tab.
  public func tab(_ id: String) -> AppTab? {
    tabs.first { $0.id == id }
  }

  /// Whether a tab can be closed, torn off or replaced: every tab but a session's primary chat.
  /// - Parameter id: The tab.
  /// - Returns: `false` for a primary chat or a tab that is not open.
  public func canClose(_ id: String) -> Bool {
    guard let tab = tab(id) else { return false }
    return !tab.content.isPrimaryChat
  }

  /// The pane showing a tab, when the window is split.
  /// - Parameter id: The tab.
  /// - Returns: Its pane, or `nil` when the window is not split.
  public func pane(of id: String) -> TabPane? {
    guard let split else { return nil }
    return split.trailing.contains(id) ? .trailing : .leading
  }

  /// Replaces every tab with a restored window, for example once the window learns its server.
  /// - Parameter snapshot: The restored tabs.
  public func restore(_ snapshot: TabWindowSnapshot) {
    let previous = tabs
    load(snapshot)
    for tab in previous where !tabs.contains(where: { $0.id == tab.id }) { _ = retire(tab) }
    changed()
  }

  private func load(_ snapshot: TabWindowSnapshot) {
    var seen = Set<String>()
    let unique = snapshot.tabs.filter { seen.insert($0.id).inserted }
    // A primary chat is never reopened: it leaves only with its session.
    closed = Array(snapshot.closed.filter { !$0.content.isPrimaryChat }.suffix(Self.closedLimit))
    split = nil
    tabs = unique
    if let saved = snapshot.split {
      let trailing = Set(saved.trailingIDs).intersection(seen)
      // A split whose pane lost every tab (it did not decode) restores as one pane.
      if !trailing.isEmpty, trailing.count < unique.count {
        split = Split(
          trailing: trailing, focused: saved.focused, otherSelectedID: saved.otherSelectedID,
          fraction: TabSplitState.clamp(saved.fraction))
      }
    }
    tabs = arranged(unique)
    selectedID = seen.contains(snapshot.selectedID ?? "") ? snapshot.selectedID : nil
    materialized = []
    if let split {
      // The selection must be in the focused pane and the other tab in the other one.
      if selectedID.flatMap(pane(of:)) != split.focused {
        selectedID = firstID(in: split.focused)
      }
      if let other = split.otherSelectedID, pane(of: other) == split.focused.other {
        self.split?.otherSelectedID = other
      } else {
        self.split?.otherSelectedID = firstID(in: split.focused.other)
      }
      if let other = self.split?.otherSelectedID { materialized.insert(other) }
    }
    if selectedID == nil { selectedID = tabs.first?.id }
    if let selectedID { materialized.insert(selectedID) }
  }

  // MARK: Opening

  /// Opens `content`, or focuses the tab already showing it when the content is one per
  /// window (a session's chat, a terminal). A new tab opens in the focused pane.
  /// - Parameters:
  ///   - content: What to show.
  ///   - placement: Where a new tab goes.
  ///   - select: Select it (otherwise it opens in the background).
  ///   - title: A title to show before the content is built.
  ///   - browserState: Browser restore state.
  /// - Returns: The tab.
  @discardableResult
  public func open(
    _ content: AppTabContent, placement: Placement = .afterSelected, select: Bool = true,
    title: String? = nil, browserState: Data? = nil
  ) -> AppTab {
    if content.focusesExisting, let existing = tabs.first(where: { $0.content == content }) {
      if select { self.select(existing.id) }
      return existing
    }
    let tab = AppTab(content: content, title: title, browserState: browserState)
    insert(tab, placement: placement)
    if select {
      self.select(tab.id)
    } else {
      changed()
    }
    return tab
  }

  /// Shows `content` in the selected tab when it is the new-tab page or `replaceable` allows its
  /// kind, focuses an existing tab for one-per-window content, and otherwise opens a tab. A
  /// primary chat is never replaced, so another session's chat opens beside it.
  /// - Parameters:
  ///   - content: What to show.
  ///   - replaceable: Whether the selected tab's content may be replaced.
  /// - Returns: The tab.
  @discardableResult
  public func navigate(
    to content: AppTabContent, replacing replaceable: (AppTabContent) -> Bool = { _ in false }
  ) -> AppTab {
    if let current = selected, current.content == .newTab || replaceable(current.content) {
      return replace(current.id, with: content) ?? open(content)
    }
    return open(content)
  }

  /// Changes what a tab shows, keeping its place and pinning. A one-per-window content that is
  /// already open elsewhere is focused instead, and this tab closes when it was a new-tab page.
  /// A primary chat keeps its content: `content` opens in a tab of its own instead.
  /// - Parameters:
  ///   - id: The tab.
  ///   - content: The new content.
  ///   - title: A title to show until the content is built.
  ///   - browserState: Browser restore state.
  /// - Returns: The tab now showing `content`, or `nil` when `id` is not open.
  @discardableResult
  public func replace(
    _ id: String, with content: AppTabContent, title: String? = nil, browserState: Data? = nil
  ) -> AppTab? {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
    if tabs[index].content.isPrimaryChat, tabs[index].content != content {
      return open(content, title: title, browserState: browserState)
    }
    if content.focusesExisting,
      let existing = tabs.first(where: { $0.content == content && $0.id != id })
    {
      if tabs[index].content == .newTab { remove(at: index, remember: false) }
      select(existing.id)
      return existing
    }
    let old = tabs[index]
    tabs[index].content = content
    tabs[index].title = title
    tabs[index].browserState = browserState
    if old.content != content { _ = retire(old) }
    materialized.insert(id)
    tabs = arranged(tabs)
    changed()
    return tab(id)
  }

  /// Updates a tab's cached title or browser state (for the strip and the next restore).
  /// - Parameters:
  ///   - id: The tab.
  ///   - title: The current title.
  ///   - browserState: The current browser restore state; `nil` leaves it.
  public func record(_ id: String, title: String?, browserState: Data? = nil) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    var tab = tabs[index]
    tab.title = title
    if let browserState { tab.browserState = browserState }
    guard tab != tabs[index] else { return }
    tabs[index] = tab
    changed()
  }

  /// A tab's live content changed in a way worth saving (a page navigated).
  public func contentChanged() {
    changed()
  }

  /// Records which tabs are busy (a turn running, a page loading, a terminal printing). A tab
  /// out of view whose work stopped since the last call becomes unread.
  /// - Parameter current: The busy tabs now.
  public func noteBusy(_ current: Set<String>) {
    let settled = busy.subtracting(current).subtracting(visibleIDs)
    busy = current
    let open = Set(tabs.map(\.id))
    let newlyUnread = settled.intersection(open).subtracting(unread)
    if !newlyUnread.isEmpty { unread.formUnion(newlyUnread) }
  }

  /// Adds tabs that came from another window (a tear-off) and selects the first.
  /// - Parameter moved: The tabs, in order.
  public func adopt(_ moved: [AppTab]) {
    for tab in moved where !tabs.contains(where: { $0.id == tab.id }) {
      insert(tab, placement: .end)
    }
    if let first = moved.first { select(first.id) } else { changed() }
  }

  // MARK: Selecting

  /// Selects a tab, focusing its pane in a split window, and builds its content.
  /// - Parameter id: The tab.
  public func select(_ id: String) {
    guard tabs.contains(where: { $0.id == id }) else { return }
    materialized.insert(id)
    if let split, let pane = pane(of: id), pane != split.focused {
      self.split?.otherSelectedID = selectedID
      self.split?.focused = pane
      selectedID = id
      changed()
      return
    }
    guard selectedID != id else { return }
    selectedID = id
    changed()
  }

  /// Selects by position, 0-based; 8 or more selects the last tab (Command-9).
  /// - Parameter position: The position.
  public func select(position: Int) {
    guard !tabs.isEmpty else { return }
    let index = position >= 8 ? tabs.count - 1 : position
    guard tabs.indices.contains(index) else { return }
    select(tabs[index].id)
  }

  /// Selects the next tab, wrapping around.
  public func selectNext() { cycle(by: 1) }

  /// Selects the previous tab, wrapping around.
  public func selectPrevious() { cycle(by: -1) }

  private func cycle(by step: Int) {
    guard !tabs.isEmpty else { return }
    let current = tabs.firstIndex { $0.id == selectedID } ?? 0
    let next = (current + step + tabs.count) % tabs.count
    select(tabs[next].id)
  }

  // MARK: Internals

  func insert(_ tab: AppTab, placement: Placement) {
    if split?.focused == .trailing { split?.trailing.insert(tab.id) }
    let bounds = segment(of: tab, in: tabs)
    var index: Int
    switch placement {
    case .end:
      index = bounds.upperBound
    case .afterSelected:
      index = (tabs.firstIndex { $0.id == selectedID }).map { $0 + 1 } ?? bounds.upperBound
    }
    tabs.insert(tab, at: min(max(index, bounds.lowerBound), bounds.upperBound))
    tabs = arranged(tabs)
  }

  func remove(
    at index: Int, remember: Bool, retiring: Bool = true, notify: Bool = true
  ) {
    var tab = tabs.remove(at: index)
    if retiring { tab = retire(tab) }
    materialized.remove(tab.id)
    if let split {
      leaveSplit(tab.id, at: index, split: split)
    } else if selectedID == tab.id {
      selectedID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
      if let selectedID { materialized.insert(selectedID) }
    }
    if remember {
      closed.append(tab)
      if closed.count > Self.closedLimit { closed.removeFirst() }
    }
    if notify { changed() }
  }

  func retire(_ tab: AppTab) -> AppTab {
    willClose?(tab) ?? tab
  }

  func changed() {
    // Showing a tab reads it; a closed one has nothing left to read.
    let read = unread.subtracting(visibleIDs).intersection(Set(tabs.map(\.id)))
    if read != unread { unread = read }
    onChange?()
  }
}
