import Foundation
public import OmnigentUIComponents

// The split view, and the strip order that keeps panes, pinned tabs and sessions together.
extension TabStore {
  // MARK: Split view

  /// Shows a tab in a pane and focuses it, splitting the window when it is not. A pane's only
  /// tab trades places with the tab the other pane shows, so moving it never closes the split;
  /// a split with a single tab gets a new-tab page in the other pane.
  /// - Parameters:
  ///   - id: The tab.
  ///   - target: The pane.
  public func show(_ id: String, in target: TabPane) {
    guard tab(id) != nil else { return }
    if split == nil {
      let others = tabs.filter { $0.id != id }.map(\.id)
      let previous = selectedID == id ? nil : selectedID
      split = Split(
        trailing: target == .trailing ? [id] : Set(others), focused: target,
        otherSelectedID: previous ?? others.first, fraction: 0.5)
      if others.isEmpty {
        let blank = AppTab(content: .newTab)
        tabs.append(blank)
        if target == .leading { split?.trailing.insert(blank.id) }
        split?.otherSelectedID = blank.id
      }
      selectedID = id
      materialized.insert(id)
      if let other = split?.otherSelectedID { materialized.insert(other) }
      tabs = arranged(tabs)
      changed()
      return
    }
    guard let source = pane(of: id), source != target else {
      select(id)
      return
    }
    // Leave the source pane: it shows another of its tabs, or takes the tab the target showed.
    let sourceTabs = ids(in: source).filter { $0 != id }
    let sourceActive = activeID(source)
    let traded = sourceTabs.isEmpty ? activeID(target) : nil
    place(id, in: target)
    if let traded { place(traded, in: source) }
    let replacement =
      traded ?? (sourceActive == id ? neighbour(of: id, among: sourceTabs) : sourceActive)
    split?.focused = target
    split?.otherSelectedID = replacement
    selectedID = id
    materialized.insert(id)
    if let replacement { materialized.insert(replacement) }
    tabs = arranged(tabs)
    changed()
  }

  private func place(_ id: String, in pane: TabPane) {
    if pane == .trailing { split?.trailing.insert(id) } else { split?.trailing.remove(id) }
  }

  /// Splits the window, the selected tab staying on the left and the tab after it (else
  /// before it, else a new-tab page) on the right; or goes back to one pane.
  public func toggleSplit() {
    if split != nil {
      closeSplit()
      return
    }
    guard let selectedID else { return }
    let others = tabs.map(\.id).filter { $0 != selectedID }
    if let partner = neighbour(of: selectedID, among: others) {
      show(partner, in: .trailing)
      focus(.leading)
    } else {
      show(selectedID, in: .leading)
      focus(.trailing)
    }
  }

  /// Back to one pane, showing the focused pane's tab.
  public func closeSplit() {
    guard split != nil else { return }
    split = nil
    changed()
  }

  /// Focuses a pane of a split window.
  /// - Parameter pane: The pane.
  public func focus(_ pane: TabPane) {
    guard let split, split.focused != pane else { return }
    let other = split.otherSelectedID
    self.split?.otherSelectedID = selectedID
    self.split?.focused = pane
    selectedID = other
    changed()
  }

  /// Sets the left pane's share of the width.
  /// - Parameter fraction: The share, kept within ``TabSplitState/fractionRange``.
  public func setSplitFraction(_ fraction: Double) {
    let clamped = TabSplitState.clamp(fraction)
    guard let split, split.fraction != clamped else { return }
    self.split?.fraction = clamped
    changed()
  }

  // MARK: Order and panes

  func activeID(_ pane: TabPane) -> String? {
    split?.focused == pane ? selectedID : split?.otherSelectedID
  }

  func ids(in pane: TabPane) -> [String] {
    tabs.filter { self.pane(of: $0.id) == pane }.map(\.id)
  }

  func firstID(in pane: TabPane) -> String? {
    tabs.first { self.pane(of: $0.id) == pane }?.id
  }

  /// The tab after `id` in `candidates`' strip order, else the one before it.
  func neighbour(of id: String, among candidates: [String]) -> String? {
    let order = tabs.map(\.id)
    guard let position = order.firstIndex(of: id) else { return candidates.first }
    let wanted = Set(candidates)
    return order[(position + 1)...].first(where: wanted.contains)
      ?? order[..<position].last(where: wanted.contains)
  }

