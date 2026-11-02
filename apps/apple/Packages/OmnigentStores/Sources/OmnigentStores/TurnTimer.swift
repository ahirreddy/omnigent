public import Foundation

/// Times the turns a conversation sees run: when the running turn started and how long each
/// finished turn worked. The core reports no turn times, so only turns this client saw start are
/// timed; a turn already running when the conversation opened has no start, rather than a wrong
/// one.
public struct TurnTimer: Equatable, Sendable {
  /// When the running turn started, when this client saw it start.
  public private(set) var startedAt: Date?
  /// How long each timed turn worked, by the response ids its rows carry.
  public private(set) var durations: [String: TimeInterval] = [:]
  private var isRunning = false

  /// Creates a timer with no turns.
  public init() {}

  /// Records the conversation's state.
  /// - Parameters:
  ///   - running: A turn is running now.
  ///   - observed: The change came from the live stream (`false` for a snapshot, such as the
  ///     first load or a reconnect, where the turn may have started long before).
  ///   - responseIDs: The response ids of the latest turn's rows.
  ///   - now: The time of the change.
  public mutating func update(
    isRunning running: Bool, observed: Bool, responseIDs: @autoclosure () -> [String],
    now: Date = Date()
  ) {
    defer { isRunning = running }
    if running {
      if !isRunning, observed { startedAt = now }
      return
    }
    if isRunning, let start = startedAt {
      let worked = max(0, now.timeIntervalSince(start))
      for id in responseIDs() { durations[id] = worked }
    }
    startedAt = nil
  }
}
