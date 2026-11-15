import Foundation

/// Splits the core-ordered sessions into the sidebar's sections for the chosen grouping. The
/// default is the web's: Pinned, Projects, Shared, Sessions; other groupings keep Pinned on top.
nonisolated enum SidebarSections {
  struct Section: Identifiable, Hashable {
    let title: String
    var sessions: [SessionSummary]
    var isProjects = false
    var showsDisplayMenu = false
    var isPinned = false
    var id: String { title }
  }

  static func sections(_ state: SidebarViewState, calendar: Calendar = .current) -> [Section] {
    let pinnedIDs = SidebarFamilies.pinnedIDs(state.list.sessions)
    let pinned = pinned(state, pinnedIDs: pinnedIDs)
    let rest = sorted(state.list.sessions.filter { !pinnedIDs.contains($0.id) }, state: state)
    guard state.display.groupBy != .default else {
      return defaultSections(pinned: pinned, rest: rest, state: state)
    }
    // Grouped views keep Pinned on top and group the rest, as the web does.
    let groups: [Section] =
      switch state.display.groupBy {
      case .default, .status: statusSections(rest, state: state)
      case .harness: harnessSections(rest, state: state)
      case .created, .updated: dateSections(rest, state: state, calendar: calendar)
      }
    let pinnedSection = Section(title: "Pinned", sessions: pinned, isPinned: true)
    return (pinned.isEmpty ? [] : [pinnedSection]) + groups
  }

  /// The sessions outside Pinned, in the list's Ordering.
  private static func sorted(_ sessions: [SessionSummary], state: SidebarViewState)
    -> [SessionSummary]
  {
    guard state.display.sortBy == .created else { return sessions }
    return order(sessions, by: .created, state: state)
  }

  /// `sessions` in `sort`'s order; a session without a creation date sorts by its last update.
  private static func order(
    _ sessions: [SessionSummary], by sort: SessionGroupSort, custom: [String] = [],
    state: SidebarViewState
  ) -> [SessionSummary] {
    sort.ordered(sessions, createdAt: state.createdAt, custom: custom)
  }

  /// `sessions` with each family together, head first.
  private static func families(_ sessions: [SessionSummary], state: SidebarViewState)
    -> [SessionSummary]
  {
    SidebarFamilies.ordered(sessions, createdAt: state.createdAt)
  }

  /// The Pinned group's rows top to bottom, a pinned family's members nested under its head;
  /// its Custom order is the server's pin order.
  static func pinned(_ state: SidebarViewState) -> [SessionSummary] {
    pinned(state, pinnedIDs: SidebarFamilies.pinnedIDs(state.list.sessions))
  }

  private static func pinned(_ state: SidebarViewState, pinnedIDs: Set<String>)
    -> [SessionSummary]
  {
    let sessions = state.list.sessions.filter { pinnedIDs.contains($0.id) }
    return families(order(sessions, by: state.sort(of: .pinned), state: state), state: state)
  }

  /// A project's loaded sessions top to bottom, in its sort's order with each family together;
  /// a pinned family shows in Pinned instead.
  static func sessions(of project: SessionProject, in state: SidebarViewState)
    -> [SessionSummary]
  {
    let pinned = SidebarFamilies.pinnedIDs(state.list.sessions)
    let members = Set(project.sessionIds).subtracting(pinned)
    let loaded = Dictionary(
      state.list.sessions.lazy.filter { members.contains($0.id) }.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first })
    let sessions = project.sessionIds.compactMap { loaded[$0] }
    let group = SessionGroup.project(project.id)
    let sort = state.sort(of: group)
    // A project's sessions arrive most recent first: the list's own order.
    guard sort != .recent else { return families(sessions, state: state) }
    let custom = state.groupSorts.customOrder[group.key] ?? []
    return families(order(sessions, by: sort, custom: custom, state: state), state: state)
  }

  /// A group's rows top to bottom: Pinned's, or a project's loaded sessions.
  static func rows(of group: SessionGroup, in state: SidebarViewState) -> [SessionSummary] {
    switch group {
    case .pinned: pinned(state)
    case .project(let id):
      state.projects.first { $0.id == id }.map { sessions(of: $0, in: state) } ?? []
    }
  }

  private static func defaultSections(
    pinned: [SessionSummary], rest sessions: [SessionSummary], state: SidebarViewState
  ) -> [Section] {
    let inProject = Set(state.projects.flatMap(\.sessionIds))
    let shared = sessions.filter { state.rowInfo[$0.id]?.isShared == true }
    let rest = sessions.filter {
      !inProject.contains($0.id) && state.rowInfo[$0.id]?.isShared != true
    }
    var result: [Section] = []
    if !pinned.isEmpty { result.append(Section(title: "Pinned", sessions: pinned, isPinned: true)) }
    // Always shown, as on the web, so New project stays reachable.
    result.append(Section(title: "Projects", sessions: [], isProjects: true))
    // Shared sessions are someone else's, which never carry a family.
    if !shared.isEmpty { result.append(Section(title: "Shared", sessions: shared)) }
    result.append(
      Section(title: "Sessions", sessions: families(rest, state: state), showsDisplayMenu: true))
    return result
  }

  /// The web's status buckets, in its order.
  static let statusTitles = ["Needs attention", "Unread", "Working", "Draft", "Done"]

  private static func statusSections(_ sessions: [SessionSummary], state: SidebarViewState)
    -> [Section]
  {
    // A family goes where its most urgent member would.
    let buckets = buckets(sessions, rule: .earliest(order: statusTitles), state: state) {
      statusTitle($0, state: state)
    }
    // Working stays visible while empty, as on the web.
    return withMenu(
      statusTitles.map { Section(title: $0, sessions: buckets[$0] ?? []) }, keepEmpty: "Working")
  }

  /// `sessions` by group title, each family kept in one group by `rule` and gathered in it.
  private static func buckets(
    _ sessions: [SessionSummary], rule: SidebarFamilies.GroupRule, state: SidebarViewState,
    title: (SessionSummary) -> String
  ) -> [String: [SessionSummary]] {
    let titles = SidebarFamilies.groupTitles(
      sessions, rule: rule, createdAt: state.createdAt, title: title)
    var buckets: [String: [SessionSummary]] = [:]
    for session in sessions {
      buckets[titles[session.id] ?? title(session), default: []].append(session)
    }
    return buckets.mapValues { families($0, state: state) }
  }

  /// The web's `statusBucket`: pending or failed first, then running, unread, draft, done.
  static func statusTitle(_ session: SessionSummary, state: SidebarViewState) -> String {
    switch session.attention {
    case .needsYou, .failed: return "Needs attention"
    case .working: return "Working"
    case .unread, .idle:
      if session.attention == .unread || state.list.unreadIds.contains(session.id) {
        return "Unread"
      }
      return state.rowInfo[session.id]?.hasDraft == true ? "Draft" : "Done"
    }
  }

  private static func harnessSections(_ sessions: [SessionSummary], state: SidebarViewState)
    -> [Section]
  {
    let buckets = buckets(sessions, rule: .head, state: state) { session in
      HarnessAppearance(harness: state.rowInfo[session.id]?.harness).label
    }
    let order = buckets.keys.sorted { $0.localizedCompare($1) == .orderedAscending }
    return withMenu(order.map { Section(title: $0, sessions: buckets[$0] ?? []) })
  }

  /// The web's date buckets; titles read "Updated today", "Created in the last 7 days", ….
  static let dateBuckets = [
    "today", "yesterday", "in the last 7 days", "in the last 30 days", "earlier",
  ]

  private static func dateSections(
    _ sessions: [SessionSummary], state: SidebarViewState, calendar: Calendar
  ) -> [Section] {
    let now = state.list.now ?? Date()
    let prefix = state.display.groupBy.title
    let isCreated = state.display.groupBy == .created
    // Created follows the family's head; Updated its first member in the list's order.
    let buckets = buckets(sessions, rule: isCreated ? .head : .first, state: state) { session in
      let stamp = isCreated ? state.createdAt(session) : session.updatedAt
      return dateBucket(
        Date(timeIntervalSince1970: TimeInterval(stamp)), now: now, calendar: calendar)
    }
    return withMenu(
      dateBuckets.compactMap { bucket in
        buckets[bucket].map { Section(title: "\(prefix) \(bucket)", sessions: $0) }
      })
  }

  /// The web's `dateBucket`: by local calendar day relative to `now`.
  static func dateBucket(_ date: Date, now: Date, calendar: Calendar) -> String {
    let midnight = { (daysAgo: Int) in
      calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)) ?? now
    }
    if date >= midnight(0) { return "today" }
    if date >= midnight(1) { return "yesterday" }
    if date >= midnight(7) { return "in the last 7 days" }
    if date >= midnight(30) { return "in the last 30 days" }
    return "earlier"
  }

  /// Drops empty sections (but `keepEmpty`) and puts the display menu on the first.
  private static func withMenu(_ sections: [Section], keepEmpty: String? = nil) -> [Section] {
    var result = sections.filter { !$0.sessions.isEmpty || $0.title == keepEmpty }
    if result.isEmpty { result = [Section(title: "Sessions", sessions: [])] }
    result[0].showsDisplayMenu = true
    return result
  }
}
