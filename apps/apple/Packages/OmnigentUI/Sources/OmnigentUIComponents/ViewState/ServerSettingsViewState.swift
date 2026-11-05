import Foundation

/// Server settings: one server's administration, loaded per pane.
nonisolated public struct ServerSettingsViewState: Hashable, Sendable {
  /// Servers to pick from.
  public var servers: [ServerChoice]
  /// The panes this server and caller offer, in order.
  public var panes: [ServerSettingsPane]
  /// Harnesses.
  public var harnesses: [ServerHarness]
  /// MCP registry services.
  public var mcpServices: [MCPServiceRow]
  /// Provider accounts.
  public var connections: [ProviderConnectionRow]
  /// Members.
  public var members: [ServerMember]
  /// Default policies.
  public var policies: [ServerSettingRow]
  /// Handlers a default policy can be added from.
  public var policyTemplates: [PolicyTemplate] = []
  /// Sharing; `nil` until loaded.
  public var sharing: SharingViewState?
  /// Archived sessions loaded so far.
  public var archived: [SessionSummary]
  /// More archived sessions are on the server.
  public var hasMoreArchived: Bool
  /// Hosts that can import their local sessions.
  public var importHosts: [SettingChoice]
  /// Harnesses to import from.
  public var importSources: [SettingChoice]
  /// The server can remove a session's worktree on archive.
  public var archiveWorktreeCleanup: Bool
  /// The caller is an admin.
  public var isAdmin: Bool
  /// The current pane is loading.
  public var isLoading: Bool
  /// A change is in flight.
  public var isSaving: Bool
  /// A load or save error, never swallowed.
  public var errorMessage: String?
  /// Who the caller is signed in as, for the Account pane.
  public var account: ServerAccountState?
  /// Per archived session (by id): its project, archive time and whether it can be deleted.
  public var archivedInfo: [String: ArchivedSessionInfo] = [:]
  /// Projects with loaded archived sessions, for the Archived pane's filter.
  public var archivedProjects: [SettingChoice] = []

  /// Creates settings state.
  /// - Parameters:
  ///   - servers: Servers.
  ///   - panes: Panes offered.
  ///   - harnesses: Harnesses.
  ///   - mcpServices: MCP services.
  ///   - connections: Provider accounts.
  ///   - members: Members.
  ///   - policies: Policies.
  ///   - sharing: Sharing.
  ///   - archived: Archived sessions.
  ///   - hasMoreArchived: More archived.
  ///   - importHosts: Import hosts.
  ///   - importSources: Import sources.
  ///   - archiveWorktreeCleanup: Worktree cleanup on archive.
  ///   - isAdmin: Admin.
  ///   - isLoading: Loading.
  ///   - isSaving: Saving.
  ///   - errorMessage: Error.
  public init(
    servers: [ServerChoice], panes: [ServerSettingsPane] = ServerSettingsPane.allCases,
    harnesses: [ServerHarness] = [], mcpServices: [MCPServiceRow] = [],
    connections: [ProviderConnectionRow] = [], members: [ServerMember] = [],
    policies: [ServerSettingRow] = [], sharing: SharingViewState? = nil,
    archived: [SessionSummary] = [], hasMoreArchived: Bool = false,
    importHosts: [SettingChoice] = [], importSources: [SettingChoice] = [],
    archiveWorktreeCleanup: Bool = false, isAdmin: Bool = false, isLoading: Bool = false,
    isSaving: Bool = false, errorMessage: String? = nil
  ) {
    self.servers = servers
    self.panes = panes
    self.harnesses = harnesses
    self.mcpServices = mcpServices
    self.connections = connections
    self.members = members
    self.policies = policies
    self.sharing = sharing
    self.archived = archived
    self.hasMoreArchived = hasMoreArchived
    self.importHosts = importHosts
    self.importSources = importSources
    self.archiveWorktreeCleanup = archiveWorktreeCleanup
    self.isAdmin = isAdmin
    self.isLoading = isLoading
    self.isSaving = isSaving
    self.errorMessage = errorMessage
  }
}

/// Server settings actions; `nil` makes the control read-only or hides it.
public struct ServerSettingsActions {
  /// A pane was shown: load its data.
  public var load: (@MainActor (ServerSettingsPane) -> Void)?
  /// The pane list was shown (iPhone and iPad): load which panes the server offers.
  public var loadServer: (@MainActor () -> Void)?
  /// Enable or disable a harness.
  public var setHarnessEnabled: (@MainActor (ServerHarness, Bool) -> Void)?
  /// Connect an MCP service with a personal token; returns whether it connected.
  public var connectMCP: (@MainActor (MCPServiceRow, String) async -> Bool)?
  /// Disconnect the caller's MCP account.
  public var disconnectMCP: (@MainActor (MCPServiceRow) -> Void)?
  /// Check an MCP service; returns a one-line result, or `nil` on failure.
  public var testMCP: (@MainActor (MCPServiceRow) async -> String?)?
  /// Connect in the browser (OAuth and provider accounts, which need the web's sign-in).
  public var openInBrowser: (@MainActor (ServerSettingsPane) -> Void)?
  /// Disconnect a provider account.
  public var disconnectProvider: (@MainActor (ProviderConnectionRow) -> Void)?
  /// Import sessions (host, source, limit, and a harness session id for one session); returns a
  /// one-line tally, or `nil` on failure.
  public var importSessions: (@MainActor (String, String, Int, String?) async -> String?)?
  /// Change the caller's password (current, new); returns whether it changed.
  public var changePassword: (@MainActor (String, String) async -> Bool)?
  /// Sign out of the server.
  public var signOut: (@MainActor () -> Void)?
  /// Open a session in a window (after Unarchive).
  public var openSession: (@MainActor (String) -> Void)?
  /// Reset a member's password; returns the new one, shown once.
  public var resetPassword: (@MainActor (ServerMember) async -> String?)?
  /// Remove a member.
  public var removeMember: (@MainActor (ServerMember) -> Void)?
  /// Mint an invite link (as an admin or not); `nil` on failure. `nil` hides Invite.
  public var invite: (@MainActor (Bool) async -> MemberInviteLink?)?
  /// Add a default policy (template, name, parameter values); returns whether it was added.
  public var addPolicy: (@MainActor (PolicyTemplate, String, [String: String]) async -> Bool)?
  /// Enable or disable a policy.
  public var setPolicyEnabled: (@MainActor (ServerSettingRow, Bool) -> Void)?
  /// Delete a policy.
  public var deletePolicy: (@MainActor (ServerSettingRow) -> Void)?
  /// Change sharing.
  public var changeSharing: (@MainActor (SharingChange) -> Void)?
  /// Unarchive sessions.
  public var unarchive: (@MainActor ([String]) -> Void)?
  /// Delete sessions.
  public var delete: (@MainActor ([String]) -> Void)?
  /// Load more archived sessions.
  public var loadMoreArchived: (@MainActor () -> Void)?

  /// Creates actions; every one is optional.
  public init() {}
}
