import Foundation

/// How one sidebar group (Pinned, or a project) orders its sessions.
nonisolated public enum SessionGroupSort: String, Hashable, Sendable, CaseIterable, Codable {
  /// Most recent activity first.
  case recent
  /// By title, A to Z.
  case name
  /// Most recently created first.
  case created
  /// The user's own order (a drag, or Move).
  case custom

  /// The menu title.
  public var title: String {
    switch self {
    case .recent: "Recent activity"
    case .name: "Name"
    case .created: "Date created"
    case .custom: "Custom"
    }
  }
}

/// A sidebar group whose sessions sort on their own.
nonisolated public enum SessionGroup: Hashable, Sendable {
  /// The Pinned section.
  case pinned
  /// A project folder, by its id.
  case project(String)

  /// The key its sort and custom order are saved under.
  public var key: String {
    switch self {
    case .pinned: "pinned"
    case .project(let id): "project:\(id)"
    }
  }
}

/// Each group's sort and each project's custom order, which the host keeps per server. Pinned's
/// custom order is the server's pin order, so none is kept for it here.
nonisolated public struct SessionGroupSorts: Hashable, Sendable, Codable {
  /// The chosen sort by group key; a group without one keeps its default.
  public var chosen: [String: SessionGroupSort]
  /// A project's custom order (session ids, top to bottom) by group key.
  public var customOrder: [String: [String]]

  /// Creates the sorts.
  /// - Parameters:
  ///   - chosen: The chosen sort by group key.
  ///   - customOrder: Each project's custom order by group key.
  public init(chosen: [String: SessionGroupSort] = [:], customOrder: [String: [String]] = [:]) {
    self.chosen = chosen
    self.customOrder = customOrder
  }

  /// The sort `group` shows: the chosen one, or its default. Pinned keeps the pin order (Custom),
  /// or the creation date where the list is ordered by it; a project lists recent activity first.
  /// - Parameters:
  ///   - group: The group.
  ///   - listSort: The session list's own ordering.
  /// - Returns: The sort in effect.
  public func sort(of group: SessionGroup, listSort: SessionSort) -> SessionGroupSort {
    if let sort = chosen[group.key] { return sort }
    guard group == .pinned else { return .recent }
    return listSort == .created ? .created : .custom
  }

  /// Whether what a row says can move it: a group sorted by name, or Pinned by recent activity
  /// (a project's recent order is the list's own, which reports its moves).
  public var followsRows: Bool {
    chosen.contains { key, sort in
      sort == .name || (sort == .recent && key == SessionGroup.pinned.key)
    }
  }

  /// Chooses `sort` for `group`. A project's first Custom keeps the rows where they are.
  /// - Parameters:
  ///   - sort: The sort.
  ///   - group: The group.
  ///   - shown: The group's session ids as they show now, top to bottom.
  public mutating func choose(_ sort: SessionGroupSort, for group: SessionGroup, shown: [String]) {
    chosen[group.key] = sort
    let isRemembered = customOrder[group.key]?.isEmpty == false
    if sort == .custom, group != .pinned, !isRemembered, !shown.isEmpty {
      customOrder[group.key] = shown
    }
  }

  /// Sorts `group` by Custom with `shown` as its order (a row dragged within it, or Move).
  /// - Parameters:
  ///   - group: The group.
  ///   - shown: The group's session ids in their new order, top to bottom.
  public mutating func reorder(_ group: SessionGroup, shown: [String]) {
    chosen[group.key] = .custom
    guard group != .pinned else { return }
    customOrder[group.key] = Self.merged(stored: customOrder[group.key] ?? [], shown: shown)
  }

  /// `shown` with the remembered ids that are not on screen (a search hides them, or their page
  /// is not loaded) kept after the row each followed.
  static func merged(stored: [String], shown: [String]) -> [String] {
    let onScreen = Set(shown)
    var leading: [String] = []
    var following: [String: [String]] = [:]
    var anchor: String?
    for id in stored {
      if onScreen.contains(id) {
        anchor = id
      } else if let anchor {
        following[anchor, default: []].append(id)
      } else {
        leading.append(id)
      }
    }
    return leading + shown.flatMap { [$0] + (following[$0] ?? []) }
  }

  /// Forgets the sort and order of every project but `projects`, the ones that exist.
  mutating func keep(projects: Set<String>) {
    let kept = Set(projects.map { SessionGroup.project($0).key } + [SessionGroup.pinned.key])
    chosen = chosen.filter { kept.contains($0.key) }
    customOrder = customOrder.filter { kept.contains($0.key) }
  }

  /// Forgets the place of sessions that left a project; `members` has every session of each
  /// project whose membership is fully known, by project id.
  mutating func keep(members: [String: Set<String>]) {
    for (project, sessions) in members {
      let key = SessionGroup.project(project).key
      guard let order = customOrder[key] else { continue }
      let remaining = order.filter(sessions.contains)
      if remaining.count != order.count { customOrder[key] = remaining.isEmpty ? nil : remaining }
    }
  }

  /// Forgets what `state` shows is gone: deleted projects, once the projects are read, and
  /// sessions that left a project whose members are all loaded with none hidden.
  /// - Parameters:
  ///   - state: The sidebar.
  ///   - isSearching: A search hides the sessions it does not match.
  public mutating func prune(to state: SidebarViewState, isSearching: Bool) {
    // Only the default grouping lists the projects.
    guard state.display.groupBy == .default else { return }
    let hidesSessions =
      isSearching || state.quickFilter != nil || state.display.show == .archived
    let complete = state.projects.filter { project in
      !hidesSessions && customOrder[SessionGroup.project(project.id).key] != nil
        && state.paging.loadedProjects.contains(project.id)
        && !state.paging.projectsWithMore.contains(project.id)
    }
    if state.projectSort != nil { keep(projects: Set(state.projects.map(\.id))) }
    // A family's place is saved under its id.
    let families = Dictionary(
      state.list.sessions.compactMap { session in session.family.map { (session.id, $0.id) } },
      uniquingKeysWith: { first, _ in first })
    keep(
      members: Dictionary(
        complete.map { project in
          (project.id, Set(project.sessionIds + project.sessionIds.compactMap { families[$0] }))
        }, uniquingKeysWith: { first, _ in first }))
  }
}

