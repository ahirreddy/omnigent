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
  @State private var confirmingLeave: SessionSummary?
  @State private var expandedProjects: Set<String> = []
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
    List(selection: $selection) {
      navigation
      ForEach(SidebarSections.sections(state)) { section in
        sessionSection(section)
      }
      emptyState
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
        guard let id = selection?.sessionID, let session = summary(id), session.canArchive,
          let setArchived = actions.sessions.setArchived
        else { return }
        setArchived(session, !session.isArchived)
      }
    #endif
    .alert(
      "Rename Session",
      isPresented: Binding(
        get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    ) {
      TextField("Title", text: $renameText)
      Button("Rename") {
        if let renaming, let rename = actions.sessions.rename {
          rename(renaming, renameText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        renaming = nil
      }
      .disabled(
        renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renameText.count > 120
      )
      Button("Cancel", role: .cancel) { renaming = nil }
    }
    .confirmationDialog(
      "Delete this session?",
      isPresented: Binding(
        get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
      presenting: confirmingDelete
    ) { session in
      Button("Delete", role: .destructive) { actions.sessions.delete?(session) }
    } message: { _ in
      Text("This permanently deletes the session and its history.")
    }
    .modifier(
      ProjectDialogs(
        prompt: $projectPrompt, name: $projectName, confirmingDelete: $confirmingProjectDelete,
        actions: actions)
    )
    .confirmationDialog(
      "Leave this session?",
      isPresented: Binding(
        get: { confirmingLeave != nil }, set: { if !$0 { confirmingLeave = nil } }),
      presenting: confirmingLeave
    ) { session in
      Button("Leave", role: .destructive) { actions.sessions.leave?(session) }
    } message: { _ in
      Text("You lose access until someone shares it with you again.")
    }
  }

  @ViewBuilder private var navigation: some View {
    Label("New session", systemImage: "plus.bubble")
      .neutralSidebarIcon()
      .fontWeight(.medium)
      .tag(SidebarDestination.newSession)
      .sidebarSelection(selection == .newSession)
      .accessibilityIdentifier("sidebar-new-session")
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
          row(session)
        }
      }
    } header: {
      HStack {
        Text(section.title)
          .font(Theme.Typography.section)
          .foregroundStyle(Theme.mutedText)
          .textCase(nil)
        Spacer()
        if section.isProjects, actions.createProject != nil {
          Button("New project", systemImage: "plus") {
            projectName = ""
            projectPrompt = .create(moving: nil)
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .help("New project")
          .accessibilityIdentifier("sidebar-new-project")
        }
        if section.showsDisplayMenu, let setDisplay = actions.setDisplay {
          DisplayMenu(options: state.display, set: setDisplay)
        }
      }
    }
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

  @ViewBuilder private var emptyState: some View {
    if state.list.sessions.isEmpty, state.projects.isEmpty {
      switch state.list.phase {
      case .loading:
        ProgressView("Loading sessions\u{2026}")
      case .loaded, .failed:
        if !searchText.isEmpty {
          ContentUnavailableView.search(text: searchText)
        } else {
          ContentUnavailableView(
            state.display.show == .archived ? "No archived sessions" : "No sessions",
            systemImage: "bubble.left.and.bubble.right"
          )
          .font(.callout)
          .listRowSeparator(.hidden)
        }
      }
    }
  }

  @ViewBuilder private var bottomBars: some View {
    VStack(spacing: 0) {
      if let undo = state.undo {
        UndoBar(banner: undo, actions: actions)
      }
      if case .failed(let message) = state.list.phase {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(Theme.failure)
            .accessibilityHidden(true)
          Text(message).font(.caption).lineLimit(3).textSelection(.enabled)
          Spacer(minLength: 4)
          if let retry = actions.sessions.retry {
            Button("Retry", action: retry).controlSize(.small)
              .accessibilityIdentifier("session-list-retry")
          }
        }
        .padding(Theme.Spacing.medium)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session-list-error")
      }
    }
    .frame(minWidth: 0, maxWidth: .infinity)
  }
}

extension SidebarView {
  private func projectGroup(_ project: SessionProject) -> some View {
    let sessions = project.sessionIds.compactMap(summary)
    let showsAll = showsAllInProject.contains(project.id)
    return DisclosureGroup(
      isExpanded: Binding(
        get: { expandedProjects.contains(project.id) },
        set: { expanded in
          if expanded {
            expandedProjects.insert(project.id)
          } else {
            expandedProjects.remove(project.id)
          }
        })
    ) {
      if sessions.isEmpty {
        Text("No sessions").foregroundStyle(.secondary)
      }
      ForEach(showsAll ? sessions : Array(sessions.prefix(5))) { session in
        row(session)
      }
      if sessions.count > 5 {
        Button(showsAll ? "Show less" : "Show more") {
          if showsAll {
            showsAllInProject.remove(project.id)
          } else {
            showsAllInProject.insert(project.id)
          }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
      }
    } label: {
      Label {
        Text(project.name)
      } icon: {
        if let icon = project.icon {
          Text(icon)
        } else {
          Image(systemName: "folder")
        }
      }
      .contextMenu { projectMenu(project) }
      .accessibilityIdentifier("sidebar-project-\(project.id)")
    }
  }

  @ViewBuilder private func projectMenu(_ project: SessionProject) -> some View {
    if actions.renameProject != nil {
      Button("Rename\u{2026}", systemImage: "pencil") {
        projectName = project.name
        projectPrompt = .rename(project)
      }
    }
    if actions.deleteProject != nil {
      Button("Delete project\u{2026}", systemImage: "trash", role: .destructive) {
        confirmingProjectDelete = project
      }
    }
  }

  private func row(_ session: SessionSummary) -> some View {
    let info = state.rowInfo[session.id] ?? SessionRowInfo()
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
      now: now, menu: menu
    )
    .tag(SidebarDestination.session(session.id))
    .sidebarSelection(selection == .session(session.id))
    #if os(iOS)
      .swipeActions(edge: .leading) {
        if let setUnread = actions.sessions.setUnread {
          Button(
            isUnread ? "Read" : "Unread", systemImage: isUnread ? "envelope.open" : "envelope.badge"
          ) {
            setUnread(session, !isUnread)
          }
          .tint(Theme.unread)
        }
        if actions.sessions.setPinned != nil, session.canPin {
          Button(session.isPinned ? "Unpin" : "Pin", systemImage: "pin") { menu.togglePin() }
          .tint(.orange)
        }
      }
      .swipeActions(edge: .trailing) {
        if let setArchived = actions.sessions.setArchived, session.canArchive {
          Button(session.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox") {
            setArchived(session, !session.isArchived)
          }
          .tint(.indigo)
        }
      }
    #endif
  }
}
