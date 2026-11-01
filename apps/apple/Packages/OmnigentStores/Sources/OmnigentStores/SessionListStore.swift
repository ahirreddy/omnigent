public import Observation
public import OmnigentCoreFFI

/// The server's sessions, kept in step with the core's `SessionListChanged` events. Ordering and
/// filtering are the core's (`filterSessions`).
///
/// The list's status comes from the server's session rows, which arrive a moment after a
/// decision is answered or a turn is stopped. Those two actions record the status they expect
/// (``expect(_:for:)``) so the row changes at once; the session's next server row replaces the
/// expectation, confirming or reverting it.
@Observable
public final class SessionListStore {
  /// Every known session, by id, with any expected status applied.
  public private(set) var sessionsByID: [String: SessionSummary] = [:]
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
  /// - Returns: Whether the change was saved; a failure is in ``editError``.
  @discardableResult
  public func setArchived(_ sessionID: String, _ archived: Bool) async -> Bool {
    await edit(sessionID, .archived(archived: archived))
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

  private func edit(_ sessionID: String, _ change: SessionChange) async -> Bool {
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

  /// Sessions that wait for a decision, in display order.
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
    recompute()
  }

  private func recompute() {
    var sessions = serverSessions
    for (id, expectation) in expectations {
      sessions[id]?.status = expectation.status
    }
    sessionsByID = sessions
    visible = filterSessions(
      sessions: Array(sessionsByID.values), text: searchText, filter: filter)
  }
}