nonisolated extension SessionGroupSort {
  /// `sessions` as this sort shows them; ties keep the order given.
  /// - Parameters:
  ///   - sessions: The group's sessions, in the list's order (most recent first).
  ///   - createdAt: When a session was created, Unix seconds.
  ///   - custom: The remembered order for Custom, by ``SessionSummary/orderKey``. Sessions it
  ///     does not name go first, as given,
  ///     so none keeps the order given (Pinned's is the server's pin order).
  /// - Returns: The sessions in order.
  func ordered(
    _ sessions: [SessionSummary], createdAt: (SessionSummary) -> Int64, custom: [String]
  ) -> [SessionSummary] {
    switch self {
    case .recent:
      return Self.stablySorted(sessions) { $0.updatedAt > $1.updatedAt }
    case .name:
      return Self.stablySorted(sessions) {
        $0.title.localizedStandardCompare($1.title) == .orderedAscending
      }
    case .created:
      return Self.stablySorted(sessions) { createdAt($0) > createdAt($1) }
    case .custom:
      let place = Dictionary(
        zip(custom, custom.indices), uniquingKeysWith: { first, _ in first })
      // A family's place is by its id, so it moves as one.
      let remembered = sessions.filter { place[$0.orderKey] != nil }
      return sessions.filter { place[$0.orderKey] == nil }
        + Self.stablySorted(remembered) {
          (place[$0.orderKey] ?? 0) < (place[$1.orderKey] ?? 0)
        }
    }
  }

  /// `sessions` sorted so that `precedes` holds, equal ones staying in the order given.
  private static func stablySorted(
    _ sessions: [SessionSummary], by precedes: (SessionSummary, SessionSummary) -> Bool
  ) -> [SessionSummary] {
    sessions.enumerated().sorted { left, right in
      if precedes(left.element, right.element) { return true }
      if precedes(right.element, left.element) { return false }
      return left.offset < right.offset
    }.map(\.element)
  }
}

nonisolated extension Array where Element: Identifiable {
  /// The array with `moving` placed at `target`'s index (the web's `arrayMove`); empty when
  /// either is missing or they are the same.
  func reordered(moving: Element.ID, onto target: Element.ID) -> [Element] {
    guard let from = firstIndex(where: { $0.id == moving }),
      let to = firstIndex(where: { $0.id == target }), from != to
    else { return [] }
    var result = self
    result.insert(result.remove(at: from), at: to)
    return result
  }

  /// The array with the element `id` moved as `move` says (the web's `moveProject`); empty when
  /// it is missing or already there.
  func moved(_ id: Element.ID, _ move: ProjectMove) -> [Element] {
    guard let from = firstIndex(where: { $0.id == id }) else { return [] }
    let to =
      switch move {
      case .upOne: from - 1
      case .downOne: from + 1
      case .top: 0
      case .bottom: count - 1
      }
    guard indices.contains(to) else { return [] }
    return reordered(moving: id, onto: self[to].id)
  }
}
