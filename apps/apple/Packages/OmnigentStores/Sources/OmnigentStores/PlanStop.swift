public import OmnigentCoreFFI

/// The plan's Stop, from its press until the session is seen to stop working, during which the
/// Tasks tab shows "Stopping…" in its place (web `planStops`).
public struct PlanStop: Equatable, Sendable {
  /// Tells one Stop from the next.
  public let id: Int
  /// The transcript's latest request when Stop was pressed; a newer one that isn't a stop
  /// message, such as Continue from another window, ends this Stop.
  public let baselineRequestID: String?
  /// The session took the stop message.
  public var sent = false
}

/// The transcript's latest request: whether it is the plan's stop message, which after a
/// relaunch stands in for a Stop pressed here.
public struct LatestRequest: Equatable, Sendable {
  /// Its row.
  public var id: String
  /// It is the plan's stop message.
  public var isStop: Bool
  /// A message sent here that the server hasn't echoed yet.
  public var isPending = false

  /// The latest request: the newest message waiting for its echo, else the newest user row.
  /// - Parameters:
  ///   - rows: The transcript.
  ///   - pending: The messages sent here that the server hasn't echoed.
  /// - Returns: The request, or `nil` without one.
  public static func of(rows: [Row], pending: [Row]) -> Self? {
    if let row = pending.last {
      return Self(id: row.id, isStop: isStopPlanMessage(text: row.text), isPending: true)
    }
    guard let row = rows.last(where: { $0.role == .user }) else { return nil }
    return Self(id: row.id, isStop: isStopPlanMessage(text: row.text))
  }
}

extension ConversationStore {
  /// The transcript's latest request, which tells the plan's Stop what followed it.
  public var latestRequest: LatestRequest? {
    LatestRequest.of(rows: rows, pending: pendingMessages.rows)
  }
}

/// The Stops and the transcript's stop messages seen to end, which no longer count. Kept out of
/// observation: the tab notes them as it reads whether the run is stopping.
struct PlanStopSettlement {
  private var stopIDs: Set<Int> = []
  private var messageIDs: Set<String> = []

  /// Whether the run is stopping: a Stop not sent yet; or, while the session works, a Stop it
  /// took or, without one, the transcript's latest stop message. Once the session is seen idle,
  /// or takes another request, they settle and no longer count.
  mutating func stopping(_ stop: PlanStop?, working: Bool, latest: LatestRequest?) -> Bool {
    if let stop, !stopIDs.contains(stop.id) {
      let followed = latest.map { !$0.isStop && $0.id != stop.baselineRequestID } ?? false
      if !followed, !stop.sent || working { return true }
      stopIDs.insert(stop.id)
      if !followed, let latest, latest.isStop { messageIDs.insert(latest.id) }
      return false
    }
    // Only an echoed stop message stands in: one still on its way may yet fail.
    guard let latest, latest.isStop, !latest.isPending, !messageIDs.contains(latest.id) else {
      return false
    }
    if working { return true }
    messageIDs.insert(latest.id)
    return false
  }
}
