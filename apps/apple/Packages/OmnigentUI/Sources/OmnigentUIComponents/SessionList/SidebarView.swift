public import SwiftUI

/// The sidebar, structured like the web's: the wordmark with a server switcher, New session,
/// Inbox and Canvas, the native quick filters (Running, Needs you), then Pinned, Projects,
/// Shared and Sessions with the web's filter and display menu. Native list selection, keyboard
/// navigation, context menus, hover pin, swipe actions and Delete-to-archive.
public struct SidebarView: View {
  let state: SidebarViewState
  @Binding private var selection: SidebarDestination?
  @Binding private var searchText: String
  let actions: SidebarActions

  @State private var renaming: SessionSummary?
  @State private var renameText = ""
  @State private var confirmingDelete: SessionSummary?
  @State private var confirmingBulkDelete: [SessionSummary] = []
  @State private var confirmingLeave: SessionSummary?
  @State private var confirmingStop: SessionSummary?
  @State private var bulk = SidebarBulkSelection()
  @State private var inlineEdit = SidebarInlineEdit()
  /// Expanded project folders (they start collapsed), newline-separated, kept across launches.
  @AppStorage(SidebarNavigationOrder.expandedProjectsKey) private var expandedProjectIDs = ""
  /// Rows each folder's Show more has revealed, by folder id.
  @State private var shownInProject: [String: Int] = [:]
  /// Pages the Load more row read by itself as it scrolled into view.
  @State private var autoLoads = SidebarAutoLoads()
  @State private var projectPrompt: ProjectPrompt?
  @State private var projectName = ""
  @State private var confirmingProjectDelete: SessionProject?
  /// Collapsed section titles, newline-separated, kept across launches.
  @AppStorage(SidebarNavigationOrder.collapsedSectionsKey) private var collapsedSections = ""
  @AppStorage(InterfacePreferences.harnessIconKey) private var harnessIcon = HarnessIconStyle
    .default
  @State private var behavior = SidebarBehavior()
  @State private var drawnGroups = SidebarDrawnGroups()

  /// Creates the sidebar.
  /// - Parameters:
  ///   - state: Sessions, projects, counts and servers.
  ///   - selection: The selected destination.
  ///   - searchText: Search text; the host re-queries the core.
  ///   - actions: Host actions.
  public init(
    state: SidebarViewState, selection: Binding<SidebarDestination?>,
    searchText: Binding<String>, actions: SidebarActions
  ) {
    self.state = state
    _selection = selection
    _searchText = searchText
    self.actions = actions
  }

