import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The server-configured MCP services a new session starts with (the web's
/// `McpRegistryLaunchPicker` and `useMcpRegistrySelection`): the remembered choice, the chip's
/// state, and what a start sends.
extension NewSessionForm {
  /// Where the choice is kept; the web's browser key.
  static let mcpServicesKey = "omnigent:last-mcp-services"

  /// Reads the remembered choice once, then the registry where the server has one.
  func loadMcpServices(_ creation: CreationStore) async {
    if !didReadMcpServices {
      didReadMcpServices = true
      mcpServices = preferences.stringArray(forKey: Self.mcpServicesKey) ?? []
    }
    await creation.loadMcpServices()
  }

  /// Turns `id` on or off and remembers the choice, as an explicit toggle on the web does.
  func toggleMcpService(_ id: String, enabled: Bool) {
    if enabled {
      if !mcpServices.contains(id) { mcpServices.append(id) }
    } else {
      mcpServices.removeAll { $0 == id }
    }
    preferences.set(mcpServices, forKey: Self.mcpServicesKey)
  }

  /// The services a start sends: the chosen ones the registry still lists.
  func mcpLaunchServices(_ creation: CreationStore) -> [String] {
    guard creation.catalog.value?.mcpRegistry == true else { return [] }
    return launchMcpServices(
      selected: mcpServices, offered: creation.mcpServices.value?.map(\.id) ?? [])
  }

  /// Why a start waits on the registry: services are chosen and it is loading or unreadable.
  func mcpProblem(_ creation: CreationStore) -> String? {
    guard creation.catalog.value?.mcpRegistry == true else { return nil }
    let (loading, failed): (Bool, Bool) =
      switch creation.mcpServices {
      case .idle, .loading: (true, false)
      case .failed: (false, true)
      case .loaded: (false, false)
      }
    return launchMcpProblem(
      selected: mcpServices, registryLoading: loading, registryFailed: failed)
  }

  /// The MCPs chip, where the server has the registry and the session is not a nested agent
  /// (named sub-agents keep their authored services).
  func mcpChip(_ creation: CreationStore) -> McpLaunchServices? {
    guard creation.catalog.value?.mcpRegistry == true, nested == nil else { return nil }
    let selected = Set(mcpServices)
    let services = (creation.mcpServices.value ?? []).map { service in
      McpLaunchServices.Service(
        id: service.id, title: service.title.isEmpty ? service.id : service.title,
        description: service.description,
        connection: service.connected
          ? .connected : service.acceptsToken ? .needsToken : .needsSignIn,
        isSelected: selected.contains(service.id))
    }
    let phase: McpLaunchServices.Phase
    switch creation.mcpServices {
    case .idle, .loading: phase = .loading
    case .failed(let error): phase = .failed(error.message)
    case .loaded: phase = .loaded
    }
    // While the list is unknown the chip counts the remembered choice, as the web's does.
    let count = phase == .loaded ? services.filter(\.isSelected).count : mcpServices.count
    return McpLaunchServices(phase: phase, services: services, selectedCount: count)
  }
}
