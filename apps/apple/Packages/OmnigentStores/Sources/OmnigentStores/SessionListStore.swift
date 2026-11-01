public import Observation
public import OmnigentCoreFFI

/// The server's sessions, kept in step with the core's `SessionListChanged` events. Ordering and
/// filtering are the core's (`filterSessions`).
@Observable
public final class SessionListStore {
  /// Every known session, by id.
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

  private func edit(_ sessionID: String, _ change: SessionChange) async -> Bool {
    guard let core else {
      editError = .InvalidState(message: "Connect to a server before editing sessions.")
      return false
    }
    editing.insert(sessionID)
    defer { editing.remove(sessionID) }
    do {
      let updated = try await core.editSession(sessionId: sessionID, change: change)
      sessionsByID[updated.id] = updated
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
    switch change {
    case .reset(let sessions):
      sessionsByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    case .upsert(let sessions):
      for session in sessions {
        sessionsByID[session.id] = session
      }
    case .remove(let ids):
      for id in ids {
        sessionsByID[id] = nil
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
    sessionsByID = [:]
    isLoaded = false
    recompute()
  }

  private func recompute() {
    visible = filterSessions(
      sessions: Array(sessionsByID.values), text: searchText, filter: filter)
  }
}
