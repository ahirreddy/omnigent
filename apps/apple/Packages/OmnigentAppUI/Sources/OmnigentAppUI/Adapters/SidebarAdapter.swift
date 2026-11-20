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
  ///   - sorts: How Pinned and each project sort their sessions.
  ///   - server: The connected server, offered in the server switcher.
  ///   - servers: Other servers the switcher offers.
  /// - Returns: The state.
  static func state(
    list: SessionListStore, display: SessionDisplayOptions,
    sorts: SessionGroupSorts = SessionGroupSorts(), server: ConnectedServer?,
    servers: [ServerChoice] = []
  ) -> SidebarViewState {
    let contents = list.contents
    let badges = counts(contents.totals)
    let pending = contents.attention.compactMapValues(requests)
    let filter = OmnigentUIComponents.SessionFilter(list.filter)
    let layout = layout(
      sessions: contents.visible, projects: list.projects, display: display,
      members: list.members, isOwned: list.isOwned,
      manualOrder: list.projectSortMode == .manual)
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
    state.groupSorts = sorts
    return state
  }

  /// The Inbox badge and the quick filters' counts; only those two filters show one.
  static func counts(_ totals: AttentionTotals) -> SidebarCounts {
    SidebarCounts(
      inbox: approvals(totals) + Int(totals.unread),
      filters: [.running: Int(totals.working), .needsResponse: Int(totals.sessionsNeedingYou)])
  }

  /// The Inbox badge's approvals, as the web counts them: pending requests, and at least one for
  /// each session that needs the user, a session parked in its terminal included.
  static func approvals(_ totals: AttentionTotals) -> Int {
    max(Int(totals.requests), Int(totals.sessionsNeedingYou))
  }

  /// The Inbox badge as the web's: approvals, unread sessions without one, unseen file comments,
  /// automation failures that made no session and unread agent-posted items. It reads the
  /// totals, not each session, so one session's change draws only its own row.
  static func counts(_ totals: AttentionTotals, list: SessionListStore, pages: PagesStore?)
    -> SidebarCounts
  {
    var counts = counts(totals)
    guard let pages else { return counts }
    // Archived sessions' comments are dropped as they are read.
    counts.inbox += pages.unseenComments(viewerID: list.viewerID).count
    if pages.offered?.automationInbox == true {
      counts.inbox += pages.feeds.unreadFailures.count
      counts.inboxIsAtLeast = pages.feeds.hasMoreFailures
    }
    if pages.offered?.inboxItems == true {
      counts.inbox += Int(clamping: pages.feeds.unreadCount)
      counts.inboxIsAtLeast = counts.inboxIsAtLeast || pages.feeds.unreadCountCapped
    }
    return counts
  }

  /// The decisions a row's Needs you capsule counts; `nil` for a session that needs none.
  static func requests(_ attention: SessionAttention) -> Int? {
    attention.state == .needsYou ? Int(attention.requests) : nil
  }

  /// The sidebar's readers of `list` as it is now. Each reads one session, or the totals, so
  /// the view that calls one is drawn again for that session or those totals alone.
  static func live(_ list: SessionListStore, pages: PagesStore? = nil) -> SidebarLive {
    SidebarLive(
      row: { id, showsDraft in row(id, list: list, showsDraft: showsDraft) },
      counts: { counts(list.attentionTotals, list: list, pages: pages) })
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
  ///   - manualOrder: The folders follow the caller's order rather than their names.
  /// - Returns: The sessions to list and the folders.
  static func layout(
    sessions: [OmnigentCoreFFI.SessionSummary], projects: [ProjectSummary],
    display: SessionDisplayOptions,
    members: ([OmnigentCoreFFI.SessionSummary]) -> [[String]],
    isOwned: (OmnigentCoreFFI.SessionSummary) -> Bool, manualOrder: Bool = false
  ) -> (sessions: [OmnigentCoreFFI.SessionSummary], projects: [SessionProject]) {
    let pinned = shownPinned(sessions)
    var folders: [SessionProject] = []
    if display.groupBy == .default {
      let groups = members(sessions.filter { !pinned.contains($0.id) })
      folders = zip(projects, groups).map { project, ids in
        SessionProject(
          id: projectFolderId(project: project), name: project.name, sessionIds: ids,
          projectID: project.id, icon: project.icon)
      }
      // Filing is the owner's, so the Shared view keeps others' runs among its rows.
      if display.show == .all || display.show == .mine {
        folders = withSharedRuns(
          folders, sessions: sessions, isOwned: isOwned, pinned: pinned,
          manualOrder: manualOrder)
      }
    }
    let filed = Set(folders.flatMap(\.sessionIds))
    let shown = sessions.filter { session in
      if pinned.contains(session.id) || filed.contains(session.id) { return true }
      switch display.show {
      case .all, .archived: return true
      case .mine: return isOwned(session)
      case .shared: return !isOwned(session)
      }
    }
    return (shown, folders)
  }

  /// The sessions shown pinned (the core's `session_shows_pinned`): a pinned family's members
  /// with it, never a member by a pin of its own.
  static func shownPinned(_ sessions: [OmnigentCoreFFI.SessionSummary]) -> Set<String> {
    let loaded = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return Set(
      sessions.filter { session in
        guard let family = session.family else { return session.isPinned }
        return sessionShowsPinned(
          session: session, representative: family.representativeId.flatMap { loaded[$0] })
      }.map(\.id))
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
    info.pullRequest = session.pullRequest.map(pullRequest)
    info.hasLiveSandbox = SandboxAdapter.isAlive(
      session, isOwned: isOwned, environments: environments)
    if let launch = SandboxAdapter.launchNote(configuration?.sandboxLaunch) {
      // A sandbox on its way, or one that never came up, is neither local nor just disconnected.
      info.environment = launch.label
      if launch.standing == .failed {
        info.disconnectedLabel = launch.line
      } else {
        info.isDisconnected = false
      }
    }
    return info
  }

  /// The tooltip's PR: its number, and its stored state when its host fetched one.
  static func pullRequest(_ pullRequest: RowPullRequest) -> SessionRowPullRequest {
    let status: String? =
      switch pullRequest.status {
      case .open: "Open"
      case .draft: "Draft"
      case .merged: "Merged"
      case .closed: "Closed"
      case .unknown: nil
      }
    return SessionRowPullRequest(
      number: pullRequest.number, status: status,
      checkedAt: pullRequest.checkedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) })
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

  /// The folder name of a workspace path; labels that are not paths have none. The path is often
  /// on another machine, so it is read as text: a lookup under `/home` here takes milliseconds.
  static func repoName(_ workspace: String) -> String? {
    guard workspace.hasPrefix("/") || workspace.hasPrefix("~") else { return nil }
    return workspace.split(separator: "/").last.map(String.init)
  }

  static func phase(_ list: SessionListStore) -> SessionListPhase {
    if let error = list.lastError { return .failed(message: error.message) }
    return list.isLoaded ? .loaded : .loading
  }

  /// The line under the sidebar while the list is this device's saved copy, offline.
  static let offlineText = "Offline \u{2014} showing saved sessions"
  /// The line while the saved copy shows and the server's list is on its way.
  static let refreshingText = "Updating saved sessions\u{2026}"

  /// The sidebar's line while the list is the saved copy, `nil` once it is the server's.
  /// - Parameter connection: The connection.
  /// - Returns: The line.
  static func savedListNotice(_ connection: ConnectionStore) -> SidebarSavedListNotice? {
    if connection.isOffline { return .offline(offlineText) }
    return connection.isShowingSavedList ? .refreshing(refreshingText) : nil
  }

  /// The sidebar rows of the pages the server offers; before any read, none, and the Shared
  /// scope as on a multi-user server.
  static func applyOfferedPages(_ offered: ServerPages?, to state: inout SidebarViewState) {
    state.showsAutomations = offered?.automations == true
    state.showsWorkflows = offered?.workflows == true
    state.showsUsage = offered?.usage == true
    state.showsCanvas = offered?.canvas == true
    state.projectBoards = offered?.projectKanban == true
    state.showsSharedScope = offered?.sharing ?? true
  }

  /// Why the sidebar has no Automations, Usage or Canvas rows when the reason is a failed read
  /// rather than the server: `nil` once pages were read, or before any read finished.
  /// - Parameter connection: The connection.
  /// - Returns: The failure, for the quiet row's help.
  static func pagesFailure(_ connection: ConnectionStore) -> String? {
    guard connection.isSignedIn else { return nil }
    return connection.pages?.offeredReadFailure?.message
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
