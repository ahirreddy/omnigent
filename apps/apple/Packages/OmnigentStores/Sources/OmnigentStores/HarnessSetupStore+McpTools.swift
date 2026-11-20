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

  /// Turns `server` on or off for Omnigent sessions of `harness` on `hostID`, then reads the
  /// harness's lists again; the row shows the asked state until the host answers.
  public func setMcpServerEnabled(
    _ server: InventoryMcpServer, enabled: Bool, harness: String, hostID: String
  ) async {
    let key = Self.mcpToolsKey(hostID, harness, server.id)
    guard mcpSwitching[key] == nil else { return }
    mcpSwitching[key] = enabled
    mcpSwitchError = nil
    do {
      _ = try await core.setMcpServerEnabled(hostId: hostID, server: server, enabled: enabled)
      await loadCatalog(harness: harness, hostID: hostID)
    } catch {
      mcpSwitchError = coreError(error)
    }
    mcpSwitching[key] = nil
  }
}