  /// The strip groups a tab sorts into: left pane then right, pinned first in each.
  func rank(_ tab: AppTab) -> Int {
    (pane(of: tab.id) == .trailing ? 2 : 0) + (tab.isPinned ? 0 : 1)
  }

  /// The indices of `tab`'s group in `others`, where it may be placed.
  func segment(of tab: AppTab, in others: [AppTab]) -> ClosedRange<Int> {
    let own = rank(tab)
    let lower = others.count { rank($0) < own }
    return lower...(lower + others.count { rank($0) == own })
  }

  /// `tabs` in strip order: grouped by pane and pinning, keeping their order, with each primary
  /// chat ahead of its session's other tabs in its group.
  func arranged(_ tabs: [AppTab]) -> [AppTab] {
    (0..<4).flatMap { group in Self.leadingChats(tabs.filter { rank($0) == group }) }
  }

  /// Moves a session's tabs that come before its primary chat to right after it.
  static func leadingChats(_ tabs: [AppTab]) -> [AppTab] {
    let chats = Set(tabs.filter(\.content.isPrimaryChat).compactMap(\.content.sessionID))
    var emitted = Set<String>()
    var waiting: [String: [AppTab]] = [:]
    var result: [AppTab] = []
    for tab in tabs {
      guard let session = tab.content.sessionID, chats.contains(session) else {
        result.append(tab)
        continue
      }
      if tab.content.isPrimaryChat {
        result.append(tab)
        result += waiting.removeValue(forKey: session) ?? []
        emitted.insert(session)
      } else if emitted.contains(session) {
        result.append(tab)
      } else {
        waiting[session, default: []].append(tab)
      }
    }
    return result
  }

  /// A tab left a split window: its pane shows its neighbour, or the split closes when the
  /// pane is empty.
  func leaveSplit(_ id: String, at index: Int, split: Split) {
    let pane: TabPane = split.trailing.contains(id) ? .trailing : .leading
    self.split?.trailing.remove(id)
    let remaining = ids(in: pane)
    guard !remaining.isEmpty else {
      self.split = nil
      if selectedID == id { selectedID = split.otherSelectedID ?? tabs.first?.id }
      if let selectedID { materialized.insert(selectedID) }
      return
    }
    let isActive = split.focused == pane ? selectedID == id : split.otherSelectedID == id
    guard isActive else { return }
    // The tab now at the closed one's place, if it is in the same pane, else the pane's last.
    let next =
      tabs.indices.contains(index) && remaining.contains(tabs[index].id)
      ? tabs[index].id : remaining.last
    if split.focused == pane { selectedID = next } else { self.split?.otherSelectedID = next }
    if let next { materialized.insert(next) }
  }
}

/// A window's saved split view. Versioned: a newer layout restores as one pane.
nonisolated public struct TabSplitSnapshot: Hashable, Sendable, Codable {
  /// The layout's format version.
  public static let version = 1

  /// The format this layout was written in.
  public var version: Int
  /// The right pane's tabs, in strip order; the others are in the left pane.
  public var trailingIDs: [String]
  /// The focused pane, whose tab is the window's selected tab.
  public var focused: TabPane
  /// The tab the other pane shows.
  public var otherSelectedID: String?
  /// The left pane's share of the width.
  public var fraction: Double

  /// Creates a layout.
  /// - Parameters:
  ///   - trailingIDs: The right pane's tabs.
  ///   - focused: The focused pane.
  ///   - otherSelectedID: The other pane's tab.
  ///   - fraction: The left pane's share.
  public init(
    trailingIDs: [String], focused: TabPane, otherSelectedID: String?, fraction: Double
  ) {
    version = Self.version
    self.trailingIDs = trailingIDs
    self.focused = focused
    self.otherSelectedID = otherSelectedID
    self.fraction = fraction
  }
}

extension AppTabContent {
  /// A session's primary chat: one per session in a window, closed only with its session. It
  /// is also the only tab that offers the session's terminal view.
  nonisolated public var isPrimaryChat: Bool {
    if case .chat = self { return true }
    return false
  }
}
