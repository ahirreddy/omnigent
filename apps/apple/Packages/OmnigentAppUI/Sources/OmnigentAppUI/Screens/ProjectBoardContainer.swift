import Foundation
import OmnigentCoreFFI
import OmnigentPlatform
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// A project's board over the session list: the core files the project's loaded sessions into
/// lanes and cards, its folder's pages load as the board shows, each card's reply preview is read
/// once per finished turn, and new sessions are outlined for a moment. With boards off (the
/// server or Settings), the project's New session page opens instead, as the web's project link.
struct ProjectBoardContainer: View {
  let session: ServerSession
  let folderID: String
  /// The sidebar's project and session actions, for the header's and cards' menus.
  let sidebarActions: SidebarActions
  /// The row details each card shows.
  let details: Set<SessionRowDetail>
  /// Opens a session in full.
  let open: @MainActor (String) -> Void
  /// Opens the project's full New session page (phones, and boards turned off).
  let newSession: @MainActor (SessionProject) -> Void
  /// A session's chat, for the quick view.
  let chat: (String) -> AnyView

  @State private var filter = ""
  @State private var isComposerShown = false
  @State private var arrivals = ProjectBoardArrivals()
  @State private var previews: ProjectBoardPreviews
  @AppStorage(InterfacePreferences.projectBoardKey) private var boardsOn = true
  @AppStorage(InterfacePreferences.harnessIconKey) private var harnessIcon = HarnessIconStyle
    .default
  @Environment(\.horizontalSizeClass) private var sizeClass

  init(
    session: ServerSession, folderID: String, sidebarActions: SidebarActions,
    details: Set<SessionRowDetail>, open: @escaping @MainActor (String) -> Void,
    newSession: @escaping @MainActor (SessionProject) -> Void,
    chat: @escaping (String) -> AnyView
  ) {
    self.session = session
    self.folderID = folderID
    self.sidebarActions = sidebarActions
    self.details = details
    self.open = open
    self.newSession = newSession
    self.chat = chat
    _previews = State(initialValue: ProjectBoardPreviews(core: session.connection.core))
  }

  private var list: SessionListStore { session.connection.sessionList }

  var body: some View {
    let offered = session.connection.pages?.offered
    if let project = list.projects.first(where: { projectFolderId(project: $0) == folderID }),
      let offered
    {
      let folder = ProjectBoardAdapter.folder(project)
      if offered.projectKanban, boardsOn {
        board(project, folder: folder)
      } else {
        LoadingCaption(title: "Opening the project\u{2026}")
          .task { newSession(folder) }
      }
    } else if offered == nil || (list.projectSortMode == nil && list.projectsError == nil) {
      LoadingCaption(title: "Opening the project\u{2026}")
    } else {
      ContentUnavailableView(
        "Project Not Found", systemImage: "folder.badge.questionmark",
        description: Text("It may have been renamed or deleted."))
    }
  }

  private func board(_ project: ProjectSummary, folder: SessionProject) -> some View {
    let board = ProjectBoardAdapter.board(
      project: project, list: list, filter: filter, previews: previews.previews)
    var state = ProjectBoardViewState(
      project: folder, columns: board.columns,
      phase: ProjectBoardAdapter.phase(folderID, paging: list.paging))
    let pages = list.paging.projects[folderID]
    state.hasMore = pages?.isLoaded == true && pages?.hasMoreAfter == true
    state.isLoadingMore = pages?.isLoaded == true && pages?.isLoading == true
    state.filter = filter
    state.details = details
    state.harnessIcon = harnessIcon
    state.arrivals = arrivals.highlighted
    state.quickViewID = session.tabs.quickViewSessionID
    state.isComposerShown = isComposerShown
    state.projects = list.projects.map(ProjectBoardAdapter.folder)
    let isLoaded = state.phase == .loaded
    return ProjectBoardView(
      state: state, actions: actions(project, folder: folder), projectActions: sidebarActions,
      composer: {
        NewSessionContainer(
          connection: session.connection,
          open: { _ in isComposerShown = false },
          project: project, isFloating: true)
      },
      quickView: { id in chat(id) }
    )
    .task(id: folderID) {
      list.paging.setBoardShown(folderID, true)
      if pages?.isLoaded != true { list.paging.loadProject(project) }
    }
    .onDisappear {
      list.paging.setBoardShown(folderID, false)
      session.tabs.quickViewSessionID = nil
    }
    // Counted from the first loaded board, whether or not its sessions changed as it loaded.
    .onChange(of: isLoaded ? board.sessionIDs : nil, initial: true) { _, ids in
      guard let ids else { return }
      arrivals.update(ids, sessions: board.sessions)
    }
  }

