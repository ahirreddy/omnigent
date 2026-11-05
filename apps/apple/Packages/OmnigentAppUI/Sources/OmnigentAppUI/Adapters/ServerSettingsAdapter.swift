import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Builds the Settings window's server settings from a ``ServerSettingsStore``.
enum ServerSettingsAdapter {
  /// The view state.
  /// - Parameters:
  ///   - store: The selected server's settings, if one is signed in.
  ///   - servers: The signed-in servers.
  ///   - projects: The server's projects, naming the Archived pane's filter.
  ///   - now: For "last signed in" labels.
  /// - Returns: The state.
  static func state(
    _ store: ServerSettingsStore?, servers: [ServerChoice],
    projects: [OmnigentCoreFFI.ProjectSummary] = [],
    now: Date = .now
  ) -> ServerSettingsViewState {
    guard let store else { return ServerSettingsViewState(servers: servers, panes: []) }
    var state = baseState(store, servers: servers, now: now)
    let info = store.info.value
    state.account = info.map {
      ServerAccountState(
        userID: $0.userId, isAdmin: $0.isAdmin, canChangePassword: $0.accountsEnabled)
    }
    let archived = store.archived.value ?? []
    state.archivedInfo = Dictionary(
      archived.map { ($0.id, archivedInfo($0, userID: info?.userId)) },
      uniquingKeysWith: { first, _ in first })
    state.archivedProjects = archivedProjects(archived, projects: projects)
    return state
  }

  private static func baseState(_ store: ServerSettingsStore, servers: [ServerChoice], now: Date)
    -> ServerSettingsViewState
  {
    let info = store.info.value
    let loads: [CoreError?] = [
      store.info.error, store.members.error, store.policies.error, store.sharing.error,
      store.mcpServices.error, store.connections.error, store.importHosts.error,
      store.archived.error, store.policyRegistry.error,
    ]
    var state = ServerSettingsViewState(
      servers: servers, panes: panes(info),
      mcpServices: store.mcpServices.value?.map(mcpRow) ?? [],
      connections: store.connections.value?.map(connectionRow) ?? [],
      members: store.members.value?.map { member($0, info: info, now: now) } ?? [],
      policies: store.policies.value?.map(policyRow) ?? [],
      sharing: store.sharing.value.map(sharing),
      archived: store.archived.value?.map { OmnigentUIComponents.SessionSummary($0) } ?? [],
      hasMoreArchived: store.hasMoreArchived,
      importHosts: store.importHosts.value?.map { SettingChoice(id: $0.hostId, title: $0.name) }
        ?? [],
      importSources: importSources().map { SettingChoice(id: $0.id, title: $0.title) },
      archiveWorktreeCleanup: info?.archiveWorktreeCleanup ?? false,
      isAdmin: info?.isAdmin ?? false,
      isLoading: store.info.isLoading || store.archived.isLoading,
      isSaving: store.isSaving,
      errorMessage: (store.error ?? loads.compactMap(\.self).first)?.message)
    state.policyTemplates = store.policyRegistry.value?.map(policyTemplate) ?? []
    return state
  }

  static func policyTemplate(_ entry: PolicyRegistryEntry) -> PolicyTemplate {
    PolicyTemplate(
      id: entry.handler, name: entry.name, detail: entry.description,
      suggestedName: entry.suggestedName,
      params: entry.params.map {
        PolicyTemplate.Param(
          id: $0.key, kind: paramKind($0.kind), detail: $0.description,
          defaultValue: $0.defaultValue, options: $0.options)
      })
  }

  static func paramKind(_ kind: PolicyParamKind) -> PolicyTemplate.ParamKind {
    switch kind {
    case .text: .text
    case .integer: .integer
    case .number: .number
    case .boolean: .boolean
    case .choice: .choice
    case .list: .list
    case .multiChoice: .multiChoice
    case .object: .object
    }
  }

