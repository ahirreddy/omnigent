public import Foundation
import OmnigentUIComponents

// Closing, reopening and arranging tabs.
extension TabStore {
  // MARK: Closing

  /// Closes a tab, remembering it for Reopen Closed Tab. The tab to its right is selected, or
  /// the one to its left when it was last. A primary chat stays open.
  /// - Parameter id: The tab.
  public func close(_ id: String) {
    guard canClose(id), let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    remove(at: index, remember: tabs[index].content != .newTab)
  }

  /// Closes every unpinned tab except `id` and the primary chats.
  /// - Parameter id: The tab to keep.
  public func closeOthers(_ id: String) {
    for tab in tabs where tab.id != id && !tab.isPinned { close(tab.id) }
    select(id)
  }

  /// Closes the unpinned tabs to the right of `id`, except the primary chats.
  /// - Parameter id: The tab.
  public func closeToRight(_ id: String) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    for tab in tabs[(index + 1)...] where !tab.isPinned { close(tab.id) }
  }

  /// Closes every closable tab whose content matches, for example a deleted terminal.
  /// - Parameter matches: Which contents to close.
  public func closeAll(where matches: (AppTabContent) -> Bool) {
    for tab in tabs where matches(tab.content) { close(tab.id) }
  }

  /// Removes the sessions' tabs, their primary chats among them, without remembering them:
  /// the sessions were archived or deleted.
  /// - Parameter sessionIDs: The sessions.
  public func removeSessions(_ sessionIDs: Set<String>) {
    let before = closed.count
    closed.removeAll { $0.content.sessionID.map(sessionIDs.contains) ?? false }
    var removed = closed.count != before
    while let index = tabs.firstIndex(where: {
      $0.content.sessionID.map(sessionIDs.contains) ?? false
    }) {
      remove(at: index, remember: false, notify: false)
      removed = true
    }
    if removed { changed() }
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

  /// Removes a tab without remembering it, for a tear-off; the other window adopts it. A
  /// primary chat cannot leave.
  /// - Parameter id: The tab.
  /// - Returns: The tab, or `nil` when it is not open or cannot leave.
  public func detach(_ id: String) -> AppTab? {
    guard canClose(id), let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
    let tab = tabs[index]
    remove(at: index, remember: false, retiring: false)
    return tab
  }

  // MARK: Arranging

  /// Pins or unpins a tab. Pinning moves it to the end of its pane's pinned tabs; unpinning to
  /// the start of the others.
  /// - Parameters:
  ///   - id: The tab.
  ///   - pinned: Pinned.
  public func setPinned(_ id: String, _ pinned: Bool) {
    guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].isPinned != pinned
    else { return }
    var tab = tabs.remove(at: index)
    tab.isPinned = pinned
    let bounds = segment(of: tab, in: tabs)
    tabs.insert(tab, at: pinned ? bounds.upperBound : bounds.lowerBound)
    tabs = arranged(tabs)
    changed()
  }

  /// Moves a tab to `index` in the strip (its final position), kept within its pane and pin
  /// group. A primary chat brings its session's tabs in that group along; a session's other
  /// tabs never pass its primary chat.
  /// - Parameters:
  ///   - id: The tab.
  ///   - index: The final position.
  public func move(_ id: String, to index: Int) {
    guard let tab = tab(id) else { return }
    let before = tabs.map(\.id)
    var block = [tab]
    if tab.content.isPrimaryChat, let session = tab.content.sessionID {
      block += tabs.filter {
        $0.id != id && $0.content.sessionID == session && rank($0) == rank(tab)
      }
    }
    let ids = Set(block.map(\.id))
    var remaining = tabs.filter { !ids.contains($0.id) }
    let bounds = segment(of: tab, in: remaining)
    let target = min(max(index, bounds.lowerBound), bounds.upperBound)
    remaining.insert(contentsOf: block, at: target)
    tabs = arranged(remaining)
    if tabs.map(\.id) != before { changed() }
  }

  /// Opens a copy of a tab right after it. A primary chat has no copy.
  /// - Parameters:
  ///   - id: The tab.
  ///   - browser: For a browser tab, the new page's id and state from the browser host.
  /// - Returns: The copy.
  @discardableResult
  public func duplicate(_ id: String, browser: (id: UUID, state: Data?)? = nil) -> AppTab? {
    guard canClose(id), let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
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
    if pane(of: id) == .trailing { split?.trailing.insert(copy.id) }
    tabs = arranged(tabs)
    select(copy.id)
    return copy
  }
}
