public import OmnigentCoreFFI

/// The harness page's MCP tool probe: an opened row asks its host to connect to the server and
/// list its tools, kept for the session as the web keeps its probe for five minutes.
extension HarnessSetupStore {
  /// The key of a server's probe.
  public static func mcpToolsKey(_ hostID: String, _ harness: String, _ serverID: String)
    -> String
  {
    "\(hostID)/\(harness)/\(serverID)"
  }

  /// Probes `server`'s tools on `hostID` unless a probe answered or runs; a failed or busy one
  /// runs again, as the web retries a reopened row.
  /// - Parameters:
  ///   - server: The row.
  ///   - harness: The harness id.
  ///   - hostID: The host.
  public func loadMcpTools(_ server: InventoryMcpServer, harness: String, hostID: String) async {
    guard let family = harnessInventoryFamily(harness: harness) else { return }
    let key = Self.mcpToolsKey(hostID, harness, server.id)
    switch mcpTools[key] {
    case .loading: return
    case .loaded(.probed), .loaded(.routeMissing), .loaded(.hostOutdated): return
    default: break
    }
    mcpTools[key] = .loading
    do {
      mcpTools[key] = .loaded(
        try await core.mcpServerTools(
          hostId: hostID, harness: family, server: server.name, plugin: server.plugin,
          sourceId: server.sourceId))
    } catch {
      mcpTools[key] = .failed(coreError(error))
    }
  }
}
