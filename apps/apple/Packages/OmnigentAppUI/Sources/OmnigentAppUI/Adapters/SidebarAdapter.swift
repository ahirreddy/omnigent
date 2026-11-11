import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Builds the sidebar's view state from the session list. Ordering, search and filtering stay the
/// core's (its session index); every attention glyph and count comes from the list's shared
/// attention model (`SessionListStore.attention(of:)` and `attentionTotals`), so the row, the
/// Running and Needs you counts and the Inbox badge agree with the Dock and menu bar.
enum SidebarAdapter {
  /// The sidebar's view state. It reads the list's rows and marks without observing them
  /// (`SessionListStore.contents`): a view that draws from it reads `placementRevision`, and
  /// each row reads its own session through ``live(_:)``.
  /// - Parameters:
  ///   - list: The session list.
  ///   - display: The user's display options.
  ///   - server: The connected server, offered in the server switcher.
  ///   - servers: Other servers the switcher offers.
  /// - Returns: The state.
  static func state(
    list: SessionListStore, display: SessionDisplayOptions, server: ConnectedServer?,
    servers: [ServerChoice] = []
  ) -> SidebarViewState {
    let contents = list.contents
    let badges = counts(contents.totals)
    let pending = contents.attention.compactMapValues(requests)
    let filter = OmnigentUIComponents.SessionFilter(list.filter)
    let layout = layout(
      sessions: contents.visible, projects: list.projects, display: display,
      members: list.members, isOwned: list.isOwned)
    let idle = SessionAttention(state: .idle, requests: 0)
    let listState = SessionListViewState(
      sessions: layout.sessions.map {
        OmnigentUIComponents.SessionSummary($0, attention: contents.attention[$0.id] ?? idle)
      },
      filter: filter, unreadIds: contents.unreadIDs, attentionCounts: pending,
      filterCounts: badges.filters, phase: phase(list))
    let current = server.map(ServerChoice.init)
    var choices = current.map { [$0] } ?? []
    choices += servers.filter { choice in choice.id != current?.id }
    var state = SidebarViewState(
      list: listState,
      rowInfo: Dictionary(
        layout.sessions.map { session in
          let info = rowInfo(
            session, isOwned: list.isOwned(session),
            environments: list.hostEnvironments,
            hasDraft: contents.draftSessionIDs.contains(session.id))
          return (session.id, info)
        },
        uniquingKeysWith: { first, _ in first }),
      projects: layout.projects, inboxCount: badges.inbox, showsCanvas: false,
      display: display, quickFilter: filter == .all || filter == .archived ? nil : filter,
      servers: choices, currentServerID: current?.id)
    state.paging = paging(list.paging)
    return state
  }

  /// The Inbox badge and the quick filters' counts; only those two filters show one.
  static func counts(_ totals: AttentionTotals) -> SidebarCounts {
    SidebarCounts(
      inbox: Int(totals.sessionsNeedingYou),
      filters: [.running: Int(totals.working), .needsResponse: Int(totals.sessionsNeedingYou)])
  }

  /// The decisions a row's Needs you capsule counts; `nil` for a session that needs none.
  static func requests(_ attention: SessionAttention) -> Int? {
    attention.state == .needsYou ? Int(attention.requests) : nil
  }

  /// The sidebar's readers of `list` as it is now. Each reads one session, or the totals, so
  /// the view that calls one is drawn again for that session or those totals alone.
  static func live(_ list: SessionListStore) -> SidebarLive {
    SidebarLive(
      row: { id, showsDraft in row(id, list: list, showsDraft: showsDraft) },
      counts: { counts(list.attentionTotals) })
  }

  /// One session's row from the list; `nil` for a session it does not have.
  static func row(_ id: String, list: SessionListStore, showsDraft: Bool) -> SidebarRowContent? {
    guard let session = list.session(id) else { return nil }
    let attention = list.attention(of: id)
    let info = rowInfo(
      session, isOwned: list.isOwned(session), environments: list.hostEnvironments,
      hasDraft: showsDraft && list.hasDraft(id))
    return SidebarRowContent(
      session: OmnigentUIComponents.SessionSummary(session, attention: attention), info: info,
      isUnread: list.isUnread(id), requests: requests(attention))
  }

  /// Load more and each folder's pages.
  static func paging(_ paging: SessionListPaging) -> SidebarPaging {
    let projects = paging.projects
    return SidebarPaging(
      hasMore: paging.hasMore, isLoading: paging.isLoading,
      loadedProjects: Set(projects.filter { $0.value.isLoaded }.keys),
      projectsWithMore: Set(projects.filter { $0.value.isLoaded && $0.value.hasMore }.keys),
      loadingProjects: Set(projects.filter { $0.value.isLoading }.keys))
  }

