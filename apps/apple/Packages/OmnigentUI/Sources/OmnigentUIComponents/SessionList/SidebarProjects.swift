import SwiftUI

/// The paging of one folder: its members are read from the server a page at a time (the web's
/// `?project=` read), and listed five more per Show more.
struct ProjectFolderPages {
  /// Rows listed.
  let visibleCount: Int
  /// Members left on the server.
  let hasMore: Bool
  let isLoading: Bool
  /// The first page was read.
  let isLoaded: Bool
  /// Reveal five more rows, reading the next page when the loaded ones run out.
  let showMore: () -> Void
  /// Read the folder's first page, or its next.
  let load: (() -> Void)?
}

extension ProjectFolderPages {
  /// A folder's rows and pages: Show more lists five more and reads the next server page once
  /// the loaded rows run out.
  @MainActor init(
    project: SessionProject, sessions: [SessionSummary], paging: SidebarPaging, shown: Int,
    selectedID: String?, load: (@MainActor (SessionProject) -> Void)?,
    setShown: @escaping (Int) -> Void
  ) {
    let selectedIndex = selectedID.flatMap { id in sessions.firstIndex { $0.id == id } }
    let visible = ProjectFolderPaging.visibleCount(
      count: sessions.count, shown: shown, selectedIndex: selectedIndex)
    let loadPage = load.map { load in { load(project) } }
    self.init(
      visibleCount: visible, hasMore: paging.projectsWithMore.contains(project.id),
      isLoading: paging.loadingProjects.contains(project.id),
      isLoaded: paging.loadedProjects.contains(project.id),
      showMore: {
        let next = visible + ProjectFolderPaging.pageSize
        setShown(next)
        if next > sessions.count { loadPage?() }
      },
      load: loadPage)
  }
}

/// One project folder, as the web's: the label with New session in project and the project
/// menu on hover (and in the context menu), then its sessions, five until Show more.
struct ProjectFolder<Row: View>: View {
  let project: SessionProject
  let sessions: [SessionSummary]
  @Binding var isExpanded: Bool
  let pages: ProjectFolderPages
  let menu: ProjectMenu
  let drop: (SidebarDragItem) -> Bool
  @ViewBuilder let row: (SessionSummary) -> Row
  /// The strongest state of its sessions, while it is collapsed.
  var folderMarker: SidebarHiddenMarker?
  /// The strongest state of the sessions under Show more.
  var moreMarker: SidebarHiddenMarker?

