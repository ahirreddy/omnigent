public import Foundation
public import Observation

/// One window's tabs, like a browser's: open or focus, close and reopen, pin, duplicate,
/// reorder, select by position or cycle, and tear off into another window.
///
/// Pinned tabs always come first. A tab's content is built the first time it is selected
/// (``materialized``), so a restored window costs nothing until its tabs are shown. Every change
/// calls ``onChange`` so the window can save.
@Observable
public final class TabStore {
  /// Where a new tab goes.
  public enum Placement: Sendable {
    /// Right after the selected tab (after the pinned tabs when a pinned tab is selected).
    case afterSelected
    /// At the end of the strip.
    case end
  }

  /// How many closed tabs Reopen Closed Tab remembers.
  public static let closedLimit = 25

  /// Tabs in strip order, pinned first.
  public private(set) var tabs: [AppTab]
  /// The selected tab.
  public private(set) var selectedID: String?
  /// Closed tabs, oldest first.
  public private(set) var closed: [AppTab]
  /// Tabs whose content has been built: selected at least once since launch or restore.
  public private(set) var materialized: Set<String> = []

  /// Called after every change to the tabs, the selection or the closed stack.
  @ObservationIgnored public var onChange: (@MainActor () -> Void)?
  /// Called with each tab that leaves the window (closed or replaced, not torn off), so its live
  /// content (a browser page) can be released. Returns the tab to remember for Reopen Closed
  /// Tab, for example with the page's final restore state.
  @ObservationIgnored public var willClose: (@MainActor (AppTab) -> AppTab)?

  /// Creates a store.
  /// - Parameter snapshot: Restored tabs; nothing is built until selected.
  public init(_ snapshot: TabWindowSnapshot = TabWindowSnapshot()) {
    tabs = Self.ordered(snapshot.tabs)
    closed = Array(snapshot.closed.suffix(Self.closedLimit))
    selectedID = snapshot.tabs.contains { $0.id == snapshot.selectedID } ? snapshot.selectedID : nil
    if selectedID == nil { selectedID = tabs.first?.id }
    if let selectedID { materialized.insert(selectedID) }
  }

  /// The selected tab.
  public var selected: AppTab? { tabs.first { $0.id == selectedID } }

  /// The window's state to save.
  public var snapshot: TabWindowSnapshot {
    TabWindowSnapshot(tabs: tabs, selectedID: selectedID, closed: closed)
  }

  /// Sessions that a built tab needs open (their conversation, terminals and workspace).
  public var liveSessionIDs: Set<String> {
    Set(tabs.filter { materialized.contains($0.id) }.compactMap(\.content.sessionID))
  }

  /// The tab with `id`.
  /// - Parameter id: Tab id.
  /// - Returns: The tab.
  public func tab(_ id: String) -> AppTab? {
    tabs.first { $0.id == id }
  }

  /// Replaces every tab with a restored window, for example once the window learns its server.
  /// - Parameter snapshot: The restored tabs.
  public func restore(_ snapshot: TabWindowSnapshot) {
    let previous = tabs
    tabs = Self.ordered(snapshot.tabs)
    closed = Array(snapshot.closed.suffix(Self.closedLimit))
    selectedID =
      tabs.contains { $0.id == snapshot.selectedID } ? snapshot.selectedID : tabs.first?.id
    materialized = selectedID.map { [$0] } ?? []
    for tab in previous where !tabs.contains(where: { $0.id == tab.id }) { _ = retire(tab) }
    changed()
  }

  // MARK: Opening

  /// Opens `content`, or focuses the tab already showing it when the content is one per
  /// window (a session's chat, a terminal).
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
  /// kind, focuses an existing tab for one-per-window content, and otherwise opens a tab.
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
    changed()
    return tabs[index]
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

  /// Adds tabs that came from another window (a tear-off) and selects the first.
  /// - Parameter moved: The tabs, in order.
  public func adopt(_ moved: [AppTab]) {
    for tab in moved where !tabs.contains(where: { $0.id == tab.id }) {
      insert(tab, placement: .end)
    }
    if let first = moved.first { select(first.id) } else { changed() }
  }

  // MARK: Selecting

  /// Selects a tab and builds its content.
  /// - Parameter id: The tab.
  public func select(_ id: String) {
    guard tabs.contains(where: { $0.id == id }) else { return }
    materialized.insert(id)
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

  // MARK: Closing

  /// Closes a tab, remembering it for Reopen Closed Tab. The tab to its right is selected, or
  /// the one to its left when it was last.
  /// - Parameter id: The tab.
  public func close(_ id: String) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    remove(at: index, remember: tabs[index].content != .newTab)
  }