  /// The sessions and folders the sidebar shows, as the web builds them: pins always show,
  /// folders hold the viewer's own unpinned sessions (only on the default grouping), and the
  /// Show choice scopes the rest (My sessions, Shared sessions).
  /// - Parameters:
  ///   - sessions: The core-filtered sessions, in display order.
  ///   - projects: The caller's projects.
  ///   - display: The display options.
  ///   - members: Groups sessions into `projects` (the core's `projectMembers`).
  ///   - isOwned: Whether the viewer owns a session.
  /// - Returns: The sessions to list and the folders.
  static func layout(
    sessions: [OmnigentCoreFFI.SessionSummary], projects: [ProjectSummary],
    display: SessionDisplayOptions,
    members: ([OmnigentCoreFFI.SessionSummary]) -> [[String]],
    isOwned: (OmnigentCoreFFI.SessionSummary) -> Bool
  ) -> (sessions: [OmnigentCoreFFI.SessionSummary], projects: [SessionProject]) {
    let folders: [SessionProject]
    if display.groupBy == .default {
      let groups = members(sessions.filter { !$0.isPinned })
      folders = zip(projects, groups).map { project, ids in
        SessionProject(
          id: project.id ?? "label:\(project.name)", name: project.name, sessionIds: ids,
          projectID: project.id, icon: project.icon)
      }
    } else {
      folders = []
    }
    let filed = Set(folders.flatMap(\.sessionIds))
    let shown = sessions.filter { session in
      if session.isPinned || filed.contains(session.id) { return true }
      switch display.show {
      case .all, .archived: return true
      case .mine: return isOwned(session)
      case .shared: return !isOwned(session)
      }
    }
    return (shown, folders)
  }

  /// What a row shows beyond the summary.
  /// - Parameters:
  ///   - session: The session.
  ///   - isOwned: The viewer owns it.
  ///   - environments: Where a session on each host runs; empty until the hosts are read.
  ///   - hasDraft: Its composer holds an unsent draft.
  /// - Returns: The row's facts.
  static func rowInfo(
    _ session: OmnigentCoreFFI.SessionSummary, isOwned: Bool,
    environments: [String: SessionEnvironment] = [:], hasDraft: Bool = false
  ) -> SessionRowInfo {
    let configuration = session.configuration
    var info = SessionRowInfo(
      harness: configuration?.harness,
      environment: environments.isEmpty
        ? nil
        : configuration.map { environmentLabel($0.hostId.map { environments[$0] ?? .remote }) },
      repo: repoName(session.workspace),
      branch: configuration?.gitBranch, createdAt: session.createdAt, isShared: !isOwned,
      hasDraft: hasDraft,
      isDisconnected: configuration.map { executionUnavailableReason(configuration: $0) != nil }
        ?? false)
    info.createdBy = isOwned ? (session.owner == nil ? nil : "You") : session.owner
    info.runsOnHost = configuration?.hostId != nil
    return info
  }

  /// The Environment detail: a session without a host runs on the server's own machine.
  static func environmentLabel(_ environment: SessionEnvironment?) -> String {
    switch environment ?? .localMachine {
    case .localMachine: "Local machine"
    case .thisMachine:
      #if os(macOS)
        "This Mac"
      #else
        "This device"
      #endif
    case .remote: "Remote"
    case .sandbox(let label): label
    }
  }

  /// The folder name of a workspace path; labels that are not paths have none.
  static func repoName(_ workspace: String) -> String? {
    guard workspace.hasPrefix("/") || workspace.hasPrefix("~") else { return nil }
    let name = URL(fileURLWithPath: workspace).lastPathComponent
    return name.isEmpty || name == "/" ? nil : name
  }

  static func phase(_ list: SessionListStore) -> SessionListPhase {
    if let error = list.lastError { return .failed(message: error.message) }
    return list.isLoaded ? .loaded : .loading
  }

  /// The web page of a session, as the core builds it (`<server>/c/<id>`, keeping any mount).
  static func webURL(server: ConnectedServer?, sessionID: String) -> URL? {
    guard let server else { return nil }
    do {
      return URL(
        string: try conversationUrl(
          serverUrl: server.baseUrl, route: .conversation(sessionId: sessionID)))
    } catch {
      // The row menu hides Copy Link for a session without a web URL; the server URL itself was
      // already validated by the core on connect.
      return nil
    }
  }
}

extension ServerChoice {
  init(_ server: ConnectedServer) {
    self.init(
      id: Self.normalizedID(server.baseUrl),
      name: ExecutionContext.serverDisplayName(name: server.serverName, baseURL: server.baseUrl),
      url: server.baseUrl, isConnected: true)
  }
}

extension ProjectSummary {
  /// The core's project for a sidebar folder.
  init(_ project: SessionProject) {
    self.init(id: project.projectID, name: project.name, icon: project.icon)
  }
}
