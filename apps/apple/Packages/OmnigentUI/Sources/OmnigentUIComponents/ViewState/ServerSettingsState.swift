import Foundation

/// A server settings pane.
nonisolated public enum ServerSettingsPane: String, Hashable, Sendable, CaseIterable, Identifiable {
  /// Harnesses.
  case harnesses
  /// MCP servers.
  case mcp
  /// Git providers.
  case git
  /// Members (admin).
  case members
  /// Policies (admin).
  case policies
  /// Sharing (admin).
  case sharing
  /// Archived sessions.
  case archived

  /// The pane itself.
  public var id: Self { self }

  /// The title.
  public var title: String {
    switch self {
    case .harnesses: "Harnesses"
    case .mcp: "MCP"
    case .git: "Git"
    case .members: "Members"
    case .policies: "Policies"
    case .sharing: "Sharing"
    case .archived: "Archived sessions"
    }
  }

  /// The SF Symbol.
  public var systemImage: String {
    switch self {
    case .harnesses: "cpu"
    case .mcp: "powerplug"
    case .git: "arrow.triangle.branch"
    case .members: "person.2"
    case .policies: "hand.raised"
    case .sharing: "person.badge.plus"
    case .archived: "archivebox"
    }
  }
}

/// A harness the server knows.
nonisolated public struct ServerHarness: Hashable, Sendable, Identifiable {
  /// Id.
  public var id: String
  /// Name.
  public var name: String
  /// Harness id.
  public var harness: String
  /// Configured on the server.
  public var isEnabled: Bool
  /// A readiness note, for example "Needs sign-in on 1 host".
  public var note: String?

  /// Creates a harness row.
  /// - Parameters:
  ///   - id: Id.
  ///   - name: Name.
  ///   - harness: Harness id.
  ///   - isEnabled: Enabled.
  ///   - note: Note.
  public init(id: String, name: String, harness: String, isEnabled: Bool, note: String? = nil) {
    self.id = id
    self.name = name
    self.harness = harness
    self.isEnabled = isEnabled
    self.note = note
  }
}

/// A generic named row with a status and an on/off switch (MCP servers, Git providers, policies).
nonisolated public struct ServerSettingRow: Hashable, Sendable, Identifiable {
  /// Id.
  public var id: String
  /// Name.
  public var name: String
  /// One line.
  public var detail: String
  /// On.
  public var isEnabled: Bool

  /// Creates a row.
  /// - Parameters:
  ///   - id: Id.
  ///   - name: Name.
  ///   - detail: Detail.
  ///   - isEnabled: On.
  public init(id: String, name: String, detail: String = "", isEnabled: Bool = true) {
    self.id = id
    self.name = name
    self.detail = detail
    self.isEnabled = isEnabled
  }
}

/// A server member.
nonisolated public struct ServerMember: Hashable, Sendable, Identifiable {
  /// Id.
  public var id: String
  /// Name.
  public var name: String
  /// Email.
  public var email: String
  /// Role, for example "Admin" or "Member".
  public var role: String

  /// Creates a member.
  /// - Parameters:
  ///   - id: Id.
  ///   - name: Name.
  ///   - email: Email.
  ///   - role: Role.
  public init(id: String, name: String, email: String, role: String) {
    self.id = id
    self.name = name
    self.email = email
    self.role = role
  }
}

