import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// What each control in a server's settings does to its ``ServerSettingsStore``.
struct ServerSettingsWiring {
  let store: ServerSettingsStore
  let connection: ConnectionStore?
  let openSession: (@MainActor (String) -> Void)?
  let openWebSettings: @MainActor (ServerSettingsPane) -> Void
  let signOut: @MainActor (ConnectionStore) -> Void

  func actions() -> ServerSettingsActions {
    var actions = ServerSettingsActions()
    actions.load = { pane in Task { await load(pane) } }
    actions.loadServer = {
      Task { if store.info.value == nil, !store.info.isLoading { await store.loadInfo() } }
    }
    actions.connectMCP = { await store.connectMCPService($0.id, token: $1) }
    actions.disconnectMCP = { service in Task { await store.disconnectMCPService(service.id) } }
    actions.testMCP = { service in
      do throws(CoreError) {
        let tools = try await store.testMCPService(service.id)
        return tools.isEmpty
          ? "Connected; no tools listed." : "Tools: \(tools.joined(separator: ", "))"
      } catch {
        return "Test failed: \(error.message)"
      }
    }
    actions.openInBrowser = openWebSettings
    actions.disconnectProvider = { row in Task { await store.disconnectProvider(row.id) } }
    actions.importSessions = { host, source, limit, sessionID in
      await store.importSessions(
        hostID: host, source: source, limit: UInt32(clamping: limit), sessionID: sessionID
      )
      .map(ServerSettingsAdapter.importSummary)
    }
    actions.changePassword = { await store.changePassword(current: $0, new: $1) }
    adminActions(&actions)
    actions.changeSharing = { change in
      Task { await store.updateSharing(ServerSettingsAdapter.update(change)) }
    }
    actions.unarchive = { ids in Task { await store.unarchive(ids) } }
    actions.delete = { ids in Task { await store.delete(ids) } }
    actions.loadMoreArchived = { Task { await store.loadMoreArchived() } }
    if let connection, store.info.value?.hasLoginSession ?? false {
      actions.signOut = { signOut(connection) }
    }
    actions.openSession = openSession
    return actions
  }

  /// Members and Policies: password resets, removals, invites and default policies.
  private func adminActions(_ actions: inout ServerSettingsActions) {
    actions.resetPassword = { await store.resetPassword($0.id) }
    actions.removeMember = { member in Task { await store.removeMember(member.id) } }
    if store.info.value?.accountsEnabled == true {
      actions.invite = { isAdmin in
        await store.invite(isAdmin: isAdmin).map(ServerSettingsAdapter.inviteLink)
      }
    }
    actions.addPolicy = { template, name, values in
      guard let entry = store.policyRegistry.value?.first(where: { $0.handler == template.id })
      else { return false }
      return await store.addPolicy(entry, name: name, values: values)
    }
    actions.setPolicyEnabled = { row, enabled in
      Task { await store.setPolicyEnabled(row.id, enabled) }
    }
    actions.deletePolicy = { row in Task { await store.deletePolicy(row.id) } }
  }

  /// Reads what `pane` shows.
  func load(_ pane: ServerSettingsPane) async {
    if store.info.value == nil { await store.loadInfo() }
    switch pane {
    case .mcp: await store.loadMCPServices()
    case .integrations: await store.loadConnections(store.info.value?.connections ?? [])
    case .importSessions: await store.loadImportHosts()
    case .members: await store.loadMembers()
    case .policies:
      await store.loadPolicies()
      await store.loadPolicyRegistry()
    case .sharing: await store.loadSharing()
    case .archived: await store.loadArchived()
    case .account, .harnesses, .customAgents, .git: break
    }
  }
}
