import Foundation

/// A server settings pane, in sidebar order.
nonisolated public enum ServerSettingsPane: String, Hashable, Sendable, CaseIterable, Identifiable {
  /// Account: change password.
  case account
  /// Harnesses.
  case harnesses
  /// Custom agents: yours and the server's.
  case customAgents
  /// MCP registry services.
  case mcp
  /// Sandbox integrations (provider accounts).
  case integrations
  /// Git: worktree defaults.
  case git
  /// Import local sessions from a host.
  case importSessions
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
    case .account: "Account"
    case .harnesses: "Harnesses"
    case .customAgents: "Custom Agents"
    case .mcp: "MCP"
    case .integrations: "Sandbox Integrations"
    case .git: "Git"
    case .importSessions: "Import Sessions"
    case .members: "Members"
    case .policies: "Policies"
    case .sharing: "Sharing"
    case .archived: "Archived Sessions"
    }
  }

  /// The SF Symbol.
  public var systemImage: String {
    switch self {
    case .account: "person.crop.circle"
    case .harnesses: "cpu"
    case .customAgents: "person.crop.rectangle.stack"
    case .mcp: "powerplug"
    case .integrations: "square.grid.2x2"
    case .git: "arrow.triangle.branch"
    case .importSessions: "square.and.arrow.down"
    case .members: "person.2"
    case .policies: "hand.raised"
    case .sharing: "person.badge.plus"
    case .archived: "archivebox"
    }
  }

  /// Admin panes are grouped under Admin.
  public var isAdmin: Bool { [.members, .policies, .sharing].contains(self) }
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

/// A named row with a detail line and an on/off switch (default policies).
nonisolated public struct ServerSettingRow: Hashable, Sendable, Identifiable {
  /// Id.
  public var id: String
  /// Name.
  public var name: String
  /// One line.
  public var detail: String
  /// On.
  public var isEnabled: Bool
  /// Managed elsewhere (for example the server's config file): shown, not changed.
  public var isReadOnly: Bool

  /// Creates a row.
  /// - Parameters:
  ///   - id: Id.
  ///   - name: Name.
  ///   - detail: Detail.
  ///   - isEnabled: On.
  ///   - isReadOnly: Managed elsewhere.
  public init(
    id: String, name: String, detail: String = "", isEnabled: Bool = true, isReadOnly: Bool = false
  ) {
    self.id = id
    self.name = name
    self.detail = detail
    self.isEnabled = isEnabled
    self.isReadOnly = isReadOnly
  }
}

/// An MCP registry service.
nonisolated public struct MCPServiceRow: Hashable, Sendable, Identifiable {
  /// Id.
  public var id: String
  /// Name.
  public var name: String
  /// Description.
  public var detail: String
  /// The caller's account is connected.
  public var isConnected: Bool
  /// Tools it offers.
  public var tools: [String]
  /// Connects with a personal token.
  public var acceptsToken: Bool
  /// The caller's account can be disconnected here.
  public var canDisconnect: Bool
  /// Connects in the browser (OAuth or a provider account).
  public var connectsInBrowser: Bool

  /// Creates a row.
  /// - Parameters:
  ///   - id: Id.
  ///   - name: Name.
  ///   - detail: Description.
  ///   - isConnected: Connected.
  ///   - tools: Tools.
  ///   - acceptsToken: Token connect.
  ///   - canDisconnect: Disconnectable.
  ///   - connectsInBrowser: Browser connect.
  public init(
    id: String, name: String, detail: String = "", isConnected: Bool, tools: [String] = [],
    acceptsToken: Bool = false, canDisconnect: Bool = false, connectsInBrowser: Bool = false
  ) {
    self.id = id
    self.name = name
    self.detail = detail
    self.isConnected = isConnected
    self.tools = tools
    self.acceptsToken = acceptsToken
    self.canDisconnect = canDisconnect
    self.connectsInBrowser = connectsInBrowser
  }
}

/// A provider account (GitHub, Databricks) the server's sandboxes use on the caller's behalf.
nonisolated public struct ProviderConnectionRow: Hashable, Sendable, Identifiable {
  /// The provider id.
  public var id: String
  /// Name.
  public var name: String
  /// Connected.
  public var isConnected: Bool
  /// The connected account.
  public var account: String?

  /// Creates a row.
  /// - Parameters:
  ///   - id: Provider id.
  ///   - name: Name.
  ///   - isConnected: Connected.
  ///   - account: Account.
  public init(id: String, name: String, isConnected: Bool, account: String? = nil) {
    self.id = id
    self.name = name
    self.isConnected = isConnected
    self.account = account
  }
}