  /// The sidebar.
  public var body: some View {
    let sections = SidebarSections.sections(behavior.holding(state))
    let groups = drawnGroups.shown(sections, projects: state.projects, selection: selection)
    List(selection: listSelection(in: groups.selected)) {
      SidebarNavigationRows(state: state, selection: selection, actions: actions)
      ForEach(sections) { section in
        sessionSection(section)
      }
      // A new page can land in any list section, so Load more hides only when all are collapsed.
      if state.paging.hasMore, let load = actions.loadMoreSessions,
        sections.contains(where: { !$0.isProjects && !collapsedTitles.contains($0.title) })
      {
        SidebarLoadMoreRow(
          isLoading: state.paging.isLoading, loaded: state.list.sessions.count,
          autoLoads: autoLoads, scope: loadMoreScope, load: load)
      }
      SidebarEmptyState(
        state: state, searchText: searchText, setQuickFilter: actions.setQuickFilter)
    }
    .onHover { behavior.pointer(inside: $0, sessions: state.list.sessions) }
    .onChange(of: searchText.isEmpty) { _, isEmpty in
      if !isEmpty { behavior.searchCollapsed = [] }
    }
    .onChange(of: SidebarSections.pinned(state).map(\.id)) { old, new in
      // A new pin opens Pinned, so it can't hide in a collapsed section.
      if SidebarBehavior.addsPin(old, new), !expansion(of: "Pinned").wrappedValue {
        expansion(of: "Pinned").wrappedValue = true
      }
    }
    .listStyle(.sidebar)
    .font(.callout)
    .environment(\.defaultMinListRowHeight, Theme.Control.sidebarRow)
    // On the list itself: further out it would also land on the header's wordmark and server
    // switcher, overriding their own identifiers.
    .accessibilityIdentifier("sidebar")
    .scrollContentBackground(.hidden)
    .themeSidebar()
    .modifier(SidebarSearchField(text: $searchText))
    .safeAreaInset(edge: .top, spacing: 0) { SidebarHeader(state: state, actions: actions) }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      SidebarBottomBars(
        state: state, actions: actions, bulk: $bulk, confirmDelete: { confirmingBulkDelete = $0 })
    }
    .sidebarAccountFooter(state.account, signOut: actions.signOut)
    #if os(macOS)
      .contextMenu(forSelectionType: SidebarDestination.self) { _ in
        EmptyView()
      } primaryAction: { destinations in
        renameOnDoubleClick(destinations)
      }
      .onDeleteCommand {
        guard !bulk.isActive, let id = selection?.sessionID, let session = current(id),
          session.canArchive, let setArchived = actions.sessions.setArchived
        else { return }
        setArchived(session, !session.isArchived)
      }
      .onExitCommand { if bulk.isActive { bulk.end() } }
    #endif
    .onChange(of: state.display.show) { bulk.end() }
    // After the update that drew them, so a selection that waited on a new group is told late.
    .task(id: groups.all) { drawnGroups.settle(groups.all) }
    .onChange(of: expandedProjectIDs, initial: true) { actions.setOpenProjects?(expandedProjects) }
    .modifier(
      SessionDialogs(
        renaming: $renaming, renameText: $renameText, confirmingDelete: $confirmingDelete,
        confirmingBulkDelete: $confirmingBulkDelete, confirmingLeave: $confirmingLeave,
        confirmingStop: $confirmingStop, rowInfo: state.rowInfo, actions: actions.sessions,
        deletedMany: { bulk.clear() })
    )
    .modifier(
      ProjectDialogs(
        prompt: $projectPrompt, name: $projectName, confirmingDelete: $confirmingProjectDelete,
        actions: actions, runChoices: state.projectRunChoices)
    )
  }

  /// The list's selection, a session's once its group is drawn (``SidebarListSelection``). While
  /// selecting sessions a click checks the row instead (Shift extends from the last one).
  private func listSelection(in selectedGroup: String?) -> Binding<SidebarDestination?> {
    Binding(
      get: { bulk.isActive ? nil : drawnGroups.listed(selection, group: selectedGroup) },
      set: { destination in
        guard bulk.isActive else {
          if destination != nil || !drawnGroups.isHoldingBack { selection = destination }
          return
        }
        if let id = destination?.sessionID {
          bulk.toggle(id, extending: SidebarBulkSelection.isExtending, order: visibleSessionIDs)
        } else if let destination {
          bulk.end()
          selection = destination
        }
      })
  }

  /// The session rows on screen, top to bottom, for a Shift-click range.
  private var visibleSessionIDs: [String] {
    SidebarNavigationOrder.sessionIDs(
      behavior.holding(state), collapsed: collapsedTitles,
      expandedProjects: expandedProjects, shownInProject: shownInProject)
  }

  @ViewBuilder
  private func sessionSection(_ section: SidebarSections.Section) -> some View {
    Section(isExpanded: expansion(of: section.title)) {
      if section.isProjects {
        ForEach(state.projects) { project in
          projectGroup(project)
        }
        if state.projects.isEmpty {
          Text("No projects").foregroundStyle(.secondary)
        }
      } else {
        let layout = familyLayout(section.sessions, scope: .section(section.title))
        ForEach(layout.visible) { session in
          let place = rowPlace(session, in: section, layout: layout)
          row(session, target: place.target, family: place.family)
        }
      }
    } header: {
      HStack {
        Text(section.title)
          .font(Theme.Typography.section)
          .foregroundStyle(Theme.mutedText)
          .textCase(nil)
        hiddenMarker(section)
        if section.isPinned, !bulk.isActive, let setSort = actions.setGroupSort {
          PinnedSortMenu(sort: state.sort(of: .pinned)) { setSort(.pinned, $0) }
        }
        if section.isProjects, !bulk.isActive {
          projectsHeaderButtons
        }
        if section.showsDisplayMenu {
          if !bulk.isActive {
            SessionsHeaderButtons(newSession: actions.sessions.newSession) { bulk.begin() }
          }
          if let setDisplay = actions.setDisplay {
            DisplayMenu(
              options: state.display, showsShared: state.showsSharedScope, set: setDisplay)
          }
        }
        // After the controls: the list's disclosure arrow takes the trailing edge on hover.
        Spacer()
      }
      .sidebarHeaderControls()
      .sidebarDropTarget { item in drop(item, on: dropHandler.sectionTarget(section)) }
    }
  }

  /// New project and the project list's menu, on the Projects header.
  @ViewBuilder private var projectsHeaderButtons: some View {
    if actions.createProject != nil {
      Button("New project", systemImage: "plus") {
        projectName = ""
        projectPrompt = .create(moving: nil)
      }
      .help("New project")
      .accessibilityIdentifier("sidebar-new-project")
    }
    ProjectsHeaderMenu(
      state: state, actions: actions, expanded: expandedProjects,
      setExpanded: { setExpandedProjects($0) }, selectSessions: { bulk.begin() })
  }

  /// Collapsed sections: the saved ones, or while searching those collapsed during the search.
  private var collapsedTitles: Set<String> {
    searchText.isEmpty
      ? SidebarNavigationOrder.lines(collapsedSections) : behavior.searchCollapsed
  }

  /// Whether a section is expanded; collapsing one is remembered (outside a search).
  private func expansion(of title: String) -> Binding<Bool> {
    Binding(
      get: { !collapsedTitles.contains(title) },
      set: { expanded in
        guard searchText.isEmpty else {
          if expanded {
            behavior.searchCollapsed.remove(title)
          } else {
            behavior.searchCollapsed.insert(title)
          }
          return
        }
        var titles = collapsedSections.split(separator: "\n").map(String.init)
        titles.removeAll { $0 == title }
        if !expanded { titles.append(title) }
        collapsedSections = titles.joined(separator: "\n")
      })
  }

  /// The strongest state hidden under a collapsed section, for its header.
  @ViewBuilder
  private func hiddenMarker(_ section: SidebarSections.Section) -> some View {
    if collapsedTitles.contains(section.title) {
      let sessions =
        section.isProjects
        ? state.projects.flatMap(\.sessionIds).compactMap(summary) : section.sessions
      SidebarHiddenMarker(sessions: sessions, state: state, live: actions.live)
    }
  }

}

