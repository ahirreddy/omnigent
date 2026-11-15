import Foundation

/// Session families (nested agents) as the sidebar lists them, as the web's `sessionFamilies.ts`:
/// a family stays together where its best-ranked member stands, its head first and the rest
/// nested under it.
nonisolated enum SidebarFamilies {
  /// How a grouped view keeps a family in one group.
  enum GroupRule: Hashable {
    /// The group of the family's head (Created, Harness).
    case head
    /// The group of its first member in the list's order (Updated).
    case first
    /// The earliest of its members' groups in this order (Status).
    case earliest(order: [String])
  }

  /// Each family's loaded members by family id, head first: the representative when it is
  /// loaded, then oldest first, the original source session, and id.
  static func groups(
    _ sessions: [SessionSummary], createdAt: (SessionSummary) -> Int64
  ) -> [String: [SessionSummary]] {
    var families: [String: [SessionSummary]] = [:]
    for session in sessions {
      if let family = session.family { families[family.id, default: []].append(session) }
    }
    return families.mapValues { members in
      members.sorted { leads($0, $1, createdAt: createdAt) }
    }
  }

  /// Whether `member` stands before `other` in their family.
  private static func leads(
    _ member: SessionSummary, _ other: SessionSummary, createdAt: (SessionSummary) -> Int64
  ) -> Bool {
    let isRepresentative = { (session: SessionSummary) in
      session.family?.representativeID == session.id
    }
    if isRepresentative(member) != isRepresentative(other) { return isRepresentative(member) }
    if createdAt(member) != createdAt(other) { return createdAt(member) < createdAt(other) }
    let isSource = { (session: SessionSummary) in session.family?.id == session.id }
    if isSource(member) != isSource(other) { return isSource(member) }
    return member.id < other.id
  }

  /// `sessions`, in the list's order, with each family gathered where its first member stands,
  /// head first.
  static func ordered(
    _ sessions: [SessionSummary], createdAt: (SessionSummary) -> Int64
  ) -> [SessionSummary] {
    let families = groups(sessions, createdAt: createdAt)
    var listed = Set<String>()
    var result: [SessionSummary] = []
    for session in sessions where !listed.contains(session.id) {
      let members = session.family.flatMap { families[$0.id] } ?? [session]
      for member in members where listed.insert(member.id).inserted {
        result.append(member)
      }
    }
    return result
  }

  /// The rows of a family-ordered list that show: a collapsed family keeps its head (its first
  /// row) and hides the rest.
  static func visible(
    _ rows: some Sequence<SessionSummary>, isCollapsed: (String) -> Bool
  ) -> [SessionSummary] {
    var heads = Set<String>()
    return rows.filter { row in
      guard let family = row.family else { return true }
      return heads.insert(family.id).inserted || !isCollapsed(family.id)
    }
  }

  /// The sessions shown pinned, by the core's `session_shows_pinned`: a nested member follows its
  /// loaded representative, else its family's pin, so a legacy pin of its own never pulls it out
  /// of its family; any other session shows its own pin.
  static func pinnedIDs(_ sessions: [SessionSummary]) -> Set<String> {
    let loaded = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return Set(sessions.lazy.filter { isShownPinned($0, loaded: loaded) }.map(\.id))
  }

  private static func isShownPinned(
    _ session: SessionSummary, loaded: [String: SessionSummary]
  ) -> Bool {
    guard let representative = session.nestedUnder else { return session.isPinned }
    return loaded[representative]?.isPinned ?? (session.family?.isPinned == true)
  }

  /// The pin slots taken (the core's `pinned_unit_count`): pinned, kept sessions on their own
  /// and pinned representatives; members never take one.
  static func pinUnits(_ sessions: [SessionSummary]) -> Int {
    sessions.count { $0.isPinned && !$0.isArchived && $0.isPinUnit }
  }

  /// Each session's group by id, with every family moved into one group by `rule`.
  static func groupTitles(
    _ sessions: [SessionSummary], rule: GroupRule, createdAt: (SessionSummary) -> Int64,
    title: (SessionSummary) -> String
  ) -> [String: String] {
    let families = groups(sessions, createdAt: createdAt)
    var chosen: [String: String] = [:]
    for session in sessions {
      guard let familyID = session.family?.id else { continue }
      let candidate = title(session)
      switch rule {
      case .head:
        if chosen[familyID] == nil { chosen[familyID] = families[familyID]?.first.map(title) }
      case .first:
        if chosen[familyID] == nil { chosen[familyID] = candidate }
      case .earliest(let order):
        let rank = { (group: String) in order.firstIndex(of: group) ?? order.count }
        if chosen[familyID].map({ rank($0) > rank(candidate) }) ?? true {
          chosen[familyID] = candidate
        }
      }
    }
    return Dictionary(
      sessions.map { ($0.id, $0.family.flatMap { chosen[$0.id] } ?? title($0)) },
      uniquingKeysWith: { first, _ in first })
  }

  /// Whether `selected` can move together: each nested member's representative is among them,
  /// since only that moves its family.
  static func canBulkMove(_ selected: [SessionSummary]) -> Bool {
    let ids = Set(selected.map(\.id))
    return selected.allSatisfy { session in session.nestedUnder.map(ids.contains) ?? true }
  }

  /// What a bulk move of `selected` sends: the representatives and the other sessions.
  static func bulkMoveTargets(_ selected: [SessionSummary]) -> [SessionSummary] {
    selected.filter { !$0.isNestedFamilyMember }
  }
}

