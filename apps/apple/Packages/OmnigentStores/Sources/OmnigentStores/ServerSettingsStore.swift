import Foundation
public import Observation
public import OmnigentCoreFFI

/// One server's settings for the Settings window: what the caller may manage, members, default
/// policies, sharing, the MCP registry, provider connections, import and archived sessions.
/// Writes are never retried; a failure stays in ``error`` until the next write.
@Observable
public final class ServerSettingsStore {
  /// What the server offers and the caller may manage.
  public private(set) var info: CreationLoad<ServerSettingsInfo> = .idle
  /// Accounts (admins only).
  public private(set) var members: CreationLoad<[ServerMemberRecord]> = .idle
  /// Default policies.
  public private(set) var policies: CreationLoad<[DefaultPolicyRecord]> = .idle
  /// The built-in policy handlers a default policy can be added from.
  public private(set) var policyRegistry: CreationLoad<[PolicyRegistryEntry]> = .idle
  /// Server-wide sharing (admins only).
  public private(set) var sharing: CreationLoad<SharingSettingsRecord> = .idle
  /// MCP registry services.
  public private(set) var mcpServices: CreationLoad<[McpServiceRecord]> = .idle
  /// Provider account connections, in the server's order.
  public private(set) var connections: CreationLoad<[ProviderConnectionRecord]> = .idle
  /// Hosts that can import their local sessions.
  public private(set) var importHosts: CreationLoad<[ImportHostRecord]> = .idle
  /// Archived sessions loaded so far, most recently updated first.
  public private(set) var archived: CreationLoad<[SessionSummary]> = .idle
  /// More archived sessions are on the server.
  public private(set) var hasMoreArchived = false
  /// A write is in flight.
  public private(set) var isSaving = false
  /// The last write's failure.
  public private(set) var error: CoreError?

  private let core: ClientCore
  private var archivedCursor: String?

  /// Archived sessions per page.
  static let archivedPageSize: UInt32 = 50

  init(core: ClientCore) {
    self.core = core
  }

  /// Reads what the server offers and the caller may manage.
  public func loadInfo() async {
    info = .loading
    info = await read { try await $0.serverSettingsInfo() }
  }

  /// Reads the accounts.
  public func loadMembers() async {
    members = .loading
    members = await read { try await $0.serverMembers() }
  }

  /// Reads the default policies.
  public func loadPolicies() async {
    policies = .loading
    policies = await read { try await $0.defaultPolicies() }
  }

  /// Reads the policy registry, unless it is loaded.
  public func loadPolicyRegistry() async {
    if policyRegistry.value != nil { return }
    policyRegistry = .loading
    policyRegistry = await read { try await $0.policyRegistry() }
  }

  /// Adds a default policy from the registry, then reloads the list.
  /// - Parameters:
  ///   - entry: The handler.
  ///   - name: The policy's name.
  ///   - values: The form's parameter values, by name.
  /// - Returns: Whether it was added; a failure is in ``error``.
  @discardableResult
  public func addPolicy(_ entry: PolicyRegistryEntry, name: String, values: [String: String])
    async -> Bool
  {
    let added = await write {
      _ = try await $0.addDefaultPolicy(entry: entry, name: name, values: values)
    }
    if added { await loadPolicies() }
    return added
  }

  /// Mints a single-use invite link for a new account.
  /// - Parameter isAdmin: The account is an administrator.
  /// - Returns: The invite, to show once; `nil` on failure (see ``error``).
  public func invite(isAdmin: Bool) async -> MemberInvite? {
    var invite: MemberInvite?
    await write { invite = try await $0.inviteMember(isAdmin: isAdmin) }
    return invite
  }

  /// Reads sharing.
  public func loadSharing() async {
    sharing = .loading
    sharing = await read { try await $0.sharingSettings() }
  }

  /// Reads the MCP registry.
  public func loadMCPServices() async {
    mcpServices = .loading
    mcpServices = await read { try await $0.mcpServices() }
  }

