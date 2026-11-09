public import SwiftUI

/// The sidebar, structured like the web's: the wordmark with a server switcher, New session,
/// Inbox and Canvas, the native quick filters (Running, Needs you), then Pinned, Projects,
/// Shared and Sessions with the web's filter and display menu. Native list selection, keyboard
/// navigation, context menus, hover pin, swipe actions and Delete-to-archive.
public struct SidebarView: View {
  private let state: SidebarViewState
  @Binding private var selection: SidebarDestination?
  @Binding private var searchText: String
  private let actions: SidebarActions

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
  @State private var behavior = SidebarBehavior()

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

  private var now: Date { state.list.now ?? Date() }

  /// The sidebar.
  public var body: some View {
    List(selection: listSelection) {
      SidebarNavigationRows(state: state, selection: selection, actions: actions)
      let sections = SidebarSections.sections(behavior.holding(state))
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
    .onChange(of: state.list.sessions.filter(\.isPinned).map(\.id)) { old, new in
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
    .safeAreaInset(edge: .bottom, spacing: 0) { bottomBars }
    #if os(macOS)
      .contextMenu(forSelectionType: SidebarDestination.self) { _ in
        EmptyView()
      } primaryAction: { destinations in
        renameOnDoubleClick(destinations)
      }
      .onDeleteCommand {
        guard !bulk.isActive, let id = selection?.sessionID, let session = summary(id),
          session.canArchive, let setArchived = actions.sessions.setArchived
        else { return }
        setArchived(session, !session.isArchived)
      }
      .onExitCommand { if bulk.isActive { bulk.end() } }
    #endif
    .onChange(of: state.display.show) { bulk.end() }
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
        actions: actions)
    )
  }

