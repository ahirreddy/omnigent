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
    let sessions = sorted(state.list.sessions, state: state)
    guard state.display.groupBy != .default else { return defaultSections(sessions, state: state) }
    // Grouped views keep Pinned on top and group the rest, as the web does.
    let pinned = sessions.filter(\.isPinned)
    let rest = sessions.filter { !$0.isPinned }
    let groups: [Section] =
      switch state.display.groupBy {
      case .default, .status: statusSections(rest, state: state)
      case .harness: harnessSections(rest, state: state)
      case .created, .updated: dateSections(rest, state: state, calendar: calendar)
      }
    let pinnedSection = Section(title: "Pinned", sessions: pinned, isPinned: true)
    return (pinned.isEmpty ? [] : [pinnedSection]) + groups
  }

  private static func sorted(_ sessions: [SessionSummary], state: SidebarViewState)
    -> [SessionSummary]
  {
    guard state.display.sortBy == .created else { return sessions }
    return sessions.enumerated().sorted { left, right in
      let leftCreated = state.rowInfo[left.element.id]?.createdAt ?? left.element.updatedAt
      let rightCreated = state.rowInfo[right.element.id]?.createdAt ?? right.element.updatedAt
      if leftCreated != rightCreated { return leftCreated > rightCreated }
      return left.offset < right.offset
    }.map(\.element)
  }

  private static func defaultSections(_ sessions: [SessionSummary], state: SidebarViewState)
    -> [Section]
  {
    let inProject = Set(state.projects.flatMap(\.sessionIds))
    let pinned = sessions.filter(\.isPinned)
    let shared = sessions.filter { !$0.isPinned && state.rowInfo[$0.id]?.isShared == true }
    let rest = sessions.filter {
      !$0.isPinned && !inProject.contains($0.id) && state.rowInfo[$0.id]?.isShared != true
    }
    var result: [Section] = []
    if !pinned.isEmpty { result.append(Section(title: "Pinned", sessions: pinned, isPinned: true)) }
    // Always shown, as on the web, so New project stays reachable.
    result.append(Section(title: "Projects", sessions: [], isProjects: true))
    if !shared.isEmpty { result.append(Section(title: "Shared", sessions: shared)) }
    result.append(Section(title: "Sessions", sessions: rest, showsDisplayMenu: true))
    return result
  }

  /// The web's status buckets, in its order.
  static let statusTitles = ["Needs attention", "Unread", "Working", "Draft", "Done"]

  private static func statusSections(_ sessions: [SessionSummary], state: SidebarViewState)
    -> [Section]
  {
    var buckets: [String: [SessionSummary]] = [:]
    for session in sessions {
      buckets[statusTitle(session, state: state), default: []].append(session)
    }
    // Working stays visible while empty, as on the web.
    return withMenu(
      statusTitles.map { Section(title: $0, sessions: buckets[$0] ?? []) }, keepEmpty: "Working")
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
    var buckets: [String: [SessionSummary]] = [:]
    for session in sessions {
      let label = HarnessAppearance(harness: state.rowInfo[session.id]?.harness).label
      buckets[label, default: []].append(session)
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
    var buckets: [String: [SessionSummary]] = [:]
    for session in sessions {
      let stamp =
        state.display.groupBy == .created
        ? (state.rowInfo[session.id]?.createdAt ?? session.updatedAt) : session.updatedAt
      let bucket = dateBucket(
        Date(timeIntervalSince1970: TimeInterval(stamp)), now: now, calendar: calendar)
      buckets[bucket, default: []].append(session)
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
