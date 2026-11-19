import Foundation

/// The saved workflow a new session is for.
public struct WorkflowLaunchTarget: Hashable, Sendable {
  /// The workflow's id.
  public var id: String
  /// Its name.
  public var name: String
  /// What it does.
  public var description: String

  /// Creates a target.
  public init(id: String, name: String, description: String) {
    self.id = id
    self.name = name
    self.description = description
  }
}

/// What the new-session page starts for a saved workflow (web `WorkflowSessionRequest`): a run
/// of it, or the planning chat beside its page.
public enum WorkflowLaunch: Hashable, Sendable {
  /// A run: the draft holds the run's additional instructions.
  case run(WorkflowLaunchTarget)
  /// Its planning chat, which starts with `prompt`.
  case plan(WorkflowLaunchTarget, prompt: String)

  /// The workflow.
  public var target: WorkflowLaunchTarget {
    switch self {
    case .run(let target), .plan(let target, _): target
    }
  }
}
