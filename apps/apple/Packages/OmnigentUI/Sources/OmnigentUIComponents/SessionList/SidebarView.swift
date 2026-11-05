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
  /// The session whose title is edited in place, and the text.
  @State private var inlineRenaming: SessionSummary?
  @State private var inlineText = ""
  /// Expanded project folders (they start collapsed), newline-separated, kept across launches.
  @AppStorage("omnigent:sidebar-expanded-projects") private var expandedProjectIDs = ""
  @State private var showsAllInProject: Set<String> = []
  @State private var projectPrompt: ProjectPrompt?
  @State private var projectName = ""
  @State private var confirmingProjectDelete: SessionProject?
  /// Collapsed section titles, newline-separated, kept across launches.
  @AppStorage("omnigent:sidebar-collapsed-sections") private var collapsedSections = ""

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
      navigation
      ForEach(SidebarSections.sections(state)) { section in
        sessionSection(section)
      }
      SidebarEmptyState(state: state, searchText: searchText)
    }
    .listStyle(.sidebar)
    .font(.callout)
    .environment(\.defaultMinListRowHeight, Theme.Control.sidebarRow)
    // On the list itself: further out it would also land on the header's wordmark and server
    // switcher, overriding their own identifiers.
    .accessibilityIdentifier("sidebar")
    .scrollContentBackground(.hidden)
    .themeSidebar()
    .searchable(text: $searchText, placement: .sidebar, prompt: "Search sessions")
    .safeAreaInset(edge: .top, spacing: 0) { SidebarHeader(state: state, actions: actions) }
    .safeAreaInset(edge: .bottom, spacing: 0) { bottomBars }
    #if os(macOS)
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
    let collapsed = Set(collapsedSections.split(separator: "\n").map(String.init))
    let open = SidebarSections.sections(state).filter { !collapsed.contains($0.title) }
    return open.flatMap { (section: SidebarSections.Section) -> [String] in
      guard section.isProjects else { return section.sessions.map(\.id) }
      return state.projects.filter { expandedProjects.contains($0.id) }.flatMap { project in
        showsAllInProject.contains(project.id)
          ? project.sessionIds
          : Array(project.sessionIds.prefix(ProjectFolder<EmptyView>.collapsedCount))
      }
    }
  }

  @ViewBuilder private var navigation: some View {
    Label("New session", systemImage: "plus.bubble")
      .neutralSidebarIcon()
      .fontWeight(.medium)
      .tag(SidebarDestination.newSession)
      .sidebarSelection(selection == .newSession)
      .accessibilityIdentifier("sidebar-new-session")
    if state.showsAutomations {
      Label("Automations", systemImage: "clock")
        .neutralSidebarIcon()
        .tag(SidebarDestination.automations)
        .sidebarSelection(selection == .automations)
        .accessibilityIdentifier("sidebar-automations")
    }
    Label("Inbox", systemImage: "tray")
      .neutralSidebarIcon()
      .badge(state.inboxCount)
      .tag(SidebarDestination.inbox)
      .sidebarSelection(selection == .inbox)
      .accessibilityIdentifier("sidebar-inbox")
    if state.showsCanvas {
      Label("Canvas", systemImage: "square.grid.2x2")
        .neutralSidebarIcon()
        .tag(SidebarDestination.canvas)
        .sidebarSelection(selection == .canvas)
        .accessibilityIdentifier("sidebar-canvas")
    }
    if state.showsUsage {
      Label("Usage", systemImage: "creditcard")
        .neutralSidebarIcon()
        .tag(SidebarDestination.usage)
        .sidebarSelection(selection == .usage)
        .accessibilityIdentifier("sidebar-usage")
    }
    if let setQuickFilter = actions.setQuickFilter {
      QuickFilterRow(
        filter: .running, isActive: state.quickFilter == .running,
        count: state.list.filterCounts[.running]
      ) {
        setQuickFilter(state.quickFilter == .running ? nil : .running)
      }
      QuickFilterRow(
        filter: .needsResponse, isActive: state.quickFilter == .needsResponse,
        count: state.list.filterCounts[.needsResponse]
      ) {
        setQuickFilter(state.quickFilter == .needsResponse ? nil : .needsResponse)
      }
    }
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
        Spacer()
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

  /// Whether a section is expanded; collapsing one is remembered.
  private func expansion(of title: String) -> Binding<Bool> {
    Binding(
      get: { !collapsedSections.split(separator: "\n").contains(Substring(title)) },
      set: { expanded in
        var titles = collapsedSections.split(separator: "\n").map(String.init)
        titles.removeAll { $0 == title }
        if !expanded { titles.append(title) }
        collapsedSections = titles.joined(separator: "\n")
      })
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
  private var expandedProjects: Set<String> {
    Set(expandedProjectIDs.split(separator: "\n").map(String.init))
  }

  private func setExpandedProjects(_ ids: Set<String>) {
    let text = ids.sorted().joined(separator: "\n")
    if text != expandedProjectIDs { expandedProjectIDs = text }
  }

  private func projectGroup(_ project: SessionProject) -> some View {
    ProjectFolder(
      project: project, sessions: project.sessionIds.compactMap(summary),
      isExpanded: Binding(
        get: { expandedProjects.contains(project.id) },
        set: { expanded in
          var ids = expandedProjects
          if expanded { ids.insert(project.id) } else { ids.remove(project.id) }
          setExpandedProjects(ids)
        }),
      showsAll: Binding(
        get: { showsAllInProject.contains(project.id) },
        set: { showsAll in
          if showsAll {
            showsAllInProject.insert(project.id)
          } else {
            showsAllInProject.remove(project.id)
          }
        }),
      menu: ProjectMenu(
        project: project, projects: state.projects, actions: actions,
        rename: {
          projectName = project.name
          projectPrompt = .rename(project)
        },
        confirmDelete: { confirmingProjectDelete = project }),
      drop: { item in drop(item, on: .project(project)) },
      row: { session in row(session, target: .project(project)) })
  }

  private func row(_ session: SessionSummary, target: SidebarDropTarget?) -> some View {
    var info = state.rowInfo[session.id] ?? SessionRowInfo()
    // The open session's composer already shows its draft.
    info.hasDraft = info.hasDraft && selection != .session(session.id)
    let isUnread = state.list.unreadIds.contains(session.id)
    let menu = SessionRowMenu(
      session: session, isUnread: isUnread, isShared: info.isShared,
      pinLimitReached: state.pinnedCount >= state.pinLimit,
      projects: state.projects, actions: actions.sessions,
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
      })
    return SessionRow(
      session: session, info: info, isUnread: isUnread,
      attention: state.list.attentionCounts[session.id] ?? 0, details: state.display.details,
      now: now, menu: menu, isSelecting: bulk.isActive, isChecked: bulk.ids.contains(session.id),
      inlineRename: inlineRenaming?.id == session.id ? inlineRename : nil,
      beginInlineRename: canRenameInline(session, info: info)
        ? {
          inlineText = session.title
          inlineRenaming = session
        } : nil
    )
    .tag(SidebarDestination.session(session.id))
    .sidebarSelection(
      bulk.isActive ? bulk.ids.contains(session.id) : selection == .session(session.id)
    )
    .draggable(SidebarDragItem.session(session.id).payload)
    .sidebarDropTarget { item in target.map { drop(item, on: $0) } ?? false }
    .modifier(SessionSwipeActions(session: session, isUnread: isUnread, menu: menu))
  }

  /// Double-click renames in place, as the web: the owner only, never while selecting.
  private func canRenameInline(_ session: SessionSummary, info: SessionRowInfo) -> Bool {
    actions.sessions.rename != nil && session.canRename && !info.isShared && !bulk.isActive
  }

  private var inlineRename: InlineRename {
    InlineRename(
      text: $inlineText,
      commit: {
        guard let session = inlineRenaming else { return }
        inlineRenaming = nil
        let title = inlineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != session.title,
          title.count <= SessionDialogs.maxTitleLength
        else { return }
        actions.sessions.rename?(session, title)
      },
      cancel: { inlineRenaming = nil })
  }

  private func drop(_ item: SidebarDragItem, on target: SidebarDropTarget?) -> Bool {
    guard let target, !bulk.isActive else { return false }
    return dropHandler.drop(item, on: target)
  }

  private var dropHandler: SidebarDropHandler { SidebarDropHandler(state: state, actions: actions) }
}
