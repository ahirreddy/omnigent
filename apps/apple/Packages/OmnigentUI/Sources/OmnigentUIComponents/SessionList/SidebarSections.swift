import Foundation

/// Splits the core-ordered sessions into the sidebar's sections for the chosen grouping. The
/// default is the web's: Pinned, Projects, Shared, Sessions.
nonisolated enum SidebarSections {
  struct Section: Identifiable, Hashable {
    let title: String
    var sessions: [SessionSummary]
    var isProjects = false
    var showsDisplayMenu = false
    var id: String { title }
  }

  static func sections(_ state: SidebarViewState, calendar: Calendar = .current) -> [Section] {
    let sessions = sorted(state.list.sessions, state: state)
    switch state.display.groupBy {
    case .default:
      return defaultSections(sessions, state: state)
    case .status:
      return statusSections(sessions, state: state)
    case .harness:
      return harnessSections(sessions, state: state)
    case .created, .updated:
      return dateSections(sessions, state: state, calendar: calendar)
    }
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
    if !pinned.isEmpty { result.append(Section(title: "Pinned", sessions: pinned)) }
    if !state.projects.isEmpty {
      result.append(Section(title: "Projects", sessions: [], isProjects: true))
    }
    if !shared.isEmpty { result.append(Section(title: "Shared", sessions: shared)) }
    result.append(Section(title: "Sessions", sessions: rest, showsDisplayMenu: true))
    return result
  }

  private static func statusSections(_ sessions: [SessionSummary], state: SidebarViewState)
    -> [Section]
  {
    // One section per attention state, so a session sits where its row glyph says.
    let needs = sessions.filter { $0.attention == .needsYou }
    let running = sessions.filter { $0.attention == .working }
    let failed = sessions.filter { $0.attention == .failed }
    let idle = sessions.filter { $0.attention == .unread || $0.attention == .idle }
    return withMenu([
      Section(title: "Needs you", sessions: needs),
      Section(title: "Running", sessions: running),
      Section(title: "Error", sessions: failed),
      Section(title: "Idle", sessions: idle),
    ])
  }

  private static func harnessSections(_ sessions: [SessionSummary], state: SidebarViewState)
    -> [Section]
  {
    var order: [String] = []
    var buckets: [String: [SessionSummary]] = [:]
    for session in sessions {
      let label = HarnessAppearance(harness: state.rowInfo[session.id]?.harness).label
      if buckets[label] == nil { order.append(label) }
      buckets[label, default: []].append(session)
    }
    return withMenu(order.map { Section(title: $0, sessions: buckets[$0] ?? []) })
  }

  private static func dateSections(
    _ sessions: [SessionSummary], state: SidebarViewState, calendar: Calendar
  ) -> [Section] {
    let now = state.list.now ?? Date()
    let titles = ["Today", "Yesterday", "Previous 7 days", "Previous 30 days", "Older"]
    var buckets: [String: [SessionSummary]] = [:]
    let startOfToday = calendar.startOfDay(for: now)
    for session in sessions {
      let stamp =
        state.display.groupBy == .created
        ? (state.rowInfo[session.id]?.createdAt ?? session.updatedAt) : session.updatedAt
      let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(stamp)))
      let days = calendar.dateComponents([.day], from: day, to: startOfToday).day ?? 0
      let title: String =
        switch days {
        case ..<1: "Today"
        case 1: "Yesterday"
        case 2..<7: "Previous 7 days"
        case 7..<30: "Previous 30 days"
        default: "Older"
        }
      buckets[title, default: []].append(session)
    }
    return withMenu(
      titles.compactMap { title in buckets[title].map { Section(title: title, sessions: $0) } })
  }

  /// Drops empty sections and puts the display menu on the first.
  private static func withMenu(_ sections: [Section]) -> [Section] {
    var result = sections.filter { !$0.sessions.isEmpty }
    if result.isEmpty { result = [Section(title: "Sessions", sessions: [])] }
    result[0].showsDisplayMenu = true
    return result
  }
}