/// Where a family is collapsed: each section and folder has its own, kept in memory only, as
/// the web keeps them for the tab's life.
nonisolated public struct SidebarFamilyScope: Hashable, Sendable {
  private let name: String

  /// A list section's scope.
  /// - Parameter title: The section's title.
  /// - Returns: The scope.
  public static func section(_ title: String) -> Self { Self(name: "section:\(title)") }

  /// A project folder's scope.
  /// - Parameter id: The folder's id.
  /// - Returns: The scope.
  public static func project(_ id: String) -> Self { Self(name: "project:\(id)") }

  /// The key ``SidebarViewState/collapsedFamilies`` holds for a family collapsed here.
  /// - Parameter family: The family's id.
  /// - Returns: The key.
  public func key(family: String) -> String { "\(name)\n\(family)" }
}

nonisolated extension SidebarViewState {
  /// Whether `family` is collapsed in `scope`.
  func isFamilyCollapsed(_ family: String, in scope: SidebarFamilyScope) -> Bool {
    collapsedFamilies.contains(scope.key(family: family))
  }

  /// When a session was created, Unix seconds; its last update when unknown.
  func createdAt(_ session: SessionSummary) -> Int64 {
    rowInfo[session.id]?.createdAt ?? session.updatedAt
  }

  /// `rows`, family-ordered, as `scope` shows them with its collapsed families.
  func visibleRows(_ rows: some Sequence<SessionSummary>, in scope: SidebarFamilyScope)
    -> [SessionSummary]
  {
    SidebarFamilies.visible(rows) { isFamilyCollapsed($0, in: scope) }
  }
}

nonisolated extension SidebarSections {
  /// A group's reorder units top to bottom: each family's head and every other row.
  static func units(of group: SessionGroup, in state: SidebarViewState) -> [SessionSummary] {
    var seen = Set<String>()
    return rows(of: group, in: state).filter { seen.insert($0.orderKey).inserted }
  }

  /// What a group's saved order holds for `rows`: Pinned's pin order its pins (a nested head's
  /// pin is its representative's), a project's order each family by its id.
  static func orderIDs(_ rows: [SessionSummary], in group: SessionGroup) -> [String] {
    switch group {
    case .pinned: rows.filter { !$0.isNestedFamilyMember }.map(\.id)
    case .project: rows.map(\.orderKey)
    }
  }
}