  /// The list's selection. While selecting sessions a click checks the row instead (Shift
  /// extends from the last one), and the list shows no selection of its own.
  private var listSelection: Binding<SidebarDestination?> {
    Binding(
      get: { bulk.isActive ? nil : selection },
      set: { destination in
        guard bulk.isActive else {
          selection = destination
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
        ForEach(section.sessions) { session in
          row(session, target: dropHandler.rowTarget(session, in: section))
        }
      }
    } header: {
      HStack {
        Text(section.title)
          .font(Theme.Typography.section)
          .foregroundStyle(Theme.mutedText)
          .textCase(nil)
        if let marker = hiddenMarker(section) {
          SidebarMarkerView(marker: marker)
        }
        if section.isProjects, !bulk.isActive {
          projectsHeaderButtons
        }
        if section.showsDisplayMenu {
          sessionsHeaderButtons
          if let setDisplay = actions.setDisplay {
            DisplayMenu(
              options: state.display, showsShared: state.showsSharedScope, set: setDisplay)
          }
        }
        // After the controls: the list's disclosure arrow takes the trailing edge on hover.
        Spacer()
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .sidebarDropTarget { item in drop(item, on: dropHandler.sectionTarget(section)) }
    }
  }

  /// New session and Select sessions, on the Sessions header (the web's header actions).
  @ViewBuilder private var sessionsHeaderButtons: some View {
    if !bulk.isActive {
      if let newSession = actions.sessions.newSession {
        Button("New session", systemImage: "plus.bubble", action: newSession)
          .help("New session")
          .accessibilityIdentifier("sessions-new-session")
      }
      Button("Select sessions", systemImage: "checklist") { bulk.begin() }
        .help("Select sessions")
        .accessibilityIdentifier("toggle-selection-mode")
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
  private func hiddenMarker(_ section: SidebarSections.Section) -> SidebarMarker? {
    guard collapsedTitles.contains(section.title) else { return nil }
    let sessions =
      section.isProjects
      ? state.projects.flatMap(\.sessionIds).compactMap(summary) : section.sessions
    return SidebarMarker.strongest(sessions, list: state.list, rowInfo: state.rowInfo)
  }

  private func summary(_ id: String) -> SessionSummary? {
    state.list.sessions.first { $0.id == id }
  }

  @ViewBuilder private var bottomBars: some View {
    VStack(spacing: 0) {
      if bulk.isActive {
        BulkActionBar(
          selected: state.list.sessions.filter { bulk.ids.contains($0.id) }, state: state,
          actions: actions, exit: { bulk.end() }, clear: { bulk.clear() },
          confirmDelete: { confirmingBulkDelete = $0 })
      }
      if let undo = state.undo {
        UndoBar(banner: undo, actions: actions)
      }
      if case .failed(let message) = state.list.phase {
        SessionListErrorBar(message: message, retry: actions.sessions.retry)
      }
    }
    .frame(minWidth: 0, maxWidth: .infinity)
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
    let sessions = project.sessionIds.compactMap(summary)
    let marker = { (rows: ArraySlice<SessionSummary>) in
      SidebarMarker.strongest(rows, list: state.list, rowInfo: state.rowInfo)
    }
    let pages = ProjectFolderPages(
      project: project, sessions: sessions, paging: state.paging,
      shown: shownInProject[project.id] ?? 0, selectedID: selection?.sessionID,
      load: actions.loadProjectPage, setShown: { shownInProject[project.id] = $0 })
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
        project: project, projects: state.projects, actions: actions,
        rename: {
          projectName = project.name
          projectPrompt = .rename(project)
        },
        confirmDelete: { confirmingProjectDelete = project }),
      drop: { item in drop(item, on: .project(project)) },
      row: { session in row(session, target: .project(project)) },
      folderMarker: expandedProjects.contains(project.id) ? nil : marker(sessions[...]),
      moreMarker: pages.visibleCount < sessions.count
        ? marker(sessions.dropFirst(pages.visibleCount)) : nil)
  }

  private func row(_ session: SessionSummary, target: SidebarDropTarget?) -> some View {
    var info = state.rowInfo[session.id] ?? SessionRowInfo()
    // The open session's composer already shows its draft.
    info.hasDraft = info.hasDraft && selection != .session(session.id)
    let isUnread = state.list.unreadIds.contains(session.id)
    var sessionActions = actions.sessions
    if let move = sessionActions.moveToProject {
      // The session shows in the folder it moved to, not hidden in a collapsed one.
      sessionActions.moveToProject = { session, project in
        move(session, project)
        if let project { setExpandedProjects(expandedProjects.union([project.id])) }
      }
    }
    let menu = SessionRowMenu(
      session: session, isUnread: isUnread, isShared: info.isShared,
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
      }, shareUnavailableReason: sessionActions.shareUnavailableReason)
    return SessionRow(
      session: session, info: info, isUnread: isUnread,
      attention: state.list.attentionCounts[session.id] ?? 0, details: state.display.details,
      now: now, menu: menu, isSelecting: bulk.isActive, isChecked: bulk.ids.contains(session.id),
      inlineRename: inlineEdit.session?.id == session.id
        ? SidebarInlineEdit.field($inlineEdit, rename: actions.sessions.rename) : nil,
      beginInlineRename: canRenameInline(session, info: info) ? { inlineEdit.begin(session) } : nil
    )
    .tag(SidebarDestination.session(session.id))
    .sidebarSelection(
      bulk.isActive ? bulk.ids.contains(session.id) : selection == .session(session.id)
    )
    .draggable(SidebarDragItem.session(session.id).payload)
    .sidebarDropTarget { item in target.map { drop(item, on: $0) } ?? false }
    .modifier(SessionSwipeActions(session: session, isUnread: isUnread, menu: menu))
  }

  /// A double-click on one session row renames it in place.
  private func renameOnDoubleClick(_ destinations: Set<SidebarDestination>) {
    guard destinations.count == 1, let id = destinations.first?.sessionID,
      let session = summary(id),
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

  private var dropHandler: SidebarDropHandler { SidebarDropHandler(state: state, actions: actions) }
}
