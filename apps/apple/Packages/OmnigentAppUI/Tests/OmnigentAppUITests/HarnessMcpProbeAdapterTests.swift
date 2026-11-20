import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// The harness page's MCP rows opening to their tools, worded as the web's `McpRow`.
@Suite("Harness page: MCP tool probe")
struct HarnessMcpProbeAdapterTests {
  private var catalog: HarnessCatalogState {
    var state = HarnessCatalogState()
    state.servers = [
      HarnessCatalogState.Server(id: "docs", title: "docs"),
      HarnessCatalogState.Server(id: "jira", title: "jira"),
    ]
    return state
  }

  @Test func probedRowsShowTheirToolsAndConnection() {
    let tools: [String: CreationLoad<McpToolsRead>] = [
      "h/claude-native/docs": .loaded(
        .probed(
          tools: [McpTool(name: "search", description: "Find pages")], connection: .connected,
          truncated: true)),
      "h/claude-native/jira": .loaded(.probed(tools: [], connection: .needsAuth, truncated: false)),
    ]
    let state = HarnessCatalogAdapter.probing(
      catalog, tools: tools, prefix: "h/claude-native/", harness: "claude-native", host: "Mac")
    #expect(state.servers.allSatisfy { $0.probes })
    #expect(
      state.servers[0].status
        == HarnessMcpStatus(label: "Connected", tone: .connected, toolCount: "1+ tool"))
    #expect(
      state.servers[0].probe
        == .tools([HarnessMcpTool(name: "search", description: "Find pages")], truncated: true))
    #expect(state.servers[1].status?.label == "Needs auth")
    guard case .notice(let why)? = state.servers[1].probe else {
      Issue.record("a server needing a sign-in says so")
      return
    }
    #expect(why.hasPrefix("Authentication required."))
  }

  @Test func whyAProbeFailedIsSaidAndAMissingRouteLeavesRowsStatic() {
    #expect(
      HarnessCatalogAdapter.probe(.loaded(.hostOutdated), title: "docs", host: "Mac").0
        == .notice("Update Mac to list tools."))
    #expect(HarnessCatalogAdapter.probe(.loading, title: "docs", host: "Mac").0 == .loading)
    #expect(HarnessCatalogAdapter.probe(nil, title: "docs", host: "Mac").0 == nil)
    let missing: [String: CreationLoad<McpToolsRead>] = [
      "h/claude-native/docs": .loaded(.routeMissing)
    ]
    let state = HarnessCatalogAdapter.probing(
      catalog, tools: missing, prefix: "h/claude-native/", harness: "claude-native", host: "Mac")
    #expect(!state.servers.contains { $0.probes })
    let piRows = HarnessCatalogAdapter.probing(
      catalog, tools: [:], prefix: "h/pi-native/", harness: "pi-native", host: "Mac")
    #expect(!piRows.servers.contains { $0.probes }, "Pi's servers aren't probed")
  }
}