extension SidebarView {
  /// What the list shows; each choice gets its own automatic Load more budget, as the web's tabs.
  private var loadMoreScope: String {
    "\(state.display.show)-\(state.quickFilter.map { "\($0)" } ?? "")-\(searchText)"
  }

  private var expandedProjects: Set<String> {
    Set(expandedProjectIDs.split(separator: "\n").map(String.init))
  }

  private func setExpandedProjects(_ ids: Set<String>) {
    let text = ids.sorted().joined(separator: "\n")
    if text != expandedProjectIDs { expandedProjectIDs = text }
  }

  private func projectGroup(_ project: SessionProject) -> some View {
    let sessions = SidebarSections.sessions(of: project, in: state)
    let marker = { (rows: ArraySlice<SessionSummary>) in
      SidebarHiddenMarker(sessions: Array(rows), state: state, live: actions.live)
    }
    let pages = ProjectFolderPages(
      project: project, sessions: sessions, paging: state.paging,
      shown: shownInProject[project.id], selectedID: selection?.sessionID,
      load: actions.loadProjectPage, setShown: { shownInProject[project.id] = $0 })
    let layout = familyLayout(
      sessions, listedCount: pages.visibleCount, scope: .project(project.id))
    return ProjectFolder(
      project: project, sessions: sessions,
      isExpanded: Binding(
        get: { expandedProjects.contains(project.id) },
        set: { expanded in
          var ids = expandedProjects
          if expanded { ids.insert(project.id) } else { ids.remove(project.id) }
          setExpandedProjects(ids)
          // Each expansion starts at one page, as the web's.
          if !expanded { shownInProject[project.id] = nil }
        }),
      pages: pages,
      menu: ProjectMenu(
        project: project, projects: state.projects,
        sort: state.sort(of: .project(project.id)), actions: actions,
        rename: {
          projectName = project.name
          projectPrompt = .rename(project)
        },
        confirmDelete: { confirmingProjectDelete = project }),
      drop: { item in drop(item, on: .project(project)) },
      row: { session, box in
        let place = rowPlace(session, in: project, layout: layout)
        row(session, target: place.target, family: place.family, box: box)
      },
      folderMarker: expandedProjects.contains(project.id) ? nil : marker(sessions[...]),
      moreMarker: pages.visibleCount < sessions.count
        ? marker(sessions.dropFirst(pages.visibleCount)) : nil, listed: layout.visible)
  }