  private func actions(_ project: ProjectSummary, folder: SessionProject) -> ProjectBoardActions {
    let tabs = session.tabs
    let list = list
    let previews = previews
    let open = open
    var actions = ProjectBoardActions { id in
      tabs.quickViewSessionID = nil
      open(id)
    }
    if sizeClass != .compact {
      actions.quickView = { tabs.quickViewSessionID = $0 }
    }
    actions.setFilter = { filter = $0 }
    actions.accepts = { from, to in
      boardDropAction(from: ProjectBoardAdapter.lane(from), to: ProjectBoardAdapter.lane(to)) != nil
    }
    let setUnread: @MainActor (ProjectBoardCard, Bool) -> Void = { card, unread in
      for id in ProjectBoardAdapter.readMarks(card, unread: unread, list: list) {
        Task { await list.setUnread(id, unread) }
      }
    }
    actions.setUnread = setUnread
    actions.drop = { card, lane in
      let action = boardDropAction(
        from: ProjectBoardAdapter.lane(card.lane), to: ProjectBoardAdapter.lane(lane))
      guard let action else { return }
      setUnread(card, action == .markUnread)
    }
    actions.loadPreview = { card in
      await previews.load(
        card.id, updatedAt: card.session.updatedAt, isWorking: card.session.attention == .working)
    }
    actions.loadMore = { list.paging.loadProject(project) }
    actions.retry = { list.paging.loadProject(project) }
    // A phone has no room over the lanes; New session opens the project's full composer.
    let newSession = newSession
    if sizeClass == .compact {
      actions.toggleComposer = { newSession(folder) }
    } else {
      actions.toggleComposer = { withAnimation { isComposerShown.toggle() } }
    }
    actions.sessions = sidebarActions.sessions
    return actions
  }
}

/// The sessions that just joined a board, outlined for two seconds as the web's.
@Observable
final class ProjectBoardArrivals {
  /// The cards outlined now.
  private(set) var highlighted: Set<String> = []
  /// The sessions on the board since it first loaded.
  @ObservationIgnored private var known: Set<String> = []
  /// The board loaded: sessions new to it since are arrivals.
  @ObservationIgnored private var isLoaded = false

  /// How long a new card stays outlined.
  static let duration: Duration = .seconds(2)

  /// Notes the board's sessions now: those new to it and created within the last minute
  /// (the core's rule) are outlined. Sessions present when it first loads are not.
  func update(_ ids: Set<String>, sessions: [OmnigentCoreFFI.SessionSummary]) {
    guard isLoaded else {
      isLoaded = true
      known = ids
      return
    }
    let now = Int64(Date().timeIntervalSince1970)
    let arrived = Set(boardArrivals(sessions: sessions, knownIds: Array(known), now: now))
    known.formUnion(ids)
    guard !arrived.isEmpty else { return }
    highlighted.formUnion(arrived)
    Task { [weak self] in
      do {
        try await Task.sleep(for: Self.duration)
      } catch {
        // Cancelled with its window: nothing is left to outline.
        return
      }
      self?.highlighted.subtract(arrived)
    }
  }
}
