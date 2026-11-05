public import Observation
public import OmnigentCoreFFI

/// The server's sessions, kept in step with the core's `SessionListChanged` events. Ordering and
/// filtering are the core's (`filterSessions`).
///
/// The list's status comes from the server's session rows, which arrive a moment after a
/// decision is answered or a turn is stopped. Those two actions record the status they expect
/// (``expect(_:for:)``) so the row changes at once; the session's next server row replaces the
/// expectation, confirming or reverting it.
///
/// It is also the one source of attention (the core's `sessionAttention` and
/// `attentionTotals`): every surface that says what needs the user reads ``attention(of:)`` and
/// ``attentionTotals`` instead of counting rows itself, so their numbers agree.
@Observable
public final class SessionListStore {
  /// Every known session, by id, with any expected status applied.
  public private(set) var sessionsByID: [String: SessionSummary] = [:]
  /// Each known session's attention (Needs you > Failed > Working > Unread > Idle), by id.
  public private(set) var attentionByID: [String: SessionAttention] = [:]
  /// Totals across every known session. `sessionsNeedingYou` is the badge number (sidebar Inbox
  /// and Needs you, Dock, menu bar); `requests` is the pending decisions behind it.
  public private(set) var attentionTotals = AttentionTotals(
    sessionsNeedingYou: 0, requests: 0, working: 0, failed: 0, unread: 0)
  /// Sessions with activity the user has not seen, as the core reports them (`unreadChanged`):
  /// the server's per-viewer read state, with this device's marks as the fallback. Opening or
  /// focusing a session (`ConnectionStore.setView`) marks it seen.
  public var unreadIDs: Set<String> = [] {
    didSet { recompute() }
  }
  /// The sessions matching ``searchText`` and ``filter``: pinned first, then most recent.
  public private(set) var visible: [SessionSummary] = []
  /// Whether the first list read finished.
  public private(set) var isLoaded = false
  /// Search text, matched by the core.
  public var searchText = "" {
    didSet { recompute() }
  }
  /// Which sessions show.
  public var filter: SessionFilter = .all {
    didSet { recompute() }
  }
  /// The last list failure, until the next successful load.
  public private(set) var lastError: CoreError?
  /// The last rename, pin or archive failure, until the next edit.
  public private(set) var editError: CoreError?
  /// Sessions with an edit in flight.
  public private(set) var editing: Set<String> = []

  /// The core edits go through; set by the owning ``ConnectionStore``.
  @ObservationIgnored var core: ClientCore?
  /// The caller's projects (sidebar folders), in display order.
  public internal(set) var projects: [ProjectSummary] = []
  /// The last project list failure, until the next successful read.
  public internal(set) var projectsError: CoreError?
  /// The connected user, for ownership (Shared, Mine, project membership).
  public internal(set) var viewerID: String?
  /// Where a session on each host runs, by host id (the sidebar's Environment detail).
  public internal(set) var hostEnvironments: [String: SessionEnvironment] = [:]
  /// This device's host id, read each time the hosts load; `nil` when it is not a host (or
  /// the app cannot tell), and a local server's only online machine stands in for it.
  @ObservationIgnored public var thisMachineHostID: () -> String? = { nil }
  /// The last host list failure, until the next successful read.
  public internal(set) var hostsError: CoreError?
  /// Sessions whose composer holds an unsent draft.
  public internal(set) var draftSessionIDs: Set<String> = []

  /// The server's rows, as the core last reported them.
  private var serverSessions: [String: SessionSummary] = [:]
  /// Statuses expected after a local action, until the session's next server row.
  private var expectations: [String: Expectation] = [:]
  /// How long an expectation may stand without a server row, so a missed row cannot leave a
  /// wrong status behind.
  @ObservationIgnored var expectationLifetime: Duration = .seconds(30)

  private struct Expectation {
    let status: SessionListStatus
    let token: UInt64
  }

  @ObservationIgnored private var nextToken: UInt64 = 0

  /// Creates an empty list.
  public init() {}

  /// Renames `sessionID` (edit permission). The title is trimmed and must be 1 to 120
  /// characters; the list updates from the core's acknowledgement.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - title: The new title.
  /// - Returns: Whether the rename was saved; a failure is in ``editError``.
  @discardableResult
  public func rename(_ sessionID: String, to title: String) async -> Bool {
    await edit(sessionID, .title(title: title))
  }

  /// Pins or unpins `sessionID` (view permission). A pin is stamped with the current time.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - pinned: Pin or unpin.
  /// - Returns: Whether the change was saved; a failure is in ``editError``.
  @discardableResult
  public func setPinned(_ sessionID: String, _ pinned: Bool) async -> Bool {
    await edit(sessionID, .pinned(pinned: pinned))
  }

  /// Archives or restores `sessionID` (owner permission).
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - archived: Archive or restore.
  ///   - deleteWorktree: When archiving, also remove its git worktree (the branch is kept).
  /// - Returns: Whether the change was saved; a failure is in ``editError``.
  @discardableResult
  public func setArchived(_ sessionID: String, _ archived: Bool, deleteWorktree: Bool = false)
    async -> Bool
  {
    await edit(sessionID, .archived(archived: archived, deleteWorktree: deleteWorktree))
  }

