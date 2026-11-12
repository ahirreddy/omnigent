import Observation
import SwiftUI

/// What the list is told is selected. A session's row that arrives together with its section or
/// folder is named one update later: an outline handed a new group whose row is already selected
/// keeps a second copy of that row, which then never moves, updates its fill or leaves.
nonisolated enum SidebarListSelection {
  /// The groups that hold session rows, as the list identifies them: each section and folder.
  static func groups(_ sections: [SidebarSections.Section], projects: [SessionProject])
    -> Set<String>
  {
    var groups = Set(sections.lazy.filter { !$0.isProjects }.map { group(section: $0.title) })
    if sections.contains(where: \.isProjects) {
      groups.formUnion(projects.map { group(project: $0.id) })
    }
    return groups
  }

  /// The group whose rows include `sessionID`; `nil` when no row shows that session.
  static func group(
    of sessionID: String, sections: [SidebarSections.Section], projects: [SessionProject]
  ) -> String? {
    for section in sections where !section.isProjects {
      if section.sessions.contains(where: { $0.id == sessionID }) {
        return group(section: section.title)
      }
    }
    guard sections.contains(where: \.isProjects) else { return nil }
    return projects.first { $0.sessionIds.contains(sessionID) }.map { group(project: $0.id) }
  }

  /// `selection` for the list: a session is named once the list has drawn the group its row is
  /// in. Pages, and a session without a row, pass through.
  static func listed(
    _ selection: SidebarDestination?, group: String?, drawn: Set<String>
  ) -> SidebarDestination? {
    guard selection?.sessionID != nil, let group else { return selection }
    return drawn.contains(group) ? selection : nil
  }

  private static func group(section title: String) -> String { "section:\(title)" }
  private static func group(project id: String) -> String { "project:\(id)" }
}

/// The groups one update of the list draws, and the one that holds the selected session's row.
nonisolated struct SidebarShownGroups: Equatable {
  var all: Set<String>
  var selected: String?
}

/// The groups the list drew in its last finished update, and the selection that waits on them.
@MainActor
@Observable
final class SidebarDrawnGroups {
  @ObservationIgnored private var groups: Set<String> = []
  /// The list was told no selection, for a session whose group it has not drawn yet. A selection
  /// the list clears meanwhile is not the user's choice.
  @ObservationIgnored private(set) var isHoldingBack = false
  /// Counts the selections told one update late, so the view that reads the groups draws again.
  private var lateSelections = 0

  /// The groups `sections` and `projects` draw, with the group of the selected session's row.
  func shown(
    _ sections: [SidebarSections.Section], projects: [SessionProject],
    selection: SidebarDestination?
  ) -> SidebarShownGroups {
    _ = lateSelections
    return SidebarShownGroups(
      all: SidebarListSelection.groups(sections, projects: projects),
      selected: selection?.sessionID.flatMap { sessionID in
        SidebarListSelection.group(of: sessionID, sections: sections, projects: projects)
      })
  }

  /// `selection` for the list now; a session whose `group` is not drawn yet is noted as waiting.
  func listed(_ selection: SidebarDestination?, group: String?) -> SidebarDestination? {
    let listed = SidebarListSelection.listed(selection, group: group, drawn: groups)
    if listed != selection { isHoldingBack = true }
    return listed
  }

  /// Records `groups` as drawn, once the update that drew them has finished. A selection that
  /// waited on them is told to the list by drawing it again.
  func settle(_ groups: Set<String>) {
    let wasHoldingBack = isHoldingBack
    self.groups = groups
    isHoldingBack = false
    if wasHoldingBack { lateSelections += 1 }
  }
}