/// Server settings: one server's administration, loaded per pane.
nonisolated public struct ServerSettingsViewState: Hashable, Sendable {
  /// Servers to pick from.
  public var servers: [ServerChoice]
  /// Harnesses.
  public var harnesses: [ServerHarness]
  /// MCP servers.
  public var mcpServers: [ServerSettingRow]
  /// Git providers.
  public var gitProviders: [ServerSettingRow]
  /// Members.
  public var members: [ServerMember]
  /// Policies.
  public var policies: [ServerSettingRow]
  /// Sharing is allowed on this server.
  public var sharingEnabled: Bool
  /// Archived sessions.
  public var archived: [SessionSummary]
  /// The caller is an admin (Members, Policies, Sharing are read-only otherwise).
  public var isAdmin: Bool
  /// A load or save error, never swallowed.
  public var errorMessage: String?

  /// Creates settings state.
  /// - Parameters:
  ///   - servers: Servers.
  ///   - harnesses: Harnesses.
  ///   - mcpServers: MCP servers.
  ///   - gitProviders: Git providers.
  ///   - members: Members.
  ///   - policies: Policies.
  ///   - sharingEnabled: Sharing enabled.
  ///   - archived: Archived sessions.
  ///   - isAdmin: Admin.
  ///   - errorMessage: Error.
  public init(
    servers: [ServerChoice], harnesses: [ServerHarness] = [], mcpServers: [ServerSettingRow] = [],
    gitProviders: [ServerSettingRow] = [], members: [ServerMember] = [],
    policies: [ServerSettingRow] = [], sharingEnabled: Bool = true, archived: [SessionSummary] = [],
    isAdmin: Bool = false, errorMessage: String? = nil
  ) {
    self.servers = servers
    self.harnesses = harnesses
    self.mcpServers = mcpServers
    self.gitProviders = gitProviders
    self.members = members
    self.policies = policies
    self.sharingEnabled = sharingEnabled
    self.archived = archived
    self.isAdmin = isAdmin
    self.errorMessage = errorMessage
  }
}

/// Server settings actions; `nil` makes the control read-only.
public struct ServerSettingsActions {
  /// Enable or disable a harness.
  public var setHarnessEnabled: (@MainActor (ServerHarness, Bool) -> Void)?
  /// Enable or disable an MCP server.
  public var setMCPEnabled: (@MainActor (ServerSettingRow, Bool) -> Void)?
  /// Add an MCP server.
  public var addMCPServer: (@MainActor () -> Void)?
  /// Connect or disconnect a Git provider.
  public var setGitConnected: (@MainActor (ServerSettingRow, Bool) -> Void)?
  /// Change a member's role.
  public var setMemberRole: (@MainActor (ServerMember, String) -> Void)?
  /// Enable or disable a policy.
  public var setPolicyEnabled: (@MainActor (ServerSettingRow, Bool) -> Void)?
  /// Allow or disallow sharing.
  public var setSharingEnabled: (@MainActor (Bool) -> Void)?
  /// Unarchive a session.
  public var unarchive: (@MainActor (SessionSummary) -> Void)?

  /// Creates actions.
  /// - Parameters:
  ///   - setHarnessEnabled: Harness toggle.
  ///   - setMCPEnabled: MCP toggle.
  ///   - addMCPServer: Add MCP.
  ///   - setGitConnected: Git toggle.
  ///   - setMemberRole: Member role.
  ///   - setPolicyEnabled: Policy toggle.
  ///   - setSharingEnabled: Sharing toggle.
  ///   - unarchive: Unarchive.
  public init(
    setHarnessEnabled: (@MainActor (ServerHarness, Bool) -> Void)? = nil,
    setMCPEnabled: (@MainActor (ServerSettingRow, Bool) -> Void)? = nil,
    addMCPServer: (@MainActor () -> Void)? = nil,
    setGitConnected: (@MainActor (ServerSettingRow, Bool) -> Void)? = nil,
    setMemberRole: (@MainActor (ServerMember, String) -> Void)? = nil,
    setPolicyEnabled: (@MainActor (ServerSettingRow, Bool) -> Void)? = nil,
    setSharingEnabled: (@MainActor (Bool) -> Void)? = nil,
    unarchive: (@MainActor (SessionSummary) -> Void)? = nil
  ) {
    self.setHarnessEnabled = setHarnessEnabled
    self.setMCPEnabled = setMCPEnabled
    self.addMCPServer = addMCPServer
    self.setGitConnected = setGitConnected
    self.setMemberRole = setMemberRole
    self.setPolicyEnabled = setPolicyEnabled
    self.setSharingEnabled = setSharingEnabled
    self.unarchive = unarchive
  }
}