  /// Reads each provider connection the server offers.
  /// - Parameter providers: The providers, from ``ServerSettingsInfo/connections``.
  public func loadConnections(_ providers: [String]) async {
    connections = .loading
    connections = await read { core in
      var rows: [ProviderConnectionRecord] = []
      for provider in providers {
        rows.append(try await core.providerConnection(provider: provider))
      }
      return rows
    }
  }

  /// Reads the hosts that can import.
  public func loadImportHosts() async {
    importHosts = .loading
    importHosts = await read { try await $0.importHosts() }
  }

  /// Reads the first page of archived sessions, replacing what was loaded.
  public func loadArchived() async {
    archived = .loading
    archivedCursor = nil
    await readArchivedPage(appending: [])
  }

  /// Reads the next page of archived sessions.
  public func loadMoreArchived() async {
    guard hasMoreArchived, let loaded = archived.value else { return }
    error = nil
    await readArchivedPage(appending: loaded)
  }

  private func readArchivedPage(appending loaded: [SessionSummary]) async {
    do {
      let page = try await core.archivedSessions(
        after: archivedCursor, limit: Self.archivedPageSize)
      let known = Set(loaded.map(\.id))
      archived = .loaded(loaded + page.sessions.filter { !known.contains($0.id) })
      archivedCursor = page.nextCursor
      hasMoreArchived = page.nextCursor != nil
    } catch {
      // A later page failing leaves the sessions already shown, and the cursor to retry from.
      if loaded.isEmpty {
        archived = .failed(coreError(error))
      } else {
        self.error = coreError(error)
      }
    }
  }

  /// Removes an account, then reloads the list.
  /// - Parameter userID: The account.
  public func removeMember(_ userID: String) async {
    if await write({ try await $0.removeServerMember(userId: userID) }) { await loadMembers() }
  }

  /// Resets an account's password.
  /// - Parameter userID: The account.
  /// - Returns: The new password, to show once; `nil` on failure (see ``error``).
  public func resetPassword(_ userID: String) async -> String? {
    var password: String?
    await write { password = try await $0.resetServerMemberPassword(userId: userID) }
    return password
  }

  /// Changes the caller's password.
  /// - Parameters:
  ///   - current: The current password.
  ///   - new: The new password.
  /// - Returns: Whether it changed.
  @discardableResult
  public func changePassword(current: String, new: String) async -> Bool {
    await write { try await $0.changePassword(current: current, new: new) }
  }

  /// Turns a default policy on or off.
  /// - Parameters:
  ///   - policyID: The policy.
  ///   - enabled: On or off.
  public func setPolicyEnabled(_ policyID: String, _ enabled: Bool) async {
    var updated: DefaultPolicyRecord?
    await write {
      updated = try await $0.setDefaultPolicyEnabled(policyId: policyID, enabled: enabled)
    }
    guard let updated, let rows = policies.value else { return }
    policies = .loaded(rows.map { $0.id == policyID ? updated : $0 })
  }

  /// Deletes a default policy, then reloads the list.
  /// - Parameter policyID: The policy.
  public func deletePolicy(_ policyID: String) async {
    if await write({ try await $0.deleteDefaultPolicy(policyId: policyID) }) {
      await loadPolicies()
    }
  }

  /// Changes sharing; the server's answer replaces the shown settings.
  /// - Parameter update: The changed fields.
  public func updateSharing(_ update: SharingUpdateRecord) async {
    var updated: SharingSettingsRecord?
    await write { updated = try await $0.updateSharing(update: update) }
    if let updated { sharing = .loaded(updated) }
  }

  /// Connects an MCP service with a personal token, then reloads the registry.
  /// - Parameters:
  ///   - serviceID: The service.
  ///   - token: The token.
  /// - Returns: Whether it connected.
  @discardableResult
  public func connectMCPService(_ serviceID: String, token: String) async -> Bool {
    let connected = await write {
      try await $0.connectMcpService(serviceId: serviceID, token: token)
    }
    if connected { await loadMCPServices() }
    return connected
  }

