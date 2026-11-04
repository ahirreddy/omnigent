public import Foundation

/// One person or group with access to a shared session.
nonisolated public struct ShareGrant: Hashable, Sendable, Identifiable {
  /// Read or edit.
  public enum Role: String, Hashable, Sendable, CaseIterable {
    /// Read.
    case read
    /// Edit.
    case edit

    /// The label.
    public var title: String { self == .read ? "Read" : "Edit" }
  }

  /// Stable id.
  public var id: String
  /// Email or group name.
  public var principal: String
  /// Role.
  public var role: Role

  /// Creates a grant.
  /// - Parameters:
  ///   - id: Id.
  ///   - principal: Email or group.
  ///   - role: Role.
  public init(id: String, principal: String, role: Role) {
    self.id = id
    self.principal = principal
    self.role = role
  }
}

/// The Share sheet ("Share this session").
nonisolated public struct ShareViewState: Hashable, Sendable {
  /// General access choices, for example "Restricted" or "Anyone in the workspace can view".
  public var generalAccessOptions: [String]
  /// The selected general access.
  public var generalAccess: String
  /// "Let people with view access browse this session's files".
  public var workspaceFiles: Bool
  /// Grants.
  public var grants: [ShareGrant]
  /// The session link.
  public var link: URL?
  /// A change is being saved.
  public var isSaving: Bool
  /// The last save failed.
  public var errorMessage: String?

  /// Creates share state.
  /// - Parameters:
  ///   - generalAccessOptions: Choices.
  ///   - generalAccess: Selected.
  ///   - workspaceFiles: Files browsing.
  ///   - grants: Grants.
  ///   - link: Link.
  ///   - isSaving: Saving.
  ///   - errorMessage: Error.
  public init(
    generalAccessOptions: [String] = ["Restricted", "Anyone in the workspace can view"],
    generalAccess: String = "Restricted", workspaceFiles: Bool = false, grants: [ShareGrant] = [],
    link: URL? = nil, isSaving: Bool = false, errorMessage: String? = nil
  ) {
    self.generalAccessOptions = generalAccessOptions
    self.generalAccess = generalAccess
    self.workspaceFiles = workspaceFiles
    self.grants = grants
    self.link = link
    self.isSaving = isSaving
    self.errorMessage = errorMessage
  }
}

/// Share sheet actions.
public struct ShareActions {
  /// Change general access.
  public var setGeneralAccess: (@MainActor (String) -> Void)?
  /// Toggle workspace files.
  public var setWorkspaceFiles: (@MainActor (Bool) -> Void)?
  /// Add a person with a role.
  public var addGrant: (@MainActor (String, ShareGrant.Role) -> Void)?
  /// Change a grant's role.
  public var setRole: (@MainActor (ShareGrant, ShareGrant.Role) -> Void)?
  /// Remove a grant.
  public var removeGrant: (@MainActor (ShareGrant) -> Void)?

  /// Creates actions.
  /// - Parameters:
  ///   - setGeneralAccess: General access.
  ///   - setWorkspaceFiles: Files toggle.
  ///   - addGrant: Add a person.
  ///   - setRole: Change role.
  ///   - removeGrant: Remove.
  public init(
    setGeneralAccess: (@MainActor (String) -> Void)? = nil,
    setWorkspaceFiles: (@MainActor (Bool) -> Void)? = nil,
    addGrant: (@MainActor (String, ShareGrant.Role) -> Void)? = nil,
    setRole: (@MainActor (ShareGrant, ShareGrant.Role) -> Void)? = nil,
    removeGrant: (@MainActor (ShareGrant) -> Void)? = nil
  ) {
    self.setGeneralAccess = setGeneralAccess
    self.setWorkspaceFiles = setWorkspaceFiles
    self.addGrant = addGrant
    self.setRole = setRole
    self.removeGrant = removeGrant
  }
}

/// The Fork dialog.
nonisolated public struct ForkViewState: Hashable, Sendable, Identifiable {
  /// What is being forked.
  public enum Kind: Hashable, Sendable {
    /// The whole session ("Clone session").
    case session
    /// From one response ("Fork from this response").
    case fromMessage(rowID: String)
    /// "Continue in another directory".
    case anotherDirectory
  }

  /// Stable id.
  public var id: String
  /// Kind.
  public var kind: Kind
  /// Agents to fork into.
  public var agents: [CreationAgent]
  /// The selected agent id.
  public var agentID: String
  /// The directory.
  public var directory: String
  /// Recent directories.
  public var recentDirectories: [String]
  /// The request is in flight.
  public var isForking: Bool
  /// The last attempt failed.
  public var errorMessage: String?
  /// Why "Clone & start" is unavailable (for example the host is offline); `nil` allows it.
  public var startUnavailableReason: String?
  /// Host, model, effort and approval choices; empty hides them.
  public var options = ForkOptions()

  /// Creates fork state.
  /// - Parameters:
  ///   - id: Id.
  ///   - kind: Kind.
  ///   - agents: Agents.
  ///   - agentID: Selected agent.
  ///   - directory: Directory.
  ///   - recentDirectories: Recents.
  ///   - isForking: In flight.
  ///   - errorMessage: Error.
  ///   - startUnavailableReason: Why "Clone & start" is unavailable.
  public init(
    id: String, kind: Kind, agents: [CreationAgent], agentID: String, directory: String,
    recentDirectories: [String] = [], isForking: Bool = false, errorMessage: String? = nil,
    startUnavailableReason: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.agents = agents
    self.agentID = agentID
    self.directory = directory
    self.recentDirectories = recentDirectories
    self.isForking = isForking
    self.errorMessage = errorMessage
    self.startUnavailableReason = startUnavailableReason
  }

  /// The web's dialog title.
  public var title: String {
    switch kind {
    case .session: "Clone session"
    case .fromMessage: "Fork from this response"
    case .anotherDirectory: "Continue in another directory"
    }
  }

  /// The confirm button's verb, matching the title: "Clone", "Fork" or "Continue".
  public var verb: String {
    switch kind {
    case .session: "Clone"
    case .fromMessage: "Fork"
    case .anotherDirectory: "Continue"
    }
  }
}

/// Fork actions.
public struct ForkActions {
  /// Fork with the dialog's choices; `start` begins work immediately ("Clone & start").
  public var forkWith: @MainActor (ForkChoices) -> Void
  /// The agent or host changed: load that agent's models on that host.
  public var selectionChanged: (@MainActor (_ agentID: String, _ hostID: String?) -> Void)?
  /// Close the dialog.
  public var cancel: @MainActor () -> Void

  /// Creates actions that use every choice.
  /// - Parameters:
  ///   - forkWith: Fork.
  ///   - selectionChanged: Load the models for an agent on a host.
  ///   - cancel: Close.
  public init(
    forkWith: @escaping @MainActor (ForkChoices) -> Void,
    selectionChanged: (@MainActor (_ agentID: String, _ hostID: String?) -> Void)? = nil,
    cancel: @escaping @MainActor () -> Void
  ) {
    self.forkWith = forkWith
    self.selectionChanged = selectionChanged
    self.cancel = cancel
  }

  /// Creates actions that take only the agent, directory and start.
  /// - Parameters:
  ///   - fork: Fork.
  ///   - cancel: Close.
  public init(
    fork: @escaping @MainActor (_ agentID: String, _ directory: String, _ start: Bool) -> Void,
    cancel: @escaping @MainActor () -> Void
  ) {
    self.init(forkWith: { fork($0.agentID, $0.directory, $0.start) }, cancel: cancel)
  }
}