  static func inviteLink(_ invite: MemberInvite) -> MemberInviteLink {
    MemberInviteLink(
      url: invite.url,
      expiresAt: invite.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) })
  }

  /// The panes `info` offers, in order.
  static func panes(_ info: ServerSettingsInfo?) -> [ServerSettingsPane] {
    guard let info else { return [.harnesses, .git, .importSessions, .archived] }
    var panes: [ServerSettingsPane] = []
    // Any sign-in with a session to end (password or SSO) shows who you are and Sign out.
    if info.accountsEnabled || info.hasLoginSession { panes.append(.account) }
    panes.append(.harnesses)
    // As on the web, Custom Agents shows only where the server enables its settings page.
    if info.customAgents { panes.append(.customAgents) }
    if info.mcpRegistry { panes.append(.mcp) }
    if !info.connections.isEmpty { panes.append(.integrations) }
    panes += [.git, .importSessions]
    // Members and Sharing mean nothing without other users.
    if info.isAdmin, !info.singleUser { panes.append(.members) }
    if info.isAdmin { panes.append(.policies) }
    if info.isAdmin, !info.singleUser { panes.append(.sharing) }
    panes.append(.archived)
    return panes
  }

  /// An archived session's project key, archive time and whether the caller may delete it (only
  /// their own; an unreported owner is the caller). The archive time is the last change: it is
  /// never earlier than the archive, so retention can only keep a session longer.
  static func archivedInfo(_ session: OmnigentCoreFFI.SessionSummary, userID: String?)
    -> ArchivedSessionInfo
  {
    ArchivedSessionInfo(
      projectID: projectKey(session), archivedAt: session.updatedAt,
      canDelete: session.owner == nil || session.owner == userID)
  }

  /// The projects the archived sessions are filed in, by name.
  static func archivedProjects(
    _ sessions: [OmnigentCoreFFI.SessionSummary], projects: [OmnigentCoreFFI.ProjectSummary]
  ) -> [SettingChoice] {
    let names = Dictionary(
      projects.compactMap { project in project.id.map { ($0, project.name) } },
      uniquingKeysWith: { first, _ in first })
    var seen = Set<String>()
    let choices = sessions.compactMap { session -> SettingChoice? in
      guard let key = projectKey(session), seen.insert(key).inserted else { return nil }
      let title = session.projectId.flatMap { names[$0] } ?? session.projectLabel ?? "Project"
      return SettingChoice(id: key, title: title)
    }
    return choices.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  /// A first-class project's id, or a legacy label project's name under its own prefix.
  private static func projectKey(_ session: OmnigentCoreFFI.SessionSummary) -> String? {
    session.projectId ?? session.projectLabel.map { "label:\($0)" }
  }

  static func member(_ member: ServerMemberRecord, info: ServerSettingsInfo?, now: Date)
    -> ServerMember
  {
    let accounts = info?.accountsEnabled ?? false
    let detail =
      member.lastLoginAt.map {
        let date = Date(timeIntervalSince1970: TimeInterval($0))
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return "Last signed in \(formatter.localizedString(for: date, relativeTo: now))"
      } ?? "Never signed in"
    return ServerMember(
      id: member.id, detail: detail, isAdmin: member.isAdmin,
      canResetPassword: accounts && member.hasPassword,
      canRemove: accounts && member.id != info?.userId)
  }

  static func mcpRow(_ service: McpServiceRecord) -> MCPServiceRow {
    MCPServiceRow(
      id: service.id, name: service.title.isEmpty ? service.id : service.title,
      detail: service.description ?? "", isConnected: service.connected, tools: service.tools,
      acceptsToken: service.acceptsToken, canDisconnect: service.canDisconnect,
      connectsInBrowser: service.connectsInBrowser)
  }

  static func connectionRow(_ connection: ProviderConnectionRecord) -> ProviderConnectionRow {
    let name =
      switch connection.provider {
      case "github": "GitHub"
      case "databricks": "Databricks"
      default: connection.provider
      }
    return ProviderConnectionRow(
      id: connection.provider, name: name, isConnected: connection.connected,
      account: connection.account)
  }

  static func policyRow(_ policy: DefaultPolicyRecord) -> ServerSettingRow {
    ServerSettingRow(
      id: policy.id ?? "config:\(policy.name)", name: policy.name, detail: policy.handler,
      isEnabled: policy.enabled, isReadOnly: policy.fromConfig || policy.id == nil)
  }

  static func sharing(_ sharing: SharingSettingsRecord) -> SharingViewState {
    SharingViewState(
      mode: sharing.mode, modeChoices: choices(sharing.modeOptions, current: sharing.mode),
      modeEditable: sharing.modeEditable, publicSharing: sharing.publicSharing,
      publicSharingEditable: sharing.publicSharingEditable, publicLevel: sharing.publicMaxLevel,
      publicLevelChoices: choices(sharing.publicMaxLevelOptions, current: sharing.publicMaxLevel),
      publicLevelEditable: sharing.publicMaxLevelEditable,
      defaultPublic: sharing.defaultPublicSessions,
      defaultPublicChoices: choices(
        sharing.defaultPublicSessionsOptions, current: sharing.defaultPublicSessions),
      defaultPublicEditable: sharing.defaultPublicSessionsEditable)
  }

  /// The menu choices, keeping the current value listed when the options omit it.
  static func choices(_ options: [String], current: String?) -> [SettingChoice] {
    var values = options
    if let current, !options.contains(current) { values.insert(current, at: 0) }
    return values.map { SettingChoice(id: $0, title: sharingTitle($0)) }
  }

  static func sharingTitle(_ value: String) -> String {
    switch value {
    case "on": "Anyone can share"
    case "read_only": "Read-only sharing"
    case "restricted_read_only": "Read-only, with people on this server"
    case "off": "Off"
    case "read": "Read"
    case "edit": "Edit"
    case "sandbox": "Cloud sandbox sessions"
    case "all": "All sessions"
    default: value.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }

  /// The SharingUpdate for one change.
  static func update(_ change: SharingChange) -> SharingUpdateRecord {
    switch change {
    case .mode(let mode): SharingUpdateRecord(mode: mode)
    case .publicSharing(let enabled): SharingUpdateRecord(publicSharing: enabled)
    case .publicLevel(let level): SharingUpdateRecord(publicMaxLevel: level)
    case .defaultPublic(let value): SharingUpdateRecord(defaultPublicSessions: value)
    }
  }

  /// One line for an import's tally.
  static func importSummary(_ result: ImportResultRecord) -> String {
    var parts = ["Imported \(result.imported)"]
    if result.alreadyImported > 0 { parts.append("\(result.alreadyImported) already imported") }
    if result.failed > 0 { parts.append("\(result.failed) failed") }
    let summary = parts.joined(separator: ", ") + "."
    return result.failures.isEmpty
      ? summary : summary + " " + result.failures.prefix(3).joined(separator: "; ")
  }
}

extension CreationLoad {
  /// The load's failure.
  var error: CoreError? {
    if case .failed(let error) = self { return error }
    return nil
  }

  /// In flight.
  var isLoading: Bool {
    if case .loading = self { return true }
    return false
  }
}
