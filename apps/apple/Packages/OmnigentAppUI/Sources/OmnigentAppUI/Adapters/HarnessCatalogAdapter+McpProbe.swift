import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The MCP rows' tool probe, worded as the web's `McpRow`.
extension HarnessCatalogAdapter {
  /// `catalog` with its MCP rows opening to their tools, where the harness's family is probed
  /// (Claude, Codex, Cursor); every row stays static once the server lacks the probe route.
  /// - Parameters:
  ///   - catalog: The tabs' state.
  ///   - tools: The probes, by key.
  ///   - prefix: The keys' host and harness part, `host/harness/`.
  ///   - harness: The harness id.
  ///   - host: The host's name.
  /// - Returns: The state with the probed rows.
  static func probing(
    _ catalog: HarnessCatalogState, tools: [String: CreationLoad<McpToolsRead>], prefix: String,
    harness: String, host: String
  ) -> HarnessCatalogState {
    guard let family = harnessInventoryFamily(harness: harness),
      harnessSkillPagesOpen(family: family)
    else { return catalog }
    let probes = catalog.servers.map { tools[prefix + $0.id] }
    if probes.contains(where: { $0 == .loaded(.routeMissing) }) { return catalog }
    var probed = catalog
    probed.servers = zip(catalog.servers, probes).map { server, load in
      var server = server
      server.probes = true
      (server.probe, server.status) = probe(load, title: server.title, host: host)
      return server
    }
    return probed
  }

  /// What an opened row shows and its badge.
  static func probe(_ load: CreationLoad<McpToolsRead>?, title: String, host: String)
    -> (HarnessMcpProbe?, HarnessMcpStatus?)
  {
    switch load {
    case nil, .idle: return (nil, nil)
    case .loading: return (.loading, nil)
    case .failed: return (.notice("Couldn\u{2019}t reach \(title)."), nil)
    case .loaded(.routeMissing): return (nil, nil)
    case .loaded(.hostOutdated): return (.notice("Update \(host) to list tools."), nil)
    case .loaded(.busy):
      return (
        .notice("Host is busy probing other MCP servers. Collapse and reopen to retry."), nil
      )
    case .loaded(.probed(let tools, let connection, let truncated)):
      return probed(tools, connection: connection, truncated: truncated)
    }
  }

  private static func probed(_ tools: [McpTool], connection: McpConnection, truncated: Bool)
    -> (HarnessMcpProbe?, HarnessMcpStatus?)
  {
    let failed = HarnessMcpStatus(label: "Failed to connect", tone: .failed)
    switch connection {
    case .connected:
      let count = "\(tools.count)\(truncated ? "+" : "") \(tools.count == 1 ? "tool" : "tools")"
      return (
        .tools(
          tools.map { HarnessMcpTool(name: $0.name, description: $0.description) },
          truncated: truncated),
        HarnessMcpStatus(label: "Connected", tone: .connected, toolCount: count)
      )
    case .needsAuth:
      return (
        .notice(
          "Authentication required. Harness sign-in credentials cannot be reused for this probe."
        ),
        HarnessMcpStatus(label: "Needs auth", tone: .attention)
      )
    case .unreachable: return (.notice("Couldn\u{2019}t reach this MCP server."), failed)
    case .timeout: return (.notice("MCP probe timed out."), failed)
    case .unsupported:
      return (.notice("This MCP configuration cannot be probed from the host."), failed)
    }
  }
}
