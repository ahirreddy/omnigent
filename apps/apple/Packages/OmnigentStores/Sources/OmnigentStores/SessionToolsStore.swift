public import Observation
public import OmnigentCoreFFI

/// One conversation's Add (+) menu tools through the core: side chats, Codex plan mode and the
/// session goal. Failures are kept in ``lastError`` until dismissed. Also the Agents panel's
/// spawn tree.
@Observable
public final class SessionToolsStore {
  /// The session.
  public let sessionID: String
  /// The goal, once read; `nil` when there is none.
  public private(set) var goal: SessionGoal?
  /// The goal has been read at least once.
  public private(set) var isGoalLoaded = false
  /// A goal or plan request is in flight.
  public private(set) var isBusy = false
  /// The latest failure.
  public private(set) var lastError: CoreError?
  /// The spawn tree from its top-level session, once read.
  public private(set) var agentTree: AgentTree?
  /// Why the latest spawn tree read failed; the last good tree stays shown.
  public private(set) var agentTreeError: CoreError?

  private let core: ClientCore
  private var isReadingAgentTree = false

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

  /// Creates a side chat of this session with `text` as its first message. Each side chat
  /// being started keeps its own failure, so this neither marks the store busy nor sets
  /// ``lastError``.
  /// - Parameter text: The first message.
  /// - Returns: The side chat and how its first message went.
  /// - Throws: The core's error when the side chat could not be created.
  public func createSideChat(text: String) async throws(CoreError) -> CreatedSideChat {
    do {
      return try await core.createSideChat(sessionId: sessionID, text: text)
    } catch {
      throw coreError(error)
    }
  }

  /// Reads the spawn tree. A read already in flight is not repeated.
  public func loadAgentTree() async {
    guard !isReadingAgentTree else { return }
    isReadingAgentTree = true
    defer { isReadingAgentTree = false }
    do {
      let tree = try await core.agentTree(sessionId: sessionID)
      if tree != agentTree { agentTree = tree }
      if agentTreeError != nil { agentTreeError = nil }
    } catch {
      agentTreeError = coreError(error)
    }
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
