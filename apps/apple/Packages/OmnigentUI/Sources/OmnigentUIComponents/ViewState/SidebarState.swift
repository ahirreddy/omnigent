import Foundation

/// A project (folder) in the sidebar's Projects section.
nonisolated public struct SessionProject: Hashable, Sendable, Identifiable {
  /// Stable id: the project id, or the name of a label-only project.
  public var id: String
  /// Display name.
  public var name: String
  /// Its sessions, in the core's order.
  public var sessionIds: [String]
  /// The server's project id; `nil` for a legacy label-only project.
  public var projectID: String?
  /// An emoji icon, shown instead of the folder.
  public var icon: String?

  /// Creates a project.
  /// - Parameters:
  ///   - id: Project id.
  ///   - name: Name.
  ///   - sessionIds: Session ids.
  ///   - projectID: The server's id, when first-class.
  ///   - icon: An emoji icon.
  public init(
    id: String, name: String, sessionIds: [String], projectID: String? = nil, icon: String? = nil
  ) {
    self.id = id
    self.name = name
    self.sessionIds = sessionIds
    self.projectID = projectID
    self.icon = icon
  }
}

/// The web's sidebar "Show" choice.
nonisolated public enum SessionShowScope: String, Hashable, Sendable, CaseIterable, Codable {
  /// All sessions.
  case all
  /// Sessions I created.
  case mine
  /// Sessions shared with me.
  case shared
  /// Archived sessions.
  case archived

  /// The menu title.
  public var title: String {
    switch self {
    case .all: "All sessions"
    case .mine: "My sessions"
    case .shared: "Shared sessions"
    case .archived: "Archived sessions"
    }
  }
}

/// The web's sidebar "Group by" choice.
nonisolated public enum SessionGrouping: String, Hashable, Sendable, CaseIterable, Codable {
  /// Pinned, Projects, Shared, Sessions.
  case `default`
  /// By status.
  case status
  /// By harness.
  case harness
  /// By creation date.
  case created
  /// By last update.
  case updated

  /// The menu title.
  public var title: String {
    switch self {
    case .default: "Default"
    case .status: "Status"
    case .harness: "Harness"
    case .created: "Created"
    case .updated: "Updated"
    }
  }
}

/// The web's sidebar "Sort by" choice.
nonisolated public enum SessionSort: String, Hashable, Sendable, CaseIterable, Codable {
  /// Most recently updated first.
  case updated
  /// Most recently created first.
  case created

  /// The menu title.
  public var title: String {
    switch self {
    case .updated: "Updated"
    case .created: "Created"
    }
  }
}

/// The web's sidebar row details.
nonisolated public enum SessionRowDetail: String, Hashable, Sendable, CaseIterable, Codable {
  /// The relative update time.
  case updated
  /// The environment (host or sandbox).
  case environment
  /// The repository.
  case repo
  /// The branch.
  case branch

  /// The menu title.
  public var title: String {
    switch self {
    case .updated: "Updated"
    case .environment: "Environment"
    case .repo: "Repo"
    case .branch: "Branch"
    }
  }
}

/// The filter and display menu's choices, persisted by the host under `omnigent:sidebar-view`.
nonisolated public struct SessionDisplayOptions: Hashable, Sendable, Codable {
  /// Show.
  public var show: SessionShowScope
  /// Group by.
  public var groupBy: SessionGrouping
  /// Sort by.
  public var sortBy: SessionSort
  /// Row details shown under the title.
  public var details: Set<SessionRowDetail>

  /// Creates options.
  /// - Parameters:
  ///   - show: Show scope.
  ///   - groupBy: Grouping.
  ///   - sortBy: Sort.
  ///   - details: Row details.
  public init(
    show: SessionShowScope = .all, groupBy: SessionGrouping = .default,
    sortBy: SessionSort = .updated, details: Set<SessionRowDetail> = [.updated]
  ) {
    self.show = show
    self.groupBy = groupBy
    self.sortBy = sortBy
    self.details = details
  }
}

