public import Foundation
import OmnigentCoreFFI
public import OmnigentStores
import OmnigentUIComponents
public import SwiftUI

/// Settings > Servers: the server settings of each signed-in server, with a server picker. Each
/// server's ``ServerSettingsStore`` lives while the Settings window (or the iPhone and iPad
/// Settings screen) shows it. Other windows pick the server and pane through
/// ``SettingsNavigator``.
public struct ServerSettingsContainer: View {
  private let connections: @MainActor () -> [ConnectionStore]
  private let opener: ExternalURLOpener
  private let openSession: (@MainActor (URL, String) -> Void)?
  private let navigator: SettingsNavigator
  private let leadingSections: AnyView?
  @State private var servers: [ConnectionStore] = []
  @State private var selected: String?
  @State private var pane: ServerSettingsPane?
  @State private var stores: [String: ServerSettingsStore] = [:]
  @State private var openFailure: String?

  /// Creates the settings.
  /// - Parameters:
  ///   - connections: The signed-in connections, read when the window appears.
  ///   - opener: Opens the server's web settings for browser-only sign-ins.
  ///   - navigator: Where other windows ask for a server and pane.
  ///   - openSession: Opens a session of a server in a window (after Unarchive).
  ///   - leadingSections: The app's own rows above the server panes (iPhone and iPad).
  public init(
    connections: @escaping @MainActor () -> [ConnectionStore] = {
      SupervisionConnections.shared.connections
    },
    opener: ExternalURLOpener = .system, navigator: SettingsNavigator = .shared,
    openSession: (@MainActor (URL, String) -> Void)? = nil, leadingSections: AnyView? = nil
  ) {
    self.connections = connections
    self.opener = opener
    self.navigator = navigator
    self.openSession = openSession
    self.leadingSections = leadingSections
  }

  /// The settings.
  public var body: some View {
    let store = selected.flatMap { stores[$0] }
    let connection = servers.first { $0.supervisedServerURL == selected }
    var state = ServerSettingsAdapter.state(
      store, servers: servers.map(Self.choice),
      projects: connection?.sessionList.projects ?? [])
    if let openFailure { state.errorMessage = openFailure }
    return ServerSettingsView(
      state: state, selectedServer: $selected, selectedPane: $pane,
      actions: store.map { wiring($0, connection: connection).actions() }
        ?? ServerSettingsActions(),
      leadingSections: leadingSections,
      hostedPane: { pane in
        Self.hostedPane(
          pane, connection: connection, agentDetail: store?.info.value?.agentDetail ?? false)
      }
    )
    .onAppear {
      refresh()
      showRequest()
    }
    .onChange(of: selected) { refresh() }
    .onChange(of: navigator.serverRequest) { showRequest() }
  }

  /// Harnesses and Custom Agents run over the connection's own stores.
  private static func hostedPane(
    _ pane: ServerSettingsPane, connection: ConnectionStore?, agentDetail: Bool
  ) -> AnyView? {
    guard let connection else { return nil }
    switch pane {
    case .harnesses:
      return AnyView(HarnessesSettingsView(connection: connection).id(ObjectIdentifier(connection)))
    case .customAgents:
      return AnyView(
        CustomAgentsSettingsView(connection: connection, canEdit: agentDetail)
          .id(ObjectIdentifier(connection)))
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

  /// Shows the server and pane another window asked for.
  private func showRequest() {
    guard let request = navigator.takeServerRequest() else { return }
    servers = connections()
    let ids = servers.compactMap(\.supervisedServerURL)
    if let match = Self.server(request.url, in: ids), selected != match { selected = match }
    if pane != request.pane { pane = request.pane }
    refresh()
  }

  /// The signed-in server `url` names, ignoring case and a trailing slash.
  static func server(_ url: String?, in ids: [String]) -> String? {
    guard let url else { return nil }
    let key = ServerChoice.normalizedID(url)
    return ids.first { ServerChoice.normalizedID($0) == key }
  }

  private func wiring(_ store: ServerSettingsStore, connection: ConnectionStore?)
    -> ServerSettingsWiring
  {
    var open: (@MainActor (String) -> Void)?
    if let openSession, let selected, let url = URL(string: selected) {
      open = { openSession(url, $0) }
    }
    return ServerSettingsWiring(
      store: store, connection: connection, openSession: open,
      openWebSettings: { openWebSettings($0) }, signOut: { signOut($0) })
  }

  /// Signs the server's connection out and forgets its account, as the window's Sign Out does.
  private func signOut(_ connection: ConnectionStore) {
    if let url = connection.supervisedServerURL {
      RememberedAccounts(defaults: .standard).forget(url)
    }
    Task {
      await connection.signOut()
      refresh()
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
