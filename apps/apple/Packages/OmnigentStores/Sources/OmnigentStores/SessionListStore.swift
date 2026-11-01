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

  /// Creates an empty list.
  public init() {}

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