/// Facts the sidebar row shows that the core's `SessionSummary` does not carry yet.
nonisolated public struct SessionRowInfo: Hashable, Sendable {
  /// The harness id, for Group by Harness and the hover tooltip.
  public var harness: String?
  /// The environment label (host name or sandbox).
  public var environment: String?
  /// The repository.
  public var repo: String?
  /// The branch.
  public var branch: String?
  /// Created, Unix seconds.
  public var createdAt: Int64?
  /// Shared with the viewer by someone else.
  public var isShared: Bool
  /// Has an unsent draft.
  public var hasDraft: Bool
  /// The runner or host is disconnected.
  public var isDisconnected: Bool

  /// Creates row info.
  /// - Parameters:
  ///   - harness: Harness id.
  ///   - environment: Environment.
  ///   - repo: Repository.
  ///   - branch: Branch.
  ///   - createdAt: Created, Unix seconds.
  ///   - isShared: Shared with me.
  ///   - hasDraft: Has a draft.
  ///   - isDisconnected: Disconnected.
  public init(
    harness: String? = nil, environment: String? = nil, repo: String? = nil, branch: String? = nil,
    createdAt: Int64? = nil, isShared: Bool = false, hasDraft: Bool = false,
    isDisconnected: Bool = false
  ) {
    self.harness = harness
    self.environment = environment
    self.repo = repo
    self.branch = branch
    self.createdAt = createdAt
    self.isShared = isShared
    self.hasDraft = hasDraft
    self.isDisconnected = isDisconnected
  }
}

/// One server this window can switch to (native multi-server windows).
nonisolated public struct ServerChoice: Hashable, Sendable, Identifiable {
  /// Stable id (the origin).
  public var id: String
  /// Display name.
  public var name: String
  /// The server URL.
  public var url: String
  /// Signed in or reachable.
  public var isConnected: Bool

  /// Creates a server choice.
  /// - Parameters:
  ///   - id: Id.
  ///   - name: Name.
  ///   - url: URL.
  ///   - isConnected: Connected.
  public init(id: String, name: String, url: String, isConnected: Bool = true) {
    self.id = id
    self.name = name
    self.url = url
    self.isConnected = isConnected
  }
}

/// A transient banner offering Undo after pin, unpin or archive (the web's toasts).
nonisolated public struct UndoBanner: Hashable, Sendable, Identifiable {
  /// What the banner undoes.
  public enum Kind: Hashable, Sendable {
    /// "Unpinned session".
    case unpinned
    /// "Pinned session".
    case pinned
    /// "Archived N session(s)", with View archived.
    case archived(count: Int)
  }

  /// Stable id.
  public var id: String
  /// What happened.
  public var kind: Kind

  /// Creates a banner.
  /// - Parameters:
  ///   - id: Id.
  ///   - kind: What happened.
  public init(id: String, kind: Kind) {
    self.id = id
    self.kind = kind
  }

  /// The banner text, in the web's words.
  public var message: String {
    switch kind {
    case .unpinned: "Unpinned session"
    case .pinned: "Pinned session"
    case .archived(let count): count == 1 ? "Archived 1 session" : "Archived \(count) sessions"
    }
  }
}

/// The sidebar: navigation, quick filters, sections and the server switcher.
nonisolated public struct SidebarViewState: Hashable, Sendable {
  /// The sessions (core-ordered) with unread, attention, counts and load state.
  public var list: SessionListViewState
  /// Facts per session id that the summary lacks.
  public var rowInfo: [String: SessionRowInfo]
  /// Projects.
  public var projects: [SessionProject]
  /// The Inbox count.
  public var inboxCount: Int
  /// The server offers Canvas.
  public var showsCanvas: Bool
  /// The server offers Automations.
  public var showsAutomations = false
  /// The server offers Usage.
  public var showsUsage = false
  /// The display menu choices.
  public var display: SessionDisplayOptions
  /// A one-click quick filter (Running or Needs you), or `nil` for none.
  public var quickFilter: SessionFilter?
  /// Servers to switch between.
  public var servers: [ServerChoice]
  /// The current server id.
  public var currentServerID: String?
  /// An undo banner to show.
  public var undo: UndoBanner?
  /// The pin cap (the web's 30).
  public var pinLimit: Int

  /// Creates sidebar state.
  /// - Parameters:
  ///   - list: Sessions.
  ///   - rowInfo: Per-session facts.
  ///   - projects: Projects.
  ///   - inboxCount: Inbox count.
  ///   - showsCanvas: Canvas is available.
  ///   - display: Display options.
  ///   - quickFilter: Quick filter.
  ///   - servers: Servers.
  ///   - currentServerID: Current server.
  ///   - undo: Undo banner.
  ///   - pinLimit: Pin cap.
  public init(
    list: SessionListViewState, rowInfo: [String: SessionRowInfo] = [:],
    projects: [SessionProject] = [], inboxCount: Int = 0, showsCanvas: Bool = true,
    display: SessionDisplayOptions = SessionDisplayOptions(), quickFilter: SessionFilter? = nil,
    servers: [ServerChoice] = [], currentServerID: String? = nil, undo: UndoBanner? = nil,
    pinLimit: Int = 30
  ) {
    self.list = list
    self.rowInfo = rowInfo
    self.projects = projects
    self.inboxCount = inboxCount
    self.showsCanvas = showsCanvas
    self.display = display
    self.quickFilter = quickFilter
    self.servers = servers
    self.currentServerID = currentServerID
    self.undo = undo
    self.pinLimit = pinLimit
  }

  /// The current server.
  public var currentServer: ServerChoice? {
    servers.first { $0.id == currentServerID }
  }

  /// Pinned sessions now.
  public var pinnedCount: Int { list.sessions.count(where: \.isPinned) }
}

