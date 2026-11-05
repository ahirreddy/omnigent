public import Foundation

// Mirrors of the core's session-list records (`omnigent-ffi` `sessions.rs`). Ordering and
// filtering are the core's (`session_query::matching`); the list renders `sessions` as given.

/// The status a session list shows.
nonisolated public enum SessionListStatus: String, Hashable, Sendable, CaseIterable {
  /// Idle, including failed (see `failureMessage`).
  case idle
  /// A turn or background work is in progress.
  case running
  /// A decision is pending.
  case needsResponse
}

/// One session as the list shows it.
nonisolated public struct SessionSummary: Hashable, Sendable, Identifiable {
  /// Session id.
  public var id: String
  /// Title, or "Untitled session".
  public var title: String
  /// The secondary line.
  public var preview: String
  /// List status.
  public var status: SessionListStatus
  /// Below edit permission, or unknown permission.
  public var isReadOnly: Bool
  /// Last activity, Unix seconds.
  public var updatedAt: Int64
  /// Workspace path or label.
  public var workspace: String
  /// Agent display name.
  public var agentName: String
  /// Pinned.
  public var isPinned: Bool
  /// Archived.
  public var isArchived: Bool
  /// The caller's permission level, when known.
  public var permissionLevel: Int64?
  /// For a failed session: the last error, or a generic message.
  public var failureMessage: String?
  /// Whether the caller may rename it.
  public var canRename: Bool
  /// Whether the caller may pin it.
  public var canPin: Bool
  /// Whether the caller may archive it.
  public var canArchive: Bool
  /// Why it needs the user (the core's attention model). Defaults to what ``status`` implies.
  public var attention: SessionAttentionState
  /// Stop can end its live process.
  public var canStop: Bool

  /// Creates a summary.
  /// - Parameters:
  ///   - id: Session id.
  ///   - title: Title.
  ///   - preview: Secondary line.
  ///   - status: List status.
  ///   - isReadOnly: Read only.
  ///   - updatedAt: Last activity, Unix seconds.
  ///   - workspace: Workspace label.
  ///   - agentName: Agent name.
  ///   - isPinned: Pinned.
  ///   - isArchived: Archived.
  ///   - permissionLevel: Permission level.
  ///   - failureMessage: Last failure.
  ///   - canRename: May rename.
  ///   - canPin: May pin.
  ///   - canArchive: May archive.
  ///   - attention: Attention; `nil` derives it from `status` and `failureMessage`.
  ///   - canStop: Stop can end it.
  public init(
    id: String, title: String, preview: String = "", status: SessionListStatus = .idle,
    isReadOnly: Bool = false, updatedAt: Int64 = 0, workspace: String = "",
    agentName: String = "", isPinned: Bool = false, isArchived: Bool = false,
    permissionLevel: Int64? = nil, failureMessage: String? = nil, canRename: Bool = true,
    canPin: Bool = true, canArchive: Bool = true, attention: SessionAttentionState? = nil,
    canStop: Bool = false
  ) {
    self.id = id
    self.title = title
    self.preview = preview
    self.status = status
    self.isReadOnly = isReadOnly
    self.updatedAt = updatedAt
    self.workspace = workspace
    self.agentName = agentName
    self.isPinned = isPinned
    self.isArchived = isArchived
    self.permissionLevel = permissionLevel
    self.failureMessage = failureMessage
    self.canRename = canRename
    self.canPin = canPin
    self.canArchive = canArchive
    self.attention = attention ?? SessionAttentionState(status: status, failure: failureMessage)
    self.canStop = canStop
  }

  /// ``updatedAt`` as a date.
  public var updatedDate: Date { Date(timeIntervalSince1970: TimeInterval(updatedAt)) }
}

/// Which sessions a list shows.
nonisolated public enum SessionFilter: String, Hashable, Sendable, CaseIterable, Identifiable {
  /// Every session that is not archived.
  case all
  /// Running, not archived.
  case running
  /// A decision is pending, archived or not.
  case needsResponse
  /// Archived.
  case archived

  /// The filter itself.
  public var id: Self { self }

  /// The display title (the core's `SessionFilter::title`).
  public var title: String {
    switch self {
    case .all: "All sessions"
    case .running: "Running"
    case .needsResponse: "Needs you"
    case .archived: "Archived"
    }
  }

  /// An SF Symbol for the filter.
  public var systemImage: String {
    switch self {
    case .all: "tray.full"
    case .running: "circle.dotted.circle"
    case .needsResponse: "hand.raised"
    case .archived: "archivebox"
    }
  }
}

/// Where the list stands.
nonisolated public enum SessionListPhase: Hashable, Sendable {
  /// Loaded; the list may still be empty.
  case loaded
  /// The first page is loading.
  case loading
  /// Loading failed. Already loaded sessions stay visible.
  case failed(message: String)
}

