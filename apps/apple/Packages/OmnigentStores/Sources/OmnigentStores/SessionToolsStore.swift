public import Observation
public import OmnigentCoreFFI

/// One conversation's Add (+) menu tools through the core: side chats, Codex plan mode and the
/// session goal. Failures are kept in ``lastError`` until dismissed.
@Observable
public final class SessionToolsStore {
  /// The session.
  public let sessionID: String
  /// The goal, once read; `nil` when there is none.
  public private(set) var goal: SessionGoal?
  /// The goal has been read at least once.
  public private(set) var isGoalLoaded = false
  /// A goal, plan or side chat request is in flight.
  public private(set) var isBusy = false
  /// The latest failure.
  public private(set) var lastError: CoreError?

  private let core: ClientCore

  init(sessionID: String, core: ClientCore) {
    self.sessionID = sessionID
    self.core = core
  }

  /// Reads the goal.
  public func loadGoal() async {
    await run { core in
      let goal = try await core.sessionGoal(sessionId: sessionID)
      setGoal(goal)
    }
  }

  /// Sets the goal's objective and token cap (`nil` clears it). `activate` starts it running;
  /// otherwise it keeps its status.
  /// - Returns: Whether the server accepted it.
  @discardableResult
  public func saveGoal(objective: String, tokenBudget: UInt64?, activate: Bool) async -> Bool {
    await run { core in
      let goal = try await core.setSessionGoal(
        sessionId: sessionID, objective: objective, tokenBudget: tokenBudget,
        active: activate ? true : nil)
      setGoal(goal)
    }
  }

  /// Pauses or resumes the goal.
  public func setGoalActive(_ active: Bool) async {
    await run { core in
      let goal = try await core.setSessionGoalActive(sessionId: sessionID, active: active)
      setGoal(goal)
    }
  }

  /// Clears the goal.
  public func clearGoal() async {
    await run { core in
      _ = try await core.clearSessionGoal(sessionId: sessionID)
      setGoal(nil)
    }
  }

  /// Turns Codex plan mode on or off; the session's sections report the result.
  public func setPlanMode(_ enabled: Bool) async {
    await run { core in _ = try await core.setPlanMode(sessionId: sessionID, on: enabled) }
  }

  /// Starts a side chat.
  /// - Returns: How it starts, or `nil` after a failure (kept in ``lastError``).
  public func startSideChat() async -> SideChatStart? {
    var start: SideChatStart?
    await run { core in start = try await core.startSideChat(sessionId: sessionID) }
    return start
  }

  /// Clears ``lastError`` after the user has seen it.
  public func dismissError() {
    if lastError != nil { lastError = nil }
  }

  private func setGoal(_ goal: SessionGoal?) {
    if goal != self.goal { self.goal = goal }
    if !isGoalLoaded { isGoalLoaded = true }
  }

  /// Runs one request, keeping its failure. Returns whether it succeeded.
  @discardableResult
  private func run(_ body: (ClientCore) async throws -> Void) async -> Bool {
    isBusy = true
    defer { isBusy = false }
    do {
      try await body(core)
      dismissError()
      return true
    } catch {
      lastError = coreError(error)
      return false
    }
  }
}
