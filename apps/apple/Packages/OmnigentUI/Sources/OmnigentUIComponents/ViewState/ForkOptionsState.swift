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

/// A new-sandbox row of the fork dialog's Host picker.
nonisolated public struct ForkSandboxOption: Hashable, Sendable, Identifiable {
  /// The provider; `nil` for the server's default.
  public var provider: String?
  /// `Modal Sandbox`, or `New sandbox`.
  public var label: String

  /// The provider, or empty for the default.
  public var id: String { provider ?? "" }

  /// Creates a row.
  public init(provider: String?, label: String) {
    self.provider = provider
    self.label = label
  }
}

/// The fork dialog's run configuration choices (the web's Host, Model, Effort, Permissions and
/// Advanced rows). Empty lists hide their rows.
nonisolated public struct ForkOptions: Hashable, Sendable {
  /// Hosts the copy can start on, the source's first.
  public var hosts: [ForkHostOption]
  /// The server can fork onto a new sandbox.
  public var offersSandbox: Bool
  /// The sandbox rows, one per provider.
  public var sandboxes: [ForkSandboxOption]
  /// The repositories a new sandbox clones, from the original's current branches.
  public var repositories: SandboxRepositoriesState
  /// The original's repositories are being checked for their current branches.
  public var isCheckingBranches: Bool
  /// The sandbox profile, when the provider launches with one.
  public var profiles: SandboxProfilesState?
  /// Why the new sandbox cannot start yet (repositories or profile).
  public var sandboxProblem: String?
  /// Models for the chosen agent on the chosen host.
  public var models: [ModelOption]
  /// Approval modes by agent id; the first is the harness default.
  public var approvalModes: [String: [ApprovalModeOption]]
  /// The harness's display name by agent id ("Codex"), for the danger warning.
  public var harnessNames: [String: String] = [:]

  /// Creates options.
  public init(
    hosts: [ForkHostOption] = [], offersSandbox: Bool = false,
    sandboxes: [ForkSandboxOption] = [],
    repositories: SandboxRepositoriesState = SandboxRepositoriesState(),
    isCheckingBranches: Bool = false, profiles: SandboxProfilesState? = nil,
    models: [ModelOption] = [], approvalModes: [String: [ApprovalModeOption]] = [:]
  ) {
    self.hosts = hosts
    self.offersSandbox = offersSandbox
    self.sandboxes = sandboxes
    self.repositories = repositories
    self.isCheckingBranches = isCheckingBranches
    self.profiles = profiles
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
  /// The sandbox provider; `nil` for the server's default.
  public var sandboxProvider: String?
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
