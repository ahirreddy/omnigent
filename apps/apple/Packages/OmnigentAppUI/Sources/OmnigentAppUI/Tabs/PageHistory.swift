public import OmnigentUIComponents

/// A window's Back and Forward over the pages it showed (the web's browser history across its
/// routes): showing a page records the one it leaves and drops what was ahead; Back and Forward
/// step through them without recording.
public struct PageHistory: Hashable, Sendable {
  /// The most pages kept behind or ahead of the shown one.
  public static let limit = 50

  /// The pages behind the shown one, the oldest first.
  public private(set) var back: [SidebarDestination] = []
  /// The pages ahead of the shown one, the nearest last.
  public private(set) var forward: [SidebarDestination] = []

  /// An empty history.
  public init() {}

  /// Back has a page to go to.
  public var canGoBack: Bool { !back.isEmpty }
  /// Forward has a page to go to.
  public var canGoForward: Bool { !forward.isEmpty }

  /// Records `left` as the page before a newly shown one; what was ahead is gone.
  /// - Parameter left: The page the window leaves.
  public mutating func leave(_ left: SidebarDestination) {
    if back.last != left { back.append(left) }
    if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
    forward.removeAll()
  }

  /// Steps back from `current`, which goes ahead.
  /// - Parameter current: The shown page, if any.
  /// - Returns: The page to show; `nil` when there is none.
  public mutating func goBack(from current: SidebarDestination?) -> SidebarDestination? {
    guard let target = back.popLast() else { return nil }
    if let current { forward.append(current) }
    return target
  }

  /// Steps forward from `current`, which goes behind.
  /// - Parameter current: The shown page, if any.
  /// - Returns: The page to show; `nil` when there is none.
  public mutating func goForward(from current: SidebarDestination?) -> SidebarDestination? {
    guard let target = forward.popLast() else { return nil }
    if let current { back.append(current) }
    return target
  }

  /// Forgets pages of sessions that left (archived or deleted), and the repeats that leaves
  /// side by side.
  /// - Parameter sessionIDs: The sessions.
  public mutating func remove(sessions sessionIDs: Set<String>) {
    let gone = { (page: SidebarDestination) in
      page.sessionID.map(sessionIDs.contains) ?? false
    }
    back = Self.collapsed(back.filter { !gone($0) })
    forward = Self.collapsed(forward.filter { !gone($0) })
  }

  private static func collapsed(_ pages: [SidebarDestination]) -> [SidebarDestination] {
    pages.reduce(into: []) { kept, page in
      if kept.last != page { kept.append(page) }
    }
  }
}