  /// Records `error` as the edit failure; `nil` clears it.
  func setEditError(_ error: CoreError?) {
    editError = error
  }

  /// Shows `error` where edit failures show, for a sidebar action that failed elsewhere.
  /// - Parameter error: The failure.
  public func reportFailure(_ error: CoreError) {
    editError = error
  }

  /// Clears ``editError`` after the user has seen it.
  public func dismissEditError() {
    editError = nil
  }

  /// Shows `sessionID` with `status` until its next server row arrives, which confirms or
  /// reverts it (or ``expectationLifetime`` passes). For a session the list does not know, this
  /// does nothing.
  /// - Parameters:
  ///   - status: The status the action leads to.
  ///   - sessionID: The session.
  /// - Returns: A token for ``withdrawExpectation(_:for:)``.
  @discardableResult
  public func expect(_ status: SessionListStatus, for sessionID: String) -> UInt64? {
    guard serverSessions[sessionID] != nil else { return nil }
    nextToken += 1
    let token = nextToken
    expectations[sessionID] = Expectation(status: status, token: token)
    recompute()
    let lifetime = expectationLifetime
    Task { [weak self] in
      do {
        try await Task.sleep(for: lifetime)
      } catch {
        // Cancelled with the store; the expectation goes with it.
        return
      }
      self?.withdrawExpectation(token, for: sessionID)
    }
    return token
  }

  /// Drops the expectation `token` of `sessionID` (its action failed, or it timed out), if it is
  /// still the current one.
  /// - Parameters:
  ///   - token: From ``expect(_:for:)``.
  ///   - sessionID: The session.
  public func withdrawExpectation(_ token: UInt64, for sessionID: String) {
    guard expectations[sessionID]?.token == token else { return }
    expectations[sessionID] = nil
    recompute()
  }

  func edit(_ sessionID: String, _ change: SessionChange) async -> Bool {
    guard let core else {
      editError = .InvalidState(message: "Connect to a server before editing sessions.")
      return false
    }
    editing.insert(sessionID)
    defer { editing.remove(sessionID) }
    do {
      let updated = try await core.editSession(sessionId: sessionID, change: change)
      serverSessions[updated.id] = updated
      expectations[updated.id] = nil
      recompute()
      editError = nil
      return true
    } catch {
      editError = coreError(error)
      return false
    }
  }

  /// The summary of `sessionID`, if known.
  /// - Parameter sessionID: The session.
  /// - Returns: Its summary.
  public func session(_ sessionID: String) -> SessionSummary? {
    sessionsByID[sessionID]
  }

  /// The parent of a sub-agent session, when the server reported one.
  /// - Parameter sessionID: The session.
  /// - Returns: The parent's id, or `nil` for a top-level (or unknown) session.
  public func parent(of sessionID: String) -> String? {
    sessionsByID[sessionID]?.configuration?.parentId.flatMap { $0.isEmpty ? nil : $0 }
  }

  /// The attention of `sessionID`; Idle for a session the list does not know.
  /// - Parameter sessionID: The session.
  /// - Returns: Its state and the pending decisions the caller can answer.
  public func attention(of sessionID: String) -> SessionAttention {
    attentionByID[sessionID] ?? SessionAttention(state: .idle, requests: 0)
  }

  /// Sessions that need the user (``AttentionState/needsYou``), archived or not, in display
  /// order. Its count is ``attentionTotals``' `sessionsNeedingYou`.
  public var needsResponse: [SessionSummary] {
    filterSessions(sessions: Array(sessionsByID.values), text: "", filter: .needsResponse)
  }

  func apply(_ change: SessionListChange) {
    // Every server row settles its session's expectation.
    switch change {
    case .reset(let sessions):
      serverSessions = Dictionary(
        sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
      expectations = [:]
    case .upsert(let sessions):
      for session in sessions {
        serverSessions[session.id] = session
        expectations[session.id] = nil
      }
    case .remove(let ids):
      for id in ids {
        serverSessions[id] = nil
        expectations[id] = nil
      }
    }
    recompute()
  }

  func loaded() {
    isLoaded = true
    lastError = nil
  }

  func failed(_ error: CoreError) {
    lastError = error
  }

  func clear() {
    serverSessions = [:]
    expectations = [:]
    isLoaded = false
    projects = []
    projectsError = nil
    hostEnvironments = [:]
    hostsError = nil
    recompute()
  }

  private func recompute() {
    var sessions = serverSessions
    for (id, expectation) in expectations {
      sessions[id]?.status = expectation.status
      // An answered decision clears its request now; the next server row confirms the count.
      if expectation.status != .needsResponse { sessions[id]?.pendingRequests = 0 }
    }
    sessionsByID = sessions
    let all = Array(sessions.values)
    visible = filterSessions(sessions: all, text: searchText, filter: filter)
    attentionByID = sessions.mapValues {
      sessionAttention(session: $0, isUnread: unreadIDs.contains($0.id))
    }
    attentionTotals = OmnigentCoreFFI.attentionTotals(sessions: all, unreadIds: Array(unreadIDs))
  }
}