/// A server member.
nonisolated public struct ServerMember: Hashable, Sendable, Identifiable {
  /// Id (a username or email).
  public var id: String
  /// One line: when they last signed in.
  public var detail: String
  /// An administrator.
  public var isAdmin: Bool
  /// The password can be reset (password accounts).
  public var canResetPassword: Bool
  /// The account can be removed (password accounts, not the caller).
  public var canRemove: Bool

  /// Creates a member.
  /// - Parameters:
  ///   - id: Id.
  ///   - detail: Detail.
  ///   - isAdmin: Admin.
  ///   - canResetPassword: Resettable.
  ///   - canRemove: Removable.
  public init(
    id: String, detail: String = "", isAdmin: Bool, canResetPassword: Bool = false,
    canRemove: Bool = false
  ) {
    self.id = id
    self.detail = detail
    self.isAdmin = isAdmin
    self.canResetPassword = canResetPassword
    self.canRemove = canRemove
  }
}

/// A choice in a settings menu.
nonisolated public struct SettingChoice: Hashable, Sendable, Identifiable {
  /// The value sent to the server.
  public var id: String
  /// The label.
  public var title: String

  /// Creates a choice.
  /// - Parameters:
  ///   - id: Value.
  ///   - title: Label.
  public init(id: String, title: String) {
    self.id = id
    self.title = title
  }
}

/// Server-wide sharing, each setting with whether it can be changed here.
nonisolated public struct SharingViewState: Hashable, Sendable {
  /// Who can share sessions.
  public var mode: String
  /// Modes.
  public var modeChoices: [SettingChoice]
  /// The mode can be changed.
  public var modeEditable: Bool
  /// Public links may be granted.
  public var publicSharing: Bool
  /// Public sharing can be changed.
  public var publicSharingEditable: Bool
  /// What a public link grants; `nil` when the server does not say.
  public var publicLevel: String?
  /// Public levels.
  public var publicLevelChoices: [SettingChoice]
  /// The public level can be changed.
  public var publicLevelEditable: Bool
  /// Which new sessions start public; `nil` when the server does not say.
  public var defaultPublic: String?
  /// Defaults.
  public var defaultPublicChoices: [SettingChoice]
  /// The default can be changed.
  public var defaultPublicEditable: Bool

  /// Creates sharing state.
  /// - Parameters:
  ///   - mode: Mode.
  ///   - modeChoices: Modes.
  ///   - modeEditable: Mode editable.
  ///   - publicSharing: Public links.
  ///   - publicSharingEditable: Public editable.
  ///   - publicLevel: Public level.
  ///   - publicLevelChoices: Levels.
  ///   - publicLevelEditable: Level editable.
  ///   - defaultPublic: Default.
  ///   - defaultPublicChoices: Defaults.
  ///   - defaultPublicEditable: Default editable.
  public init(
    mode: String, modeChoices: [SettingChoice], modeEditable: Bool, publicSharing: Bool,
    publicSharingEditable: Bool, publicLevel: String? = nil,
    publicLevelChoices: [SettingChoice] = [], publicLevelEditable: Bool = false,
    defaultPublic: String? = nil, defaultPublicChoices: [SettingChoice] = [],
    defaultPublicEditable: Bool = false
  ) {
    self.mode = mode
    self.modeChoices = modeChoices
    self.modeEditable = modeEditable
    self.publicSharing = publicSharing
    self.publicSharingEditable = publicSharingEditable
    self.publicLevel = publicLevel
    self.publicLevelChoices = publicLevelChoices
    self.publicLevelEditable = publicLevelEditable
    self.defaultPublic = defaultPublic
    self.defaultPublicChoices = defaultPublicChoices
    self.defaultPublicEditable = defaultPublicEditable
  }
}

/// One sharing change.
nonisolated public enum SharingChange: Hashable, Sendable {
  /// Who can share sessions.
  case mode(String)
  /// Allow or stop public links.
  case publicSharing(Bool)
  /// What a public link grants.
  case publicLevel(String)
  /// Which new sessions start public.
  case defaultPublic(String)
}