/// The session list the sidebar renders.
nonisolated public struct SessionListViewState: Hashable, Sendable {
  /// Sessions already filtered and ordered by the core (pinned first, then most recent).
  public var sessions: [SessionSummary]
  /// The active filter.
  public var filter: SessionFilter
  /// Sessions with activity the user has not seen (client-side; not part of the core record).
  public var unreadIds: Set<String>
  /// Pending decision counts by session id, when known (client-side).
  public var attentionCounts: [String: Int]
  /// Count of sessions per filter, for sidebar badges. Missing filters show no badge.
  public var filterCounts: [SessionFilter: Int]
  /// Loading state.
  public var phase: SessionListPhase
  /// The reference "now" for date grouping. `nil` uses the current date.
  public var now: Date?

  /// Creates list state.
  /// - Parameters:
  ///   - sessions: Filtered, ordered sessions.
  ///   - filter: Active filter.
  ///   - unreadIds: Unread sessions.
  ///   - attentionCounts: Pending decisions per session.
  ///   - filterCounts: Badge counts per filter.
  ///   - phase: Loading state.
  ///   - now: Reference date for grouping.
  public init(
    sessions: [SessionSummary], filter: SessionFilter = .all, unreadIds: Set<String> = [],
    attentionCounts: [String: Int] = [:], filterCounts: [SessionFilter: Int] = [:],
    phase: SessionListPhase = .loaded, now: Date? = nil
  ) {
    self.sessions = sessions
    self.filter = filter
    self.unreadIds = unreadIds
    self.attentionCounts = attentionCounts
    self.filterCounts = filterCounts
    self.phase = phase
    self.now = now
  }
}

/// Session list actions. `nil` hides or disables the matching control.
public struct SessionListActions {
  /// Change the filter; the host re-queries the core.
  public var setFilter: (@MainActor (SessionFilter) -> Void)?
  /// Pin or unpin.
  public var setPinned: (@MainActor (SessionSummary, Bool) -> Void)?
  /// Archive or restore.
  public var setArchived: (@MainActor (SessionSummary, Bool) -> Void)?
  /// Rename to the given title.
  public var rename: (@MainActor (SessionSummary, String) -> Void)?
  /// Mark read or unread.
  public var setUnread: (@MainActor (SessionSummary, Bool) -> Void)?
  /// Open the Share sheet.
  public var share: (@MainActor (SessionSummary) -> Void)?
  /// Why Share is unavailable on this server (sharing turned off); it then shows disabled.
  public var shareUnavailableReason: String?
  /// Fork (clone) the whole session.
  public var fork: (@MainActor (SessionSummary) -> Void)?
  /// Why a session cannot be forked; Fork then shows disabled with the reason.
  public var forkUnavailableReason: (@MainActor (SessionSummary) -> String?)?
  /// Move to a project (`nil` removes it from its project).
  public var moveToProject: (@MainActor (SessionSummary, SessionProject?) -> Void)?
  /// Stop the running session.
  public var stop: (@MainActor (SessionSummary) -> Void)?
  /// Delete (after confirmation).
  public var delete: (@MainActor (SessionSummary) -> Void)?
  /// Delete, also removing the session's worktree branch when `true` (irreversible). When set,
  /// the delete confirmation offers the cleanup for sessions with a branch.
  public var deleteWithBranch: (@MainActor (SessionSummary, _ deleteBranch: Bool) -> Void)?
  /// Leave a shared session (after confirmation).
  public var leave: (@MainActor (SessionSummary) -> Void)?
  /// Open in a new window or tab.
  public var openInNewWindow: (@MainActor (SessionSummary) -> Void)?
  /// Open beside the selected tab, splitting the window (where it can split).
  public var openInSplit: (@MainActor (SessionSummary) -> Void)?
  /// The session's shareable web link, for Copy Link.
  public var webURL: (@MainActor (SessionSummary) -> URL?)?
  /// Start a new session.
  public var newSession: (@MainActor () -> Void)?
  /// Retry after a load failure.
  public var retry: (@MainActor () -> Void)?

  /// Creates actions.
  /// - Parameters:
  ///   - setFilter: Change filter.
  ///   - setPinned: Pin or unpin.
  ///   - setArchived: Archive or restore.
  ///   - rename: Rename.
  ///   - setUnread: Mark read or unread.
  ///   - share: Share.
  ///   - fork: Fork.
  ///   - moveToProject: Move to a project.
  ///   - stop: Stop.
  ///   - delete: Delete.
  ///   - leave: Leave.
  ///   - openInNewWindow: Open in a new window.
  ///   - webURL: Web link.
  ///   - newSession: New session.
  ///   - retry: Retry loading.
  public init(
    setFilter: (@MainActor (SessionFilter) -> Void)? = nil,
    setPinned: (@MainActor (SessionSummary, Bool) -> Void)? = nil,
    setArchived: (@MainActor (SessionSummary, Bool) -> Void)? = nil,
    rename: (@MainActor (SessionSummary, String) -> Void)? = nil,
    setUnread: (@MainActor (SessionSummary, Bool) -> Void)? = nil,
    share: (@MainActor (SessionSummary) -> Void)? = nil,
    fork: (@MainActor (SessionSummary) -> Void)? = nil,
    moveToProject: (@MainActor (SessionSummary, SessionProject?) -> Void)? = nil,
    stop: (@MainActor (SessionSummary) -> Void)? = nil,
    delete: (@MainActor (SessionSummary) -> Void)? = nil,
    leave: (@MainActor (SessionSummary) -> Void)? = nil,
    openInNewWindow: (@MainActor (SessionSummary) -> Void)? = nil,
    webURL: (@MainActor (SessionSummary) -> URL?)? = nil,
    newSession: (@MainActor () -> Void)? = nil,
    retry: (@MainActor () -> Void)? = nil
  ) {
    self.setFilter = setFilter
    self.setPinned = setPinned
    self.setArchived = setArchived
    self.rename = rename
    self.setUnread = setUnread
    self.share = share
    self.fork = fork
    self.moveToProject = moveToProject
    self.stop = stop
    self.delete = delete
    self.leave = leave
    self.openInNewWindow = openInNewWindow
    self.webURL = webURL
    self.newSession = newSession
    self.retry = retry
  }
}
