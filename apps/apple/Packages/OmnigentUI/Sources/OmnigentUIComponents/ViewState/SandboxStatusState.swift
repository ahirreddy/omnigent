import Foundation

/// A session's managed sandbox, as the titlebar's status control and its panel show it.
nonisolated public struct SandboxStatusState: Hashable, Sendable {
  /// The small state mark on the control's icon.
  public enum Mark: String, Hashable, Sendable, CaseIterable {
    /// Launching or waking: a spinner.
    case progress
    /// The agent is connected: a steady mark.
    case running
    /// Asleep, stopped or not reported: a dim mark.
    case resting
    /// The launch waits on the user: the attention color.
    case attention
    /// The launch failed: the failure color.
    case failed

    /// The mark in a word, for assistive technology.
    public var label: String {
      switch self {
      case .progress: "In progress"
      case .running: "Running"
      case .resting: "At rest"
      case .attention: "Needs you"
      case .failed: "Failed"
      }
    }
  }

  /// Whether the server reports something as connected.
  public enum Link: String, Hashable, Sendable {
    /// Connected.
    case online
    /// Not connected.
    case offline
    /// The server has not said.
    case unreported

    /// The link in words.
    public var label: String {
      switch self {
      case .online: "Online"
      case .offline: "Offline"
      case .unreported: "Not reported"
      }
    }
  }

  /// One thing the server can be asked to do with the sandbox.
  public struct Operation: Hashable, Sendable, Identifiable {
    /// The operation's name, passed back to ``SandboxStatusActions/perform``.
    public var id: String
    /// The button's title.
    public var title: String
    /// What it does.
    public var help: String
    /// Why it does not apply now; `nil` when it does.
    public var unavailableReason: String?
    /// It ends running work, so it asks first while a turn runs.
    public var isDestructive: Bool

    /// Creates an operation.
    /// - Parameters:
    ///   - id: Its name.
    ///   - title: The button's title.
    ///   - help: What it does.
    ///   - unavailableReason: Why it does not apply now.
    ///   - isDestructive: It ends running work.
    public init(
      id: String, title: String, help: String = "", unavailableReason: String? = nil,
      isDestructive: Bool = false
    ) {
      self.id = id
      self.title = title
      self.help = help
      self.unavailableReason = unavailableReason
      self.isDestructive = isDestructive
    }
  }

  /// The mark on the icon.
  public var mark: Mark
  /// The provider's name, for example "Modal Sandbox".
  public var title: String
  /// The profile it launched with.
  public var profile: String?
  /// The state in words, for example "Cloning repository" or "Asleep".
  public var summary: String
  /// What happens next without the user.
  public var hint: String?
  /// What the user must do, while the launch waits on them.
  public var details: String?
  /// Why the launch failed.
  public var error: String?
  /// The sandbox's host.
  public var host = Link.unreported
  /// The agent's runner.
  public var runner = Link.unreported
  /// A turn is running, which a destructive operation would cut short.
  public var isTurnRunning = false
  /// The operations the server supports, each with why it does not apply now.
  public var operations: [Operation]

  /// Creates a state.
  /// - Parameters:
  ///   - mark: The mark on the icon.
  ///   - title: The provider's name.
  ///   - summary: The state in words.
  ///   - operations: The supported operations.
  public init(mark: Mark, title: String, summary: String, operations: [Operation] = []) {
    self.mark = mark
    self.title = title
    self.summary = summary
    self.operations = operations
  }

  /// The summary, with an ellipsis while the sandbox is on its way.
  public var statusLine: String { mark == .progress ? "\(summary)\u{2026}" : summary }
}

/// What the sandbox panel's buttons do.
public struct SandboxStatusActions {
  /// Asks the server for the operation with this id. Returns why it failed, or `nil` once the
  /// server took it. Without it the panel shows no buttons.
  public var perform: (@MainActor (SandboxStatusState.Operation.ID) async -> String?)?

  /// Creates the actions.
  /// - Parameter perform: Asks the server for an operation.
  public init(perform: (@MainActor (SandboxStatusState.Operation.ID) async -> String?)? = nil) {
    self.perform = perform
  }
}
