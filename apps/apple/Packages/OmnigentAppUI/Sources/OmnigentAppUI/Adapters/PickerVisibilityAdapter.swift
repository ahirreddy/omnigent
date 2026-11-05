import Foundation
import OmnigentCoreFFI
public import OmnigentStores
public import OmnigentUIComponents

/// Settings › Show in agent pickers over the catalog: the entries it lists, and the agents each
/// picker (new session, project defaults, automations) keeps after the user's hidden names.
public enum PickerVisibilityAdapter {
  /// The catalog's agents a picker shows: hidden ones dropped, except `selectedID`.
  static func shown(
    _ agents: [OmnigentCoreFFI.CreationAgent], selectedID: String?,
    hidden: Set<String> = PickerVisibility.hidden()
  ) -> [OmnigentCoreFFI.CreationAgent] {
    PickerVisibility.shown(
      agents, name: \.name, id: \.id, selectedID: selectedID, hidden: hidden)
  }

  /// The setting's entries: the harnesses, then the agents, in the picker's order.
  static func entries(_ catalog: OmnigentCoreFFI.CreationCatalog) -> [PickerVisibilityEntry] {
    let ordered = NewSessionAdapter.agents(catalog, hostID: "").choices
    let agents = Dictionary(
      catalog.agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var seen = Set<String>()
    return ordered.compactMap { choice in
      guard let agent = agents[choice.id], seen.insert(agent.name).inserted else { return nil }
      let isHarness = agent.pickerSection == .harness
      let title = isHarness && !agent.harnessLabel.isEmpty ? agent.harnessLabel : agent.name
      return PickerVisibilityEntry(
        name: agent.name, title: title, group: isHarness ? .harnesses : .agents)
    }
  }

  /// The setting's source: the first signed-in server's catalog, reusing a loaded one.
  @MainActor
  public static func source(
    _ connections: [ConnectionStore] = SupervisionConnections.shared.connections
  ) -> PickerVisibilitySource {
    let connection = connections.first
    return PickerVisibilitySource(server: connection?.supervisedServerURL ?? "") {
      await load(connection)
    }
  }

  @MainActor
  private static func load(_ connection: ConnectionStore?) async -> PickerVisibilityLoad {
    guard let creation = connection?.creation() else {
      return .failed("Sign in to a server first.")
    }
    if creation.catalog.value == nil { await creation.loadCatalog() }
    switch creation.catalog {
    case .loaded(let catalog): return .loaded(entries(catalog))
    case .failed(let error): return .failed(error.message)
    case .idle, .loading: return .failed("The server's agents are still loading.")
    }
  }
}
