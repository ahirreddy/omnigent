import SwiftUI

/// The paging of one folder: its members are read from the server a page at a time (the web's
/// `?project=` read), and listed ten more per Show more, or all of them.
struct ProjectFolderPages {
  /// Rows listed.
  let visibleCount: Int
  /// Members left on the server.
  let hasMore: Bool
  let isLoading: Bool
  /// The first page was read.
  let isLoaded: Bool
  /// Reveal ten more rows, reading the next page when the loaded ones run out.
  let showMore: () -> Void
  /// Read the folder's first page, or its next.
  let load: (() -> Void)?
  /// The server offers project boards, so a click on the row may open the folder's board.
  var offersBoard = false
  /// Its board is shown.
  var isBoardShown = false
  /// Show All Sessions is on: every member is listed and every page read.
  var showsAll = false
  /// Turns Show All Sessions on or off, and keeps it.
  var setShowsAll: (Bool) -> Void = { _ in }
}

extension ProjectFolderPages {
  /// A folder's rows and pages: Show more lists ten more and reads the next server page once
  /// the loaded rows run out. `shown` is nil until Show more or the menu sets it.
  @MainActor init(
    project: SessionProject, sessions: [SessionSummary], paging: SidebarPaging, shown: Int?,
    selection: SidebarDestination?, boards: Bool = false,
    load: (@MainActor (SessionProject) -> Void)?, setShown: @escaping (Int) -> Void
  ) {
    let selectedID = selection?.sessionID
    let shown = shown ?? ProjectShowAll.shown(project.id)
    let selectedIndex = selectedID.flatMap { id in sessions.firstIndex { $0.id == id } }
    let visible = ProjectFolderPaging.visibleCount(
      count: sessions.count, shown: shown, selectedIndex: selectedIndex)
    // A placeholder holds loaded rows only; the server has no project to page.
    let loadPage = project.isPlaceholder ? nil : load.map { load in { load(project) } }
    self.init(
      visibleCount: visible, hasMore: paging.projectsWithMore.contains(project.id),
      isLoading: paging.loadingProjects.contains(project.id),
      isLoaded: project.isPlaceholder || paging.loadedProjects.contains(project.id),
      showMore: {
        let next = visible + ProjectFolderPaging.pageSize
        setShown(next)
        if next > sessions.count { loadPage?() }
      },
      load: loadPage, offersBoard: boards && !project.isPlaceholder,
      isBoardShown: selection == .project(project.id),
      showsAll: shown == ProjectFolderPaging.all,
      setShowsAll: { isOn in
        ProjectShowAll.set(project.id, isOn)
        setShown(isOn ? ProjectFolderPaging.all : 0)
        if isOn, paging.projectsWithMore.contains(project.id) { loadPage?() }
      })
  }
}
