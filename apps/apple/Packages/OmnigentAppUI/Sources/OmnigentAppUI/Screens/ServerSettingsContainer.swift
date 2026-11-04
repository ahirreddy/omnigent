import OmnigentCoreFFI
public import OmnigentStores
import OmnigentUIComponents
public import SwiftUI

/// Settings > Servers: the server settings of each signed-in server, with a server picker. Each
/// server's ``ServerSettingsStore`` lives while the Settings window shows it.
public struct ServerSettingsContainer: View {
  private let connections: @MainActor () -> [ConnectionStore]
  private let opener: ExternalURLOpener
  @State private var servers: [ConnectionStore] = []
  @State private var selected: String?
  @State private var stores: [String: ServerSettingsStore] = [:]
  @State private var openFailure: String?

  /// Creates the settings.
  /// - Parameters:
  ///   - connections: The signed-in connections, read when the window appears.
  ///   - opener: Opens the server's web settings for browser-only sign-ins.
  public init(
    connections: @escaping @MainActor () -> [ConnectionStore] = {
      SupervisionConnections.shared.connections
    },
    opener: ExternalURLOpener = .system
  ) {
    self.connections = connections
    self.opener = opener
  }

  /// The settings.
  public var body: some View {
    let store = selected.flatMap { stores[$0] }
    var state = ServerSettingsAdapter.state(store, servers: servers.map(Self.choice))
    if let openFailure { state.errorMessage = openFailure }
    let connection = servers.first { $0.supervisedServerURL == selected }
    return ServerSettingsView(
      state: state, selectedServer: $selected,
      actions: store.map(actions) ?? ServerSettingsActions(),
      hostedPane: { pane in Self.hostedPane(pane, connection: connection) }
    )
    .onAppear(perform: refresh)
    .onChange(of: selected) { refresh() }
  }

  /// Harnesses and Custom Agents run over the connection's own stores.
  private static func hostedPane(_ pane: ServerSettingsPane, connection: ConnectionStore?)
    -> AnyView?
  {
    guard let connection else { return nil }
    switch pane {
    case .harnesses:
      return AnyView(HarnessesSettingsView(connection: connection).id(ObjectIdentifier(connection)))
    case .customAgents:
      return AnyView(
        CustomAgentsSettingsView(connection: connection).id(ObjectIdentifier(connection)))
    default: return nil
    }
  }

  private static func choice(_ connection: ConnectionStore) -> ServerChoice {
    let url = connection.supervisedServerURL ?? ""
    let name =
      connection.connectedServer?.serverName
      ?? URL(string: url)?.host(percentEncoded: false) ?? url
    return ServerChoice(id: url, name: name, url: url)
  }

  /// Rereads the signed-in servers and makes a store for the selected one.
  private func refresh() {
    servers = connections()
    let ids = servers.compactMap(\.supervisedServerURL)
    if selected.map(ids.contains) != true { selected = ids.first }
    stores = stores.filter { ids.contains($0.key) }
    guard let selected, stores[selected] == nil,
      let connection = servers.first(where: { $0.supervisedServerURL == selected }),
      let store = connection.serverSettings()
    else { return }
    stores[selected] = store
  }

  private func actions(_ store: ServerSettingsStore) -> ServerSettingsActions {
    var actions = ServerSettingsActions()
    actions.load = { pane in Task { await load(pane, store) } }
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
    actions.openInBrowser = { pane in openWebSettings(pane) }
    actions.disconnectProvider = { row in Task { await store.disconnectProvider(row.id) } }
    actions.importSessions = { host, source, limit in
      await store.importSessions(hostID: host, source: source, limit: UInt32(clamping: limit))
        .map(ServerSettingsAdapter.importSummary)
    }
    actions.changePassword = { await store.changePassword(current: $0, new: $1) }
    actions.resetPassword = { await store.resetPassword($0.id) }
    actions.removeMember = { member in Task { await store.removeMember(member.id) } }
    actions.setPolicyEnabled = { row, enabled in
      Task { await store.setPolicyEnabled(row.id, enabled) }
    }
    actions.deletePolicy = { row in Task { await store.deletePolicy(row.id) } }
    actions.changeSharing = { change in
      Task { await store.updateSharing(ServerSettingsAdapter.update(change)) }
    }
    actions.unarchive = { ids in Task { await store.unarchive(ids) } }
    actions.delete = { ids in Task { await store.delete(ids) } }
    actions.loadMoreArchived = { Task { await store.loadMoreArchived() } }
    return actions
  }

  private func load(_ pane: ServerSettingsPane, _ store: ServerSettingsStore) async {
    if store.info.value == nil { await store.loadInfo() }
    switch pane {
    case .mcp: await store.loadMCPServices()
    case .integrations: await store.loadConnections(store.info.value?.connections ?? [])
    case .importSessions: await store.loadImportHosts()
    case .members: await store.loadMembers()
    case .policies: await store.loadPolicies()
    case .sharing: await store.loadSharing()
    case .archived: await store.loadArchived()
    case .account, .harnesses, .customAgents, .git: break
    }
  }

  /// Opens the server's web settings page for `pane`: OAuth and provider sign-ins finish there,
  /// with the browser's own session.
  private func openWebSettings(_ pane: ServerSettingsPane) {
    let section = pane == .mcp ? "mcp" : "integrations"
    guard let selected, var url = URL(string: selected) else { return }
    url.append(path: "settings/\(section)")
    Task {
      openFailure = await opener.open(url) ? nil : "Could not open \(url.absoluteString)."
    }
  }
}
