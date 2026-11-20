import SwiftUI

extension SidebarView {
  /// How a section or folder draws its families: `rows` family-ordered, `listedCount` of them on
  /// its page, collapsed in `scope`.
  func familyLayout(
    _ rows: [SessionSummary], listedCount: Int = .max, scope: SidebarFamilyScope
  ) -> SidebarFamilyLayout {
    SidebarFamilyLayout(
      rows: rows, listedCount: listedCount, scope: scope, state: state,
      setCollapsed: actions.setFamilyCollapsed)
  }

  /// How a row of `section` sits in its family, and where a drop on it lands: a row that moves
  /// with its family stands for the section, so nothing lands inside a family.
  func rowPlace(
    _ session: SessionSummary, in section: SidebarSections.Section, layout: SidebarFamilyLayout
  ) -> (family: SessionRowFamily, target: SidebarDropTarget?) {
    let family = layout.family(of: session)
    let isNested = family.movesWithFamily(session)
    return (family, dropHandler.rowTarget(session, in: section, isNested: isNested))
  }

  /// How a row of `project`'s folder sits in its family, and where a drop on it lands.
  func rowPlace(
    _ session: SessionSummary, in project: SessionProject, layout: SidebarFamilyLayout
  ) -> (family: SessionRowFamily, target: SidebarDropTarget) {
    let family = layout.family(of: session)
    let isNested = family.movesWithFamily(session)
    return (family, isNested ? .project(project) : .projectSlot(project, session.id))
  }

  func summary(_ id: String) -> SessionSummary? {
    state.list.sessions.first { $0.id == id }
  }

  /// A session as it is now; the list's own copy can be a message behind.
  func current(_ id: String) -> SessionSummary? {
    actions.live?.row(id, false)?.session ?? summary(id)
  }

  var dropHandler: SidebarDropHandler { SidebarDropHandler(state: state, actions: actions) }

  /// A row as a drag source and target; a row that moves with its family drags only between
  /// nests.
  func rowDrag(_ session: SessionSummary, family: SessionRowFamily) -> SidebarRowDrag {
    dropHandler.rowDrag(session, movesWithFamily: family.movesWithFamily(session))
  }

  /// The nests `session` can join, read when its menu shows.
  func nestDestinations(for session: SessionSummary) -> @MainActor () -> [SessionSummary] {
    let state = state
    return {
      SidebarFamilies.nestDestinations(for: session, among: state.list.sessions) {
        state.rowInfo[$0]?.isShared == true
      }
    }
  }
}
