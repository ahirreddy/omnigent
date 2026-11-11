public import Observation
public import OmnigentCoreFFI

/// The server's sessions, kept in step with the core's `SessionListChanged` events. Ordering,
/// filtering and attention are the core's (`SessionIndex`), which is handed the rows that changed
/// and says what each change altered.
///
/// The list's status comes from the server's session rows, which arrive a moment after a
/// decision is answered or a turn is stopped. Those two actions record the status they expect
/// (``expect(_:for:)``) so the row changes at once; the session's next server row replaces the
/// expectation, confirming or reverting it.
///
/// A rename, pin, archive, move, delete or leave shows the same way from the core: its list
/// event arrives before the server answers, and a refused one arrives again with the row as it
/// was. This store keeps only the failure (``editError``) and what to offer beside it.
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
    didSet { if unreadIDs != oldValue { unreadChanged(from: oldValue) } }
  }
  /// The sessions matching ``searchText`` and ``filter``: pinned first, then most recent.
  public private(set) var visible: [SessionSummary] = []
  /// Whether more than one session is shown, for views that need only that of the list.
  public private(set) var hasSeveralVisible = false
  /// Sessions that need the user (``AttentionState/needsYou``), archived or not, in display
  /// order. Its count is ``attentionTotals``' `sessionsNeedingYou`. Kept current here, so the
  /// views reading it (the palette, the Inbox) cost nothing per read.
  public private(set) var needsResponse: [SessionSummary] = []
  /// Whether the first list read finished.
  public private(set) var isLoaded = false
  /// Search text, matched by the core.
  public var searchText = "" {
    didSet { if searchText != oldValue { queryChanged() } }
  }
  /// Which sessions show.
  public var filter: SessionFilter = .all {
    didSet { if filter != oldValue { queryChanged() } }
  }
  /// Counts the changes that can move a row in a list of the sessions: the visible sessions or
  /// their order changed, or a session's facts beyond what its own row says (its `placement`).
  public private(set) var placementRevision = 0
  /// The last list failure, until the next successful load.
  public private(set) var lastError: CoreError?
  /// The last rename, pin or archive failure, until the next edit.
  public private(set) var editError: CoreError? {
    didSet { if editRetry != nil { editRetry = nil } }
  }
  /// The edit behind ``editError``, for its alert to offer again; it goes with the failure.
  public internal(set) var editRetry: EditRetry?
  /// Sessions whose archive, delete or leave the server has not answered. Their rows have left
  /// the list already; their tabs wait for the answer.
  public internal(set) var departing: Set<String> = []

  /// The core edits go through; set by the owning ``ConnectionStore``.
  @ObservationIgnored var core: ClientCore? {
    didSet { paging.core = core }
  }
  /// Waits until the events the core sent before answering a call are applied; set by the
  /// owning ``ConnectionStore``. Without one, the answer is all there is.
  @ObservationIgnored var eventsBeforeAnswer: () async -> Void = {}
  /// Pages loaded beyond the first ("Load more", project folders).
  public let paging = SessionListPaging()
  /// The caller's projects (sidebar folders), in display order.
  public internal(set) var projects: [ProjectSummary] = []
  /// The last project list failure, until the next successful read.
  public internal(set) var projectsError: CoreError?
  /// How projects are sorted; `nil` until read.
  public internal(set) var projectSortMode: ProjectSortMode?
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
  public internal(set) var draftSessionIDs: Set<String> = [] {
    didSet { if draftSessionIDs != oldValue { draftsChanged(from: oldValue) } }
  }

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

  /// The core's copy of the sessions in display order, with each one's attention.
  @ObservationIgnored private let index = SessionIndex()
  /// Where each session of ``visible`` is in it.
  @ObservationIgnored private var visiblePositions: [String: Int] = [:]
  /// Who is told after each change (``follow(_:)``).
  @ObservationIgnored var followers: [WeakSessionListFollower] = []

  /// Creates an empty list.
  public init() {
    paging.reportFailure = { [weak self] in self?.reportFailure($0) }
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
    refresh([sessionID])
    let lifetime = expectationLifetime
    Task { [weak self] in
      await sleepUnlessCancelled(for: lifetime)
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
    refresh([sessionID])
  }

  func edit(_ sessionID: String, _ change: SessionChange) async -> Bool {
    guard let core else {
      editError = .InvalidState(message: "Connect to a server before editing sessions.")
      return false
    }
    do {
      let updated = try await core.editSession(sessionId: sessionID, change: change)
      await eventsBeforeAnswer()
      serverSessions[updated.id] = updated
      expectations[updated.id] = nil
      refresh([updated.id])
      editError = nil
      return true
    } catch {
      // The row is back as it was before the failure shows.
      await eventsBeforeAnswer()
      editError = coreError(error)
      return false
    }
  }

  /// The rows and marks as they are now, read without observing them: for a reader that observes
  /// ``placementRevision`` or is told of changes (``follow(_:)``) instead.
  public var contents: SessionListContents {
    SessionListContents(
      visible: _visible, attention: _attentionByID, totals: _attentionTotals,
      unreadIDs: _unreadIDs, draftSessionIDs: _draftSessionIDs)
  }

  /// One session's summary and attention as the observation registrar knows them: a view that
  /// read one session is not redrawn for another session's row.
  subscript(summaryOf sessionID: String) -> SessionSummary? { _sessionsByID[sessionID] }
  /// The summary without its preview and time, for a reader that a new message should not redraw.
  subscript(withoutActivityOf sessionID: String) -> SessionSummary? {
    _sessionsByID[sessionID]?.withoutActivity
  }
  subscript(attentionOf sessionID: String) -> SessionAttention? {
    _attentionByID[sessionID]
  }
  subscript(unreadOf sessionID: String) -> Bool { _unreadIDs.contains(sessionID) }
  subscript(draftOf sessionID: String) -> Bool { _draftSessionIDs.contains(sessionID) }

  /// The sessions whose summary, attention or marks a change altered.
  private struct ChangedSessions {
    var summaries: [String] = []
    var withoutActivity: [String] = []
    var attention: [String] = []
    var marks: [KeyPath<SessionListStore, Bool>] = []
  }

  /// Applies `change` to the dictionaries, notifying the readers of each changed session.
  private func notifying(_ changed: ChangedSessions, _ change: () -> Void) {
    let summaries: [KeyPath<SessionListStore, SessionSummary?>] =
      changed.summaries.map { \.[summaryOf: $0] }
      + changed.withoutActivity.map { \.[withoutActivityOf: $0] }
    let attention: [KeyPath<SessionListStore, SessionAttention?>] =
      changed.attention.map { \.[attentionOf: $0] }
    for keyPath in summaries { _$observationRegistrar.willSet(self, keyPath: keyPath) }
    for keyPath in attention { _$observationRegistrar.willSet(self, keyPath: keyPath) }
    for keyPath in changed.marks { _$observationRegistrar.willSet(self, keyPath: keyPath) }
    change()
    for keyPath in summaries { _$observationRegistrar.didSet(self, keyPath: keyPath) }
    for keyPath in attention { _$observationRegistrar.didSet(self, keyPath: keyPath) }
    for keyPath in changed.marks { _$observationRegistrar.didSet(self, keyPath: keyPath) }
  }

  func apply(_ change: SessionListChange) {
    // Every server row settles its session's expectation.
    switch change {
    case .reset(let sessions):
      let known = Set(serverSessions.keys)
      serverSessions = Dictionary(
        sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
      expectations = [:]
      paging.listReset()
      refresh(known.union(serverSessions.keys), resetting: true)
    case .upsert(let sessions):
      for session in sessions {
        serverSessions[session.id] = session
        expectations[session.id] = nil
      }
      refresh(Set(sessions.map(\.id)))
    case .remove(let ids):
      for id in ids {
        serverSessions[id] = nil
        expectations[id] = nil
      }
      refresh(Set(ids))
    }
  }

  /// The row of `sessionID` as it shows: the server's, with any expected status applied.
  private func shownRow(_ sessionID: String) -> SessionSummary? {
    guard var session = serverSessions[sessionID] else { return nil }
    guard let expectation = expectations[sessionID] else { return session }
    session.status = expectation.status
    // An answered decision clears its request now; the next server row confirms the count.
    if expectation.status != .needsResponse { session.pendingRequests = 0 }
    return session
  }

  /// Brings the sessions of `ids` up to date with the server's rows and the expectations. Only
  /// the rows that differ cross to the core's index, unless every row was replaced.
  private func refresh(_ ids: Set<String>, resetting: Bool = false) {
    var rows: [SessionSummary] = []
    var removed: [String] = []
    var changed = ChangedSessions()
    var moves = false
    for id in ids {
      let row = shownRow(id)
      let previous = sessionsByID[id]
      guard row != previous else { continue }
      changed.summaries.append(id)
      if row?.withoutActivity != previous?.withoutActivity { changed.withoutActivity.append(id) }
      if row?.placement != previous?.placement { moves = true }
      if let row { rows.append(row) } else { removed.append(id) }
    }
    guard !changed.summaries.isEmpty else { return }
    let change =
      resetting
      ? index.reset(sessions: Array(serverSessions.values), unreadIds: Array(unreadIDs))
      : index.update(upserted: rows, removed: removed)
    changed.attention = change.attention.map(\.sessionId)
    notifying(changed) {
      withMutation(keyPath: \.sessionsByID) {
        for row in rows { _sessionsByID[row.id] = row }
        for id in removed { _sessionsByID[id] = nil }
      }
      setAttention(change.attention)
    }
    replace(rows, keptBy: change)
    settle(change, moves: moves)
  }

  /// Puts the changed `rows` where they already are in each list whose order the change kept.
  private func replace(_ rows: [SessionSummary], keptBy change: SessionIndexChange) {
    if change.visible == nil {
      let shown = rows.compactMap { row in visiblePositions[row.id].map { ($0, row) } }
      if !shown.isEmpty {
        withMutation(keyPath: \.visible) {
          for (position, row) in shown { _visible[position] = row }
        }
      }
    }
    guard change.needsResponse == nil else { return }
    let needing = rows.compactMap { row in
      needsResponse.firstIndex { $0.id == row.id }.map { ($0, row) }
    }
    guard !needing.isEmpty else { return }
    withMutation(keyPath: \.needsResponse) {
      for (position, row) in needing { _needsResponse[position] = row }
    }
  }

  private func setAttention(_ changes: [SessionAttentionChange]) {
    guard !changes.isEmpty else { return }
    withMutation(keyPath: \.attentionByID) {
      for change in changes { _attentionByID[change.sessionId] = change.attention }
    }
  }

  /// Applies what the index reported: the lists it reordered and the totals. Each assignment
  /// notifies every view that read the property, so an unchanged value is not assigned.
  private func settle(_ change: SessionIndexChange, moves: Bool = false) {
    if let ids = change.visible {
      visible = ids.compactMap { sessionsByID[$0] }
      visiblePositions = Dictionary(
        zip(visible.map(\.id), visible.indices), uniquingKeysWith: { first, _ in first })
      let several = visible.count > 1
      if several != hasSeveralVisible { hasSeveralVisible = several }
    }
    if let ids = change.needsResponse { needsResponse = ids.compactMap { sessionsByID[$0] } }
    if change.totals != attentionTotals { attentionTotals = change.totals }
    if change.visible != nil || moves { placementRevision += 1 }
    tellFollowers()
  }

  private func unreadChanged(from previous: Set<String>) {
    let change = index.setUnread(unreadIds: Array(unreadIDs))
    var changed = ChangedSessions()
    changed.attention = change.attention.map(\.sessionId)
    changed.marks = unreadIDs.symmetricDifference(previous).map { \.[unreadOf: $0] }
    notifying(changed) { setAttention(change.attention) }
    settle(change)
  }

  private func draftsChanged(from previous: Set<String>) {
    var changed = ChangedSessions()
    changed.marks = draftSessionIDs.symmetricDifference(previous).map { \.[draftOf: $0] }
    notifying(changed) {}
    tellFollowers()
  }

  private func queryChanged() {
    settle(index.setQuery(text: searchText, filter: filter))
  }
}

extension SessionListStore {
  func loaded() {
    isLoaded = true
    lastError = nil
  }

  func failed(_ error: CoreError) {
    lastError = error
  }

  /// Forgets everything of the account that was signed in.
  func clear() {
    serverSessions = [:]
    expectations = [:]
    isLoaded = false
    lastError = nil
    editError = nil
    viewerID = nil
    unreadIDs = []
    draftSessionIDs = []
    paging.clear()
    projects = []
    projectsError = nil
    projectSortMode = nil
    hostEnvironments = [:]
    hostsError = nil
    refresh(Set(sessionsByID.keys), resetting: true)
  }
}
