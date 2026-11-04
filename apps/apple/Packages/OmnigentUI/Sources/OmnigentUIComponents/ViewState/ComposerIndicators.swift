import Foundation

/// The session's goal, as the composer tray's pill and the goal sheet show it.
nonisolated public struct ComposerGoal: Hashable, Sendable {
  /// What the agent works toward.
  public var objective: String
  /// The harness's status word, for example `active` or `budgetLimited`.
  public var status: String
  /// "1,200 / 40,000 tokens · 3 min".
  public var usage: String
  /// The token cap, when set.
  public var tokenBudget: UInt64?
  /// It can be paused now.
  public var canPause: Bool
  /// It can be resumed now.
  public var canResume: Bool

  /// Creates a goal.
  /// - Parameters:
  ///   - objective: Objective.
  ///   - status: Status word.
  ///   - usage: Usage line.
  ///   - tokenBudget: Token cap.
  ///   - canPause: Pausable.
  ///   - canResume: Resumable.
  public init(
    objective: String, status: String, usage: String = "", tokenBudget: UInt64? = nil,
    canPause: Bool = false, canResume: Bool = false
  ) {
    self.objective = objective
    self.status = status
    self.usage = usage
    self.tokenBudget = tokenBudget
    self.canPause = canPause
    self.canResume = canResume
  }

  /// "1,200 / 40,000 tokens · 3 min" (web `formatGoalUsage`).
  /// - Parameters:
  ///   - tokensUsed: Tokens spent.
  ///   - tokenBudget: The cap.
  ///   - seconds: Time spent.
  /// - Returns: The line.
  public static func usage(tokensUsed: UInt64, tokenBudget: UInt64?, seconds: UInt64) -> String {
    let used = tokensUsed.formatted()
    let tokens =
      tokenBudget.map { "\(used) / \($0.formatted()) tokens" } ?? "\(used) tokens"
    let minutes = seconds / 60
    return minutes > 0 ? "\(tokens) \u{00B7} \(minutes.formatted()) min" : tokens
  }
}

/// The composer tray's task indicators (web `composer-task-indicators`): background tasks,
/// sub-agents still in play, and the goal.
nonisolated public struct ComposerTaskIndicators: Hashable, Sendable {
  /// Background tasks still running.
  public var backgroundTasks: Int
  /// Sub-agents still in play (everything but Ready).
  public var subagents: [SubagentChild]
  /// The goal, when the session has one.
  public var goal: ComposerGoal?

  /// Creates indicators.
  /// - Parameters:
  ///   - backgroundTasks: Running background tasks.
  ///   - subagents: Sub-agents in play.
  ///   - goal: The goal.
  public init(backgroundTasks: Int = 0, subagents: [SubagentChild] = [], goal: ComposerGoal? = nil)
  {
    self.backgroundTasks = backgroundTasks
    self.subagents = subagents
    self.goal = goal
  }

  /// Nothing to show.
  public var isEmpty: Bool { backgroundTasks <= 0 && subagents.isEmpty && goal == nil }

  /// "2 sub-agents: 1 running, 1 needs you".
  public var subagentSummary: String {
    let counts = SubagentStatus.allCases.compactMap { status -> String? in
      let count = subagents.count { $0.status == status }
      return count > 0 ? status.count(count) : nil
    }
    let total = "\(subagents.count) sub-agent\(subagents.count == 1 ? "" : "s")"
    return counts.isEmpty ? total : "\(total): \(counts.joined(separator: ", "))"
  }
}

/// The tray indicators' actions. `nil` leaves an indicator as a plain label.
public struct ComposerIndicatorActions {
  /// Shows the session's pull requests.
  public var openPullRequests: (@MainActor () -> Void)?
  /// Opens a sub-agent's chat by session id.
  public var openSubagent: (@MainActor (String) -> Void)?
  /// Opens the goal sheet.
  public var openGoal: (@MainActor () -> Void)?

  /// Creates actions.
  /// - Parameters:
  ///   - openPullRequests: Show the pull requests.
  ///   - openSubagent: Open a sub-agent.
  ///   - openGoal: Open the goal.
  public init(
    openPullRequests: (@MainActor () -> Void)? = nil,
    openSubagent: (@MainActor (String) -> Void)? = nil, openGoal: (@MainActor () -> Void)? = nil
  ) {
    self.openPullRequests = openPullRequests
    self.openSubagent = openSubagent
    self.openGoal = openGoal
  }
}