  /// A session's row; a nested member is no drag source, its family moving with its head.
  private func row(
    _ session: SessionSummary, target: SidebarDropTarget?, family: SessionRowFamily,
    box: SidebarBoxPart? = nil
  ) -> some View {
    let destination = state.destination(of: session)
    let isOpen = selection == destination
    return SidebarLiveRow(
      snapshot: state.rowContent(session), live: actions.live, showsDraft: !isOpen
    ) { row in
      sessionRow(row, reorder: dropHandler.move(in: target?.group), family: family)
    }
    .tag(destination)
    .sidebarSelection(
      bulk.isActive ? bulk.ids.contains(session.id) : isOpen, indent: family.indent, box: box
    )
    .sidebarDraggable(
      family.movesWithFamily(session) ? nil : SidebarDragItem.session(session.id).payload
    )
    .sidebarDropTarget { item in target.map { drop(item, on: $0) } ?? false }
  }

  /// A row and its menu for the session as it is now.
  private func sessionRow(
    _ row: SidebarRowContent, reorder: SessionRowMove?, family: SessionRowFamily
  ) -> some View {
    let session = row.session
    var sessionActions = state.rowActions(session, actions.sessions)
    if let move = sessionActions.moveToProject {
      // The session shows in the folder it moved to, not hidden in a collapsed one.
      sessionActions.moveToProject = { session, project in
        move(session, project)
        if let project { setExpandedProjects(expandedProjects.union([project.id])) }
      }
    }
    let menu = SessionRowMenu(
      session: session, isUnread: row.isUnread, isShared: row.info.isShared,
      pinLimitReached: state.pinnedCount >= state.pinLimit,
      projects: state.projects, actions: sessionActions,
      rename: {
        renameText = session.title
        renaming = session
      },
      confirmDelete: { confirmingDelete = session },
      confirmLeave: { confirmingLeave = session },
      confirmStop: { confirmingStop = session },
      project: state.projects.first { $0.sessionIds.contains(session.id) },
      newProject: actions.createProject.map { _ in
        {
          projectName = ""
          projectPrompt = .create(moving: session)
        }
      }, shareUnavailableReason: sessionActions.shareUnavailableReason, move: reorder,
      nests: nestDestinations(for: session))
    return SessionRow(
      session: session, info: row.info, isUnread: row.isUnread, attention: row.requests ?? 0,
      details: state.display.details, harnessIcon: harnessIcon,
      now: state.list.now, menu: menu,
      isSelecting: bulk.isActive, isChecked: bulk.ids.contains(session.id),
      inlineRename: inlineEdit.session?.id == session.id
        ? SidebarInlineEdit.field($inlineEdit, rename: actions.sessions.rename) : nil,
      beginInlineRename: canRenameInline(session, info: row.info)
        ? { inlineEdit.begin(session) } : nil, family: family
    )
    #if os(iOS)
      .modifier(SessionSwipeActions(session: session, isUnread: row.isUnread, menu: menu))
    #endif
  }

  /// A double-click on one session row renames it in place.
  private func renameOnDoubleClick(_ destinations: Set<SidebarDestination>) {
    guard destinations.count == 1, let id = destinations.first?.sessionID,
      let session = current(id),
      canRenameInline(session, info: state.rowInfo[id] ?? SessionRowInfo())
    else { return }
    inlineEdit.begin(session)
  }

  /// The owner only, as the web, and never while selecting.
  private func canRenameInline(_ session: SessionSummary, info: SessionRowInfo) -> Bool {
    actions.sessions.rename != nil && session.canRename && !info.isShared && !bulk.isActive
  }

  private func drop(_ item: SidebarDragItem, on target: SidebarDropTarget?) -> Bool {
    guard let target, !bulk.isActive else { return false }
    return dropHandler.drop(item, on: target)
  }
}