  /// Disconnects the caller's account from an MCP service, then reloads the registry.
  /// - Parameter serviceID: The service.
  public func disconnectMCPService(_ serviceID: String) async {
    if await write({ try await $0.disconnectMcpService(serviceId: serviceID) }) {
      await loadMCPServices()
    }
  }

  /// Checks an MCP service over the caller's account.
  /// - Parameter serviceID: The service.
  /// - Returns: Its tools.
  /// - Throws: The core's error, for the service's row to show.
  public func testMCPService(_ serviceID: String) async throws(CoreError) -> [String] {
    do {
      return try await core.testMcpService(serviceId: serviceID)
    } catch {
      throw coreError(error)
    }
  }

  /// Removes the caller's account connection to `provider`, then reloads the connections.
  /// - Parameter provider: The provider.
  public func disconnectProvider(_ provider: String) async {
    guard await write({ try await $0.disconnectProvider(provider: provider) }) else { return }
    await loadConnections(connections.value?.map(\.provider) ?? [provider])
  }

  /// Imports recent local sessions from a host, or one session by its harness id.
  /// - Parameters:
  ///   - hostID: The host.
  ///   - source: An ``importSources()`` id; one harness (not `all`) with `sessionID`.
  ///   - limit: The most recent sessions to read.
  ///   - sessionID: The harness session to import, instead of the most recent ones.
  /// - Returns: The tally; `nil` on failure (see ``error``).
  public func importSessions(
    hostID: String, source: String, limit: UInt32, sessionID: String? = nil
  ) async -> ImportResultRecord? {
    var result: ImportResultRecord?
    await write {
      result = try await $0.importLocalSessions(
        hostId: hostID, source: source, limit: limit, sessionId: sessionID)
    }
    return result
  }

  /// Unarchives sessions one at a time; they leave the list.
  /// - Parameter sessionIDs: The sessions.
  public func unarchive(_ sessionIDs: [String]) async {
    await bulk(sessionIDs, verb: "unarchive") { core, id in
      _ = try await core.editSession(
        sessionId: id, change: .archived(archived: false, deleteWorktree: false))
    }
  }

  /// Deletes sessions and their history one at a time; they leave the list.
  /// - Parameter sessionIDs: The sessions.
  public func delete(_ sessionIDs: [String]) async {
    await bulk(sessionIDs, verb: "delete") { core, id in
      try await core.deleteSession(sessionId: id)
    }
  }

  /// Runs `operation` on each session, dropping the ones that succeed from ``archived``. The
  /// first failure is kept in ``error``, with how many failed.
  private func bulk(
    _ sessionIDs: [String], verb: String,
    _ operation: (ClientCore, String) async throws -> Void
  ) async {
    isSaving = true
    error = nil
    var done: Set<String> = []
    var failures: [CoreError] = []
    for id in sessionIDs {
      do {
        try await operation(core, id)
        done.insert(id)
      } catch {
        failures.append(coreError(error))
      }
    }
    if let rows = archived.value { archived = .loaded(rows.filter { !done.contains($0.id) }) }
    if let first = failures.first {
      error =
        failures.count == 1 && sessionIDs.count == 1
        ? first
        : .InvalidState(
          message:
            "Could not \(verb) \(failures.count) of \(sessionIDs.count) sessions: \(first.message)")
    }
    isSaving = false
  }

  private func read<Value>(_ operation: (ClientCore) async throws -> Value) async
    -> CreationLoad<Value>
  {
    do {
      return .loaded(try await operation(core))
    } catch {
      return .failed(coreError(error))
    }
  }

  @discardableResult
  private func write(_ operation: (ClientCore) async throws -> Void) async -> Bool {
    isSaving = true
    error = nil
    defer { isSaving = false }
    do {
      try await operation(core)
      return true
    } catch {
      self.error = coreError(error)
      return false
    }
  }
}