  /// Closes every unpinned tab except `id`.
  /// - Parameter id: The tab to keep.
  public func closeOthers(_ id: String) {
    for tab in tabs where tab.id != id && !tab.isPinned { close(tab.id) }
    select(id)
  }

  /// Closes the unpinned tabs to the right of `id`.
  /// - Parameter id: The tab.
  public func closeToRight(_ id: String) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    for tab in tabs[(index + 1)...] where !tab.isPinned { close(tab.id) }
  }

  /// Closes every tab whose content matches, for example a deleted terminal.
  /// - Parameter matches: Which contents to close.
  public func closeAll(where matches: (AppTabContent) -> Bool) {
    for tab in tabs where matches(tab.content) { close(tab.id) }
  }

  /// Reopens the most recently closed tab where it was, selected.
  /// - Returns: The tab, or `nil` when nothing was closed.
  @discardableResult
  public func reopenClosed() -> AppTab? {
    guard let tab = closed.popLast() else { return nil }
    if tab.content.focusesExisting, let existing = tabs.first(where: { $0.content == tab.content })
    {
      select(existing.id)
      return existing
    }
    insert(tab, placement: .afterSelected)
    select(tab.id)
    return tab
  }

  /// Removes a tab without remembering it, for a tear-off; the other window adopts it.
  /// - Parameter id: The tab.
  /// - Returns: The tab, or `nil` when it is not open.
  public func detach(_ id: String) -> AppTab? {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
    let tab = tabs[index]
    remove(at: index, remember: false, retiring: false)
    return tab
  }

  // MARK: Arranging

  /// Pins or unpins a tab. Pinning moves it to the end of the pinned tabs; unpinning to the
  /// start of the others.
  /// - Parameters:
  ///   - id: The tab.
  ///   - pinned: Pinned.
  public func setPinned(_ id: String, _ pinned: Bool) {
    guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].isPinned != pinned
    else { return }
    var tab = tabs.remove(at: index)
    tab.isPinned = pinned
    let pinnedCount = tabs.count { $0.isPinned }
    tabs.insert(tab, at: pinnedCount)
    changed()
  }

  /// Moves a tab to `index` in the strip (its final position), kept within its group: pinned
  /// tabs stay before the others.
  /// - Parameters:
  ///   - id: The tab.
  ///   - index: The final position.
  public func move(_ id: String, to index: Int) {
    guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
    let tab = tabs.remove(at: from)
    let pinnedCount = tabs.count { $0.isPinned }
    let range = tab.isPinned ? 0...pinnedCount : pinnedCount...tabs.count
    let target = min(max(index, range.lowerBound), range.upperBound)
    tabs.insert(tab, at: target)
    if target != from { changed() }
  }

  /// Opens a copy of a tab right after it.
  /// - Parameters:
  ///   - id: The tab.
  ///   - browser: For a browser tab, the new page's id and state from the browser host.
  /// - Returns: The copy.
  @discardableResult
  public func duplicate(_ id: String, browser: (id: UUID, state: Data?)? = nil) -> AppTab? {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
    let original = tabs[index]
    var content = original.content
    var state = original.browserState
    if case .browser = content {
      guard let browser else { return nil }
      content = .browser(browserID: browser.id)
      state = browser.state
    }
    let copy = AppTab(
      content: content, isPinned: original.isPinned, title: original.title, browserState: state)
    tabs.insert(copy, at: index + 1)
    select(copy.id)
    return copy
  }

  // MARK: Internals

  private func insert(_ tab: AppTab, placement: Placement) {
    let pinnedCount = tabs.count { $0.isPinned }
    var index: Int
    switch placement {
    case .end:
      index = tabs.count
    case .afterSelected:
      index = (tabs.firstIndex { $0.id == selectedID }).map { $0 + 1 } ?? tabs.count
    }
    index = tab.isPinned ? min(index, pinnedCount) : max(index, pinnedCount)
    tabs.insert(tab, at: index)
  }

  private func remove(at index: Int, remember: Bool, retiring: Bool = true) {
    var tab = tabs.remove(at: index)
    if retiring { tab = retire(tab) }
    materialized.remove(tab.id)
    if selectedID == tab.id {
      selectedID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
      if let selectedID { materialized.insert(selectedID) }
    }
    if remember {
      closed.append(tab)
      if closed.count > Self.closedLimit { closed.removeFirst() }
    }
    changed()
  }

  private func retire(_ tab: AppTab) -> AppTab {
    willClose?(tab) ?? tab
  }

  private func changed() {
    onChange?()
  }

  private static func ordered(_ tabs: [AppTab]) -> [AppTab] {
    var seen = Set<String>()
    let unique = tabs.filter { seen.insert($0.id).inserted }
    return unique.filter(\.isPinned) + unique.filter { !$0.isPinned }
  }
}