  @State private var isHovered = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      if sessions.isEmpty {
        if pages.isLoading || (pages.load != nil && !pages.isLoaded) {
          ProgressView().controlSize(.small)
        } else {
          Text("No sessions").foregroundStyle(.secondary)
        }
      }
      ForEach(sessions.prefix(pages.visibleCount)) { session in
        row(session)
      }
      if pages.visibleCount < sessions.count || (pages.hasMore && !sessions.isEmpty) {
        showMore
      }
    } label: {
      HStack(spacing: Theme.Spacing.tiny) {
        Label {
          Text(project.name).lineLimit(1)
        } icon: {
          if let icon = project.icon {
            Text(icon)
          } else {
            // The navigation rows' color, not the platform tint (system blue on iOS).
            Image(systemName: "folder").foregroundStyle(ThemeColor.primary)
          }
        }
        Spacer(minLength: 4)
        if isHovered {
          hoverButtons
        } else {
          folderMarker
        }
      }
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
      .contextMenu { menu.items }
      .draggable(SidebarDragItem.project(project.id).payload)
      .sidebarDropTarget(drop)
      .accessibilityActions {
        if let newSession = menu.actions.newSessionInProject {
          Button("New session in project") { newSession(project) }
        }
      }
      .accessibilityIdentifier("sidebar-project-\(project.id)")
      // An expanded folder reads its own first page, as the web's (collapsed ones cost nothing).
      .task(id: isExpanded && !pages.isLoaded) {
        if isExpanded, !pages.isLoaded { pages.load?() }
      }
    }
  }

  private var showMore: some View {
    // Waiting on the next server page, with no loaded rows left to reveal.
    let isWaiting = pages.isLoading && pages.visibleCount >= sessions.count
    return Button(action: pages.showMore) {
      HStack {
        Text(isWaiting ? "Loading\u{2026}" : "Show more")
        Spacer(minLength: 4)
        moreMarker
      }
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .disabled(isWaiting)
    .accessibilityIdentifier("project-show-more-\(project.id)")
  }

  @ViewBuilder private var hoverButtons: some View {
    HStack(spacing: Theme.Spacing.tiny) {
      if let newSession = menu.actions.newSessionInProject {
        Button("New session in \(project.name)", systemImage: "plus.bubble") {
          newSession(project)
        }
        .help("New session in project")
        .accessibilityIdentifier("project-new-session")
      }
      Menu {
        menu.items
      } label: {
        Label("Project actions", systemImage: "ellipsis")
      }
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Project actions")
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
  }
}

/// A project's menu in the web's order: New session, Rename, Project settings, Move, Delete.
struct ProjectMenu {
  let project: SessionProject
  let projects: [SessionProject]
  let actions: SidebarActions
  let rename: () -> Void
  let confirmDelete: () -> Void

  @ViewBuilder var items: some View {
    if let newSession = actions.newSessionInProject {
      Button("New session", systemImage: "plus.bubble") { newSession(project) }
    }
    if actions.renameProject != nil {
      Button("Rename project\u{2026}", systemImage: "pencil", action: rename)
    }
    if let settings = actions.openProjectSettings {
      Button("Project settings\u{2026}", systemImage: "slider.horizontal.3") { settings(project) }
    }
    if let reorder = actions.reorderProjects, projects.count > 1 {
      Menu("Move", systemImage: "arrow.up.arrow.down") {
        ForEach(ProjectMove.allCases) { move in
          let moved = SessionProject.moved(projects, id: project.id, move)
          Button(move.title) { reorder(moved) }
            .disabled(moved.isEmpty)
        }
      }
    }
    if actions.deleteProject != nil {
      Divider()
      Button("Delete project\u{2026}", systemImage: "trash", role: .destructive) {
        confirmDelete()
      }
    }
  }
}

/// The Projects header's "…" menu: Sort projects by, Expand all, Collapse all and Select
/// sessions, each shown only when it would do something.
struct ProjectsHeaderMenu: View {
  let state: SidebarViewState
  let actions: SidebarActions
  let expanded: Set<String>
  let setExpanded: (Set<String>) -> Void
  let selectSessions: () -> Void

  var body: some View {
    let ids = state.projects.map(\.id)
    let allExpanded = !ids.isEmpty && ids.allSatisfy(expanded.contains)
    let anyExpanded = ids.contains(where: expanded.contains)
    let hasSessions = state.projects.contains { !$0.sessionIds.isEmpty }
    if !ids.isEmpty {
      Menu {
        if let setSort = actions.setProjectSort {
          Picker(
            "Sort projects by",
            selection: Binding(
              get: { state.projectSort ?? .alphabetical },
              set: { sort in if sort != state.projectSort { setSort(sort) } })
          ) {
            ForEach(ProjectSort.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .disabled(state.projectSort == nil)
        }
        if !allExpanded {
          Button("Expand all", systemImage: "arrow.up.left.and.arrow.down.right") {
            setExpanded(expanded.union(ids))
          }
        }
        if anyExpanded {
          Button("Collapse all", systemImage: "arrow.down.right.and.arrow.up.left") {
            setExpanded(expanded.subtracting(ids))
          }
        }
        if hasSessions {
          Button("Select sessions", systemImage: "checklist", action: selectSessions)
        }
      } label: {
        Label("Project list actions", systemImage: "ellipsis")
      }
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Project list actions")
      .accessibilityIdentifier("project-list-actions")
    }
  }
}
