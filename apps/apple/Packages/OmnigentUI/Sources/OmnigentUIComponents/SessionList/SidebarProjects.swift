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
  /// The server offers project boards, so a click on the row may open the folder's board.
  var offersBoard = false
  /// Its board is shown.
  var isBoardShown = false
}

extension ProjectFolderPages {
  /// A folder's rows and pages: Show more lists five more and reads the next server page once
  /// the loaded rows run out.
  @MainActor init(
    project: SessionProject, sessions: [SessionSummary], paging: SidebarPaging, shown: Int,
    selection: SidebarDestination?, boards: Bool = false,
    load: (@MainActor (SessionProject) -> Void)?, setShown: @escaping (Int) -> Void
  ) {
    let selectedID = selection?.sessionID
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
      load: loadPage, offersBoard: boards, isBoardShown: selection == .project(project.id))
  }
}

/// One project folder, as the web's: the label with New session in project and the project
/// menu on hover (and in the context menu), then its sessions, five until Show more. A box drawn
/// around the folder's rows groups them; they sit where sessions outside a folder do.
struct ProjectFolder<Row: View>: View {
  let project: SessionProject
  let sessions: [SessionSummary]
  @Binding var isExpanded: Bool
  let pages: ProjectFolderPages
  let menu: ProjectMenu
  let drop: (SidebarDragItem) -> Bool
  /// A session's row, with its part of the folder's box.
  @ViewBuilder let row: (SessionSummary, SidebarBoxPart) -> Row
  /// The strongest state of its sessions, while it is collapsed.
  var folderMarker: SidebarHiddenMarker?
  /// The strongest state of the sessions under Show more.
  var moreMarker: SidebarHiddenMarker?
  /// The rows its page lists, without the members of collapsed families.
  let listed: [SessionSummary]

  @State private var isHovered = false
  /// With boards offered and on, a click on the row opens the project's board, as the list's
  /// selection; only the expand button shows or hides its sessions (the web's project row).
  @AppStorage(InterfacePreferences.projectBoardKey) private var boardsOn = true
  @Environment(\.defaultMinListRowHeight) private var rowHeight

  var body: some View {
    folderRow
    if isExpanded {
      if sessions.isEmpty {
        Group {
          if pages.isLoading || (pages.load != nil && !pages.isLoaded) {
            ProgressView().controlSize(.small)
          } else {
            Text("No sessions").foregroundStyle(.secondary)
          }
        }
        .padding(.leading, SessionFamilyMetrics.folderNoteIndent)
        .listRowBackground(SidebarProjectBox(part: .bottom))
      }
      ForEach(listed) { session in
        row(session, session.id == listed.last?.id && !showsMore ? .bottom : .middle)
      }
      if showsMore {
        showMore.listRowBackground(SidebarProjectBox(part: .bottom))
      }
    }
  }

  /// The folder's own row: its name, its hover buttons or hidden marker, and its expand button.
  private var folderRow: some View {
    HStack(spacing: Theme.Spacing.tiny) {
      HStack(spacing: Theme.Spacing.small) {
        folderIcon.frame(width: SessionFamilyMetrics.markWidth)
        Text(project.name).lineLimit(1)
      }
      Spacer(minLength: 4)
      if isHovered {
        hoverButtons
      } else {
        folderMarker
      }
      expandButton
    }
    // Flush left, where a family's chevron starts, so a folder reads apart from its sessions.
    .contentShape(Rectangle())
    .modifier(
      ProjectFolderClick(
        project: project, opensBoard: pages.offersBoard && boardsOn,
        isBoardShown: pages.isBoardShown, box: isExpanded ? .top : .single, toggle: toggle)
    )
    .onHover { isHovered = $0 }
    .contextMenu { menu.items }
    .draggable(SidebarDragItem.project(project.id).payload)
    .sidebarDropTarget(drop)
    // One element for the folder, around its name, hover buttons and expand button.
    .accessibilityElement(children: .contain)
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

  private func toggle() {
    withAnimation { isExpanded.toggle() }
  }

  /// Shows or hides the folder's sessions: an expand or collapse symbol at the row's end, not a
  /// chevron, so it reads apart from the chevron that leads a session family.
  private var expandButton: some View {
    let label = isExpanded ? "Collapse project" : "Expand project"
    return Button(action: toggle) {
      Image(
        systemName: isExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical"
      )
      .contentTransition(.symbolEffect(.replace))
      .frame(width: SessionFamilyMetrics.markWidth, height: SessionFamilyMetrics.markWidth)
      .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .help(label)
    .accessibilityLabel(label)
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    .accessibilityIdentifier("sidebar-project-toggle-\(project.id)")
  }

  /// Show more follows the listed rows: some are left to show, here or on the server.
  private var showsMore: Bool {
    pages.visibleCount < sessions.count || (pages.hasMore && !sessions.isEmpty)
  }

  /// The folder's emoji, else a folder; decorative, as its name says which folder it is.
  @ViewBuilder private var folderIcon: some View {
    if let icon = project.icon {
      Text(icon).accessibilityHidden(true)
    } else {
      // The window's accent: the theme's, or the system's under Use system accent.
      Image(systemName: "folder").foregroundStyle(ThemeColor.controlTint)
        .accessibilityHidden(true)
    }
  }

  private var showMore: some View {
    // Waiting on the next server page, with no loaded rows left to reveal.
    let isWaiting = pages.isLoading && pages.visibleCount >= sessions.count
    let title = isWaiting ? "Loading\u{2026}" : "Show more"
    // The click area reaches the row's edges above and below the text; the rows beside it
    // clip what reaches past.
    let reach = rowHeight / 2
    return Button(action: pages.showMore) {
      HStack {
        Text(title)
        Spacer(minLength: 4)
        // Drawn only: the button takes its clicks and says its state.
        moreMarker?.inButton()
      }
      .padding(.leading, SessionFamilyMetrics.folderNoteIndent)
      .padding(.vertical, reach)
      .contentShape(Rectangle())
    }
    .padding(.vertical, -reach)
    .help(moreMarker?.help ?? "")
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .disabled(isWaiting)
    .accessibilityLabel(
      [title, moreMarker?.accessibilityText].compactMap(\.self).joined(separator: ", ")
    )
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

/// What a click on a folder's row does: without boards it shows or hides the folder's sessions,
/// as the web's project header; with them the row is the list's selection for the project's
/// board, drawn selected while the board shows.
private struct ProjectFolderClick: ViewModifier {
  let project: SessionProject
  let opensBoard: Bool
  let isBoardShown: Bool
  let box: SidebarBoxPart
  let toggle: () -> Void

  func body(content: Content) -> some View {
    if opensBoard {
      content
        .tag(SidebarDestination.project(project.id))
        .sidebarSelection(isBoardShown, box: box)
    } else {
      content
        .onTapGesture(perform: toggle)
        .accessibilityAddTraits(.isButton)
        .listRowBackground(SidebarProjectBox(part: box))
    }
  }
}

/// A project's menu in the web's order: New session, Rename, Project settings, Move, Delete;
/// and how its sessions sort.
struct ProjectMenu {
  let project: SessionProject
  let projects: [SessionProject]
  /// How its sessions sort now.
  let sort: SessionGroupSort
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
    if let setSort = actions.setGroupSort {
      GroupSortPicker(sort: sort) { setSort(.project(project.id), $0) }
    }
    if let reorder = actions.reorderProjects, projects.count > 1 {
      MoveMenu(items: { projects }, id: project.id, save: reorder)
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
