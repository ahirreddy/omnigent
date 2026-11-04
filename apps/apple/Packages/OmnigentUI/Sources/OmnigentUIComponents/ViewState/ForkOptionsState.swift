import Foundation

/// A host the fork dialog can start the copy on.
nonisolated public struct ForkHostOption: Hashable, Sendable, Identifiable {
  /// Host id.
  public var id: String
  /// Name.
  public var name: String
  /// Why the copy cannot start there; `nil` when it can.
  public var unavailableReason: String?

  /// Creates a host option.
  public init(id: String, name: String, unavailableReason: String? = nil) {
    self.id = id
    self.name = name
    self.unavailableReason = unavailableReason
  }
}

/// The fork dialog's run configuration choices (the web's Host, Model, Effort, Permissions and
/// Advanced rows). Empty lists hide their rows.
nonisolated public struct ForkOptions: Hashable, Sendable {
  /// Hosts the copy can start on, the source's first.
  public var hosts: [ForkHostOption]
  /// The server can fork onto a new sandbox.
  public var offersSandbox: Bool
  /// Models for the chosen agent on the chosen host.
  public var models: [ModelOption]
  /// Approval modes by agent id; the first is the harness default.
  public var approvalModes: [String: [ApprovalModeOption]]

  /// Creates options.
  public init(
    hosts: [ForkHostOption] = [], offersSandbox: Bool = false, models: [ModelOption] = [],
    approvalModes: [String: [ApprovalModeOption]] = [:]
  ) {
    self.hosts = hosts
    self.offersSandbox = offersSandbox
    self.models = models
    self.approvalModes = approvalModes
  }
}

/// What the user chose in the fork dialog.
nonisolated public struct ForkChoices: Hashable, Sendable {
  /// The agent.
  public var agentID: String
  /// The directory to start in.
  public var directory: String
  /// Start the copy ("Clone & start").
  public var start: Bool
  /// The host to start on; `nil` keeps the source's.
  public var hostID: String?
  /// Fork onto a new sandbox instead of a host.
  public var isSandbox = false
  /// Repositories to clone into the sandbox (`<url>[#<branch>]`, comma or newline separated).
  public var repositories = ""
  /// Model; `nil` keeps the source's.
  public var model: String?
  /// Reasoning effort; `nil` keeps the source's.
  public var effort: String?
  /// Approval mode; `nil` keeps the harness default.
  public var approvalMode: String?
  /// A new worktree branch; blank starts in the directory.
  public var branch = ""
  /// Title; blank lets the server name it.
  public var title = ""

  /// Creates choices.
  public init(agentID: String, directory: String, start: Bool, hostID: String? = nil) {
    self.agentID = agentID
    self.directory = directory
    self.start = start
    self.hostID = hostID
  }
}