/// Sidebar actions. `nil` hides or disables the matching item.
public struct SidebarActions {
  /// Session row and title-menu actions.
  public var sessions: SessionListActions
  /// Change the display options.
  public var setDisplay: (@MainActor (SessionDisplayOptions) -> Void)?
  /// Set or clear the quick filter.
  public var setQuickFilter: (@MainActor (SessionFilter?) -> Void)?
  /// Switch this window to another server.
  public var switchServer: (@MainActor (ServerChoice) -> Void)?
  /// Add a server ("Connect to Server…").
  public var addServer: (@MainActor () -> Void)?
  /// Open server settings.
  public var openServerSettings: (@MainActor () -> Void)?
  /// Undo the banner's change.
  public var undo: (@MainActor (UndoBanner) -> Void)?
  /// Dismiss the banner.
  public var dismissUndo: (@MainActor () -> Void)?
  /// Show archived sessions (from the archive banner).
  public var viewArchived: (@MainActor () -> Void)?
  /// Create a project with the given name, moving the session into it when one is given.
  public var createProject: (@MainActor (String, SessionSummary?) -> Void)?
  /// Rename a project.
  public var renameProject: (@MainActor (SessionProject, String) -> Void)?
  /// Delete a project (its sessions are archived, never deleted).
  public var deleteProject: (@MainActor (SessionProject) -> Void)?
  /// Archive or restore several sessions at once, with one Undo (bulk selection).
  public var setArchivedMany: (@MainActor ([SessionSummary], Bool) -> Void)?
  /// Carry out a session drag (pin into a slot, file into or out of a project).
  public var dropSession: (@MainActor (SessionSummary, SidebarDropAction) -> Void)?
  /// Save a new project order (a project dragged onto another).
  public var reorderProjects: (@MainActor ([SessionProject]) -> Void)?

  /// Creates actions.
  /// - Parameters:
  ///   - sessions: Session actions.
  ///   - setDisplay: Display options.
  ///   - setQuickFilter: Quick filter.
  ///   - switchServer: Switch server.
  ///   - addServer: Add a server.
  ///   - openServerSettings: Server settings.
  ///   - undo: Undo.
  ///   - dismissUndo: Dismiss undo.
  ///   - viewArchived: View archived.
  public init(
    sessions: SessionListActions, setDisplay: (@MainActor (SessionDisplayOptions) -> Void)? = nil,
    setQuickFilter: (@MainActor (SessionFilter?) -> Void)? = nil,
    switchServer: (@MainActor (ServerChoice) -> Void)? = nil,
    addServer: (@MainActor () -> Void)? = nil, openServerSettings: (@MainActor () -> Void)? = nil,
    undo: (@MainActor (UndoBanner) -> Void)? = nil, dismissUndo: (@MainActor () -> Void)? = nil,
    viewArchived: (@MainActor () -> Void)? = nil
  ) {
    self.sessions = sessions
    self.setDisplay = setDisplay
    self.setQuickFilter = setQuickFilter
    self.switchServer = switchServer
    self.addServer = addServer
    self.openServerSettings = openServerSettings
    self.undo = undo
    self.dismissUndo = dismissUndo
    self.viewArchived = viewArchived
  }
}
